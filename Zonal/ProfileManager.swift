import AppKit
import Foundation

protocol DisplaySnapshotProviding {
    func currentSnapshot() -> DisplaySnapshot
}

struct MacDisplaySnapshotProvider: DisplaySnapshotProviding {
    func currentSnapshot() -> DisplaySnapshot {
        let displays = NSScreen.screens.map { screen in
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID = UInt32(truncating: screenNumber ?? 0)
            let quartzFrame = CGDisplayBounds(displayID)
            let leftInset = screen.visibleFrame.minX - screen.frame.minX
            let rightInset = screen.frame.maxX - screen.visibleFrame.maxX
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            let bottomInset = screen.visibleFrame.minY - screen.frame.minY
            let visibleFrame = CGRect(
                x: quartzFrame.minX + leftInset,
                y: quartzFrame.minY + topInset,
                width: max(1, quartzFrame.width - leftInset - rightInset),
                height: max(1, quartzFrame.height - topInset - bottomInset)
            )
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)
                .map {
                    CFUUIDCreateString(kCFAllocatorDefault, $0.takeRetainedValue())
                        as String? ?? "display-\(displayID)"
                }
                ?? "display-\(displayID)"
            return DisplaySnapshot.Display(
                id: displayID,
                frame: quartzFrame,
                visibleFrame: visibleFrame,
                scale: Double(screen.backingScaleFactor),
                persistentID: uuid,
                name: screen.localizedName,
                rotation: CGDisplayRotation(displayID),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0
            )
        }
        return DisplaySnapshot(displays: displays)
    }
}

final class ProfileManager {
    private let store: PersistenceStore
    private let displayProvider: any DisplaySnapshotProviding

    init(
        store: PersistenceStore,
        displayProvider: any DisplaySnapshotProviding = MacDisplaySnapshotProvider()
    ) {
        self.store = store
        self.displayProvider = displayProvider
    }

    func currentSnapshot() -> DisplaySnapshot {
        displayProvider.currentSnapshot()
    }

    func matchedProfile(for snapshot: DisplaySnapshot) -> DisplayProfile? {
        let configuration = store.loadConfiguration()
        let matches = matchingProfiles(for: snapshot)
        if let activeProfileID = configuration.activeProfileID,
           let activeMatch = matches.first(where: { $0.id == activeProfileID }) {
            return activeMatch
        }
        return matches.first
    }

    func matchingProfiles(for snapshot: DisplaySnapshot) -> [DisplayProfile] {
        store.loadConfiguration().profiles.filter { profile in
            profile.setupBindings.contains { setupMatches($0, snapshot: snapshot) }
        }
    }

    func matchedSetupBinding(
        for profile: DisplayProfile,
        snapshot: DisplaySnapshot
    ) -> DisplaySetupBinding? {
        profile.setupBindings.first { setupMatches($0, snapshot: snapshot) }
    }

    func selectedProfile(for snapshot: DisplaySnapshot) -> DisplayProfile {
        let configuration = store.loadConfiguration()
        if let profile = matchedProfile(for: snapshot) {
            return profile
        }

        if let activeProfileID = configuration.activeProfileID,
           let profile = configuration.profiles.first(where: { $0.id == activeProfileID }) {
            return profile
        }

        return configuration.profiles.first ?? DefaultProfiles.main
    }

    func reloadProfiles() {
        _ = store.loadProfiles(forceReload: true)
    }

    func signature(for snapshot: DisplaySnapshot) -> DisplaySignature {
        DisplaySignature(
            displayCount: snapshot.displays.count,
            displays: snapshot.displays
                .map { display in
                    DisplaySignature.Display(
                        width: Int(display.frame.width.rounded()),
                        height: Int(display.frame.height.rounded()),
                        scale: display.scale
                    )
                }
                .sorted {
                    if $0.width == $1.width {
                        return $0.height < $1.height
                    }
                    return $0.width < $1.width
                }
        )
    }

    func setupBinding(for snapshot: DisplaySnapshot, name: String? = nil) -> DisplaySetupBinding {
        let desktop = snapshot.desktopFrame
        let relativeFrames = Dictionary(uniqueKeysWithValues: snapshot.displays.map { display in
            (display.descriptor.persistentID, NormalizedFrame.relativeFrame(for: display.frame, in: desktop))
        })
        return DisplaySetupBinding(
            name: name ?? setupName(for: snapshot),
            displays: snapshot.displays.map(\.descriptor),
            relativeFrames: relativeFrames,
            mainDisplayPersistentID: snapshot.primaryDisplay?.descriptor.persistentID
        )
    }

    func roles(for snapshot: DisplaySnapshot) -> [DisplayRole] {
        let sorted = snapshot.displays.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return lhs.isBuiltIn
            }
            return lhs.frame.minX < rhs.frame.minX
        }
        return sorted.enumerated().map { index, display in
            let id: DisplayRoleID = index == 0
                ? .workspace
                : DisplayRoleID(rawValue: "display-\(index + 1)")
            return DisplayRole(id: id, name: display.name, descriptor: display.descriptor)
        }
    }

    func display(for roleID: DisplayRoleID?, profile: DisplayProfile, snapshot: DisplaySnapshot) -> DisplaySnapshot.Display? {
        let role: DisplayRole?
        if let roleID {
            // An explicit role must never silently route to another display. A
            // missing role means the profile no longer describes this setup.
            role = profile.displayRoles.first { $0.id == roleID }
            guard role != nil else { return nil }
        } else {
            role = profile.displayRoles.first { $0.id == .workspace }
                ?? profile.displayRoles.first
        }

        // Profiles created before display roles existed remain usable on their
        // primary display. Once roles exist, failure to resolve one is unsafe.
        guard let role else { return snapshot.primaryDisplay }

        if let exact = snapshot.display(persistentID: role.descriptor.persistentID) {
            return exact
        }
        let candidates = snapshot.displays.filter {
            $0.isBuiltIn == role.descriptor.isBuiltIn
                && Int($0.frame.width.rounded()) == role.descriptor.width
                && Int($0.frame.height.rounded()) == role.descriptor.height
                && abs($0.scale - role.descriptor.scale) < 0.01
                && abs($0.rotation - role.descriptor.rotation) < 0.01
        }
        if candidates.count == 1 {
            return candidates[0]
        }
        return nil
    }

    func setupName(for snapshot: DisplaySnapshot) -> String {
        if snapshot.displays.count == 1, snapshot.displays[0].isBuiltIn {
            return "Built-in only"
        }
        if snapshot.displays.count == 1 {
            return "\(snapshot.displays[0].name) only"
        }
        return snapshot.displays.map(\.name).joined(separator: " + ")
    }

    private func setupMatches(_ binding: DisplaySetupBinding, snapshot: DisplaySnapshot) -> Bool {
        guard binding.displays.count == snapshot.displays.count else { return false }
        let desktop = snapshot.desktopFrame
        var remaining = binding.displays
        let exactIDs = Set(snapshot.displays.map { $0.descriptor.persistentID })
        for display in snapshot.displays {
            let descriptor = display.descriptor
            let exactIndex = remaining.firstIndex { $0.persistentID == descriptor.persistentID }
            let fallbackIndices = remaining.indices.filter { index in
                let candidate = remaining[index]
                return !exactIDs.contains(candidate.persistentID)
                    && candidate.isBuiltIn == descriptor.isBuiltIn
                    && candidate.width == descriptor.width
                    && candidate.height == descriptor.height
                    && abs(candidate.scale - descriptor.scale) < 0.01
                    && abs(candidate.rotation - descriptor.rotation) < 0.01
            }
            guard let index = exactIndex ?? (fallbackIndices.count == 1 ? fallbackIndices[0] : nil) else {
                return false
            }
            let bound = remaining.remove(at: index)
            if let expectedFrame = binding.relativeFrames[bound.persistentID] {
                let currentFrame = NormalizedFrame.relativeFrame(for: display.frame, in: desktop)
                guard expectedFrame.isClose(to: currentFrame, tolerance: 0.02) else {
                    return false
                }
            }
        }
        if let boundMain = binding.mainDisplayPersistentID,
           binding.displays.contains(where: { $0.persistentID == boundMain }),
           let currentMain = snapshot.primaryDisplay?.descriptor.persistentID,
           boundMain != currentMain {
            return false
        }
        return true
    }
}

private extension NormalizedFrame {
    func isClose(to other: NormalizedFrame, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
