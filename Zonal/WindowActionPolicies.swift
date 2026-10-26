import Foundation
import Darwin

struct PlacementNoOpPolicy {
    static func shouldSkip(actual: CGRect?, target: CGRect) -> Bool {
        actual?.matchesPlacement(to: target, sizeTolerance: 0.01) == true
    }
}

struct FocusLayoutPolicy {
    static func needsLayout(assignmentID: UUID, previousActive: UUID?, prepared: Bool) -> Bool {
        !prepared && previousActive != assignmentID
    }
}

struct KnownWindowFocusPolicy {
    static func canSkipReconciliation(identity: WindowIdentity, cached: [ManagedWindow],
                                      current: [ManagedWindow], recovering: Bool) -> Bool {
        !recovering
            && cached.contains { $0.identity.matchesSameLiveWindow(as: identity) }
            && current.contains { $0.identity.matchesSameLiveWindow(as: identity) }
    }
}

enum ZoneTabAction: Equatable {
    case move(ZoneID)
    case fit
    case restoreCustom
    case close

    var title: String {
        switch self {
        case .move: "Move to…"
        case .fit: "Fit to Zone"
        case .restoreCustom: "Restore Custom Size"
        case .close: "Close Window"
        }
    }
}

struct ZoneCustomPlacementGeometry {
    static func capture(_ frame: CGRect, in zone: CGRect) -> SavedCustomPlacement {
        func anchor(_ offset: CGFloat, freeSpace: CGFloat) -> CGFloat {
            abs(freeSpace) < 1 ? 0.5 : max(0, min(1, offset / freeSpace))
        }
        return SavedCustomPlacement(size: frame.size, relativePosition: CGPoint(
            x: anchor(frame.minX - zone.minX, freeSpace: zone.width - frame.width),
            y: anchor(frame.minY - zone.minY, freeSpace: zone.height - frame.height)))
    }

    static func frame(_ saved: SavedCustomPlacement, in zone: CGRect, display: CGRect) -> CGRect {
        let frame = CGRect(x: (zone.minX + saved.relativePosition.x * (zone.width - saved.size.width)).rounded(),
                           y: (zone.minY + saved.relativePosition.y * (zone.height - saved.size.height)).rounded(),
                           width: saved.size.width, height: saved.size.height)
        return keepVisible(frame, in: display)
    }

    static func keepVisible(_ frame: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: max(display.minX, min(frame.minX, display.maxX - frame.width)),
               y: max(display.minY, min(frame.minY, display.maxY - frame.height)),
               width: frame.width, height: frame.height)
    }
}

enum ManualWindowChange {
    case fit(ZoneID)
    case membership(ZoneID)
    case move(ZoneID, CGRect)
    case custom(ZoneID?, CGRect, isResize: Bool = false)

    var name: String {
        switch self {
        case .fit: ZoneTabAction.fit.title
        case .membership: "Update Window Zone"
        case .move: "Move Window"
        case .custom(_, _, let isResize): isResize ? "Resize Window" : "Move Window"
        }
    }
}

struct ZoneReflowPolicy {
    static func changedZones(from previous: DisplayProfile?, to current: DisplayProfile) -> Set<ZoneID> {
        Set(current.zones.filter { zone in
            guard let previous, previous.id == current.id,
                  let old = previous.zones.first(where: { $0.id == zone.id }) else { return true }
            return previous.zoneSpacing != current.zoneSpacing
                || old.windowPresentation != zone.windowPresentation
                || old.peekWidth != zone.peekWidth || old.peekDirection != zone.peekDirection
                || old.tabStyle != zone.tabStyle
                || old.tabBorderWidth != zone.tabBorderWidth
                || ZoneTabGroupPolicy.owner(for: old, profile: previous)?.id != ZoneTabGroupPolicy.owner(for: zone, profile: current)?.id
                || ZoneTabGroupPolicy.owner(for: old, profile: previous)?.tabStyle != ZoneTabGroupPolicy.owner(for: zone, profile: current)?.tabStyle
                || ZoneTabGroupPolicy.owner(for: old, profile: previous)?.tabBorderWidth != ZoneTabGroupPolicy.owner(for: zone, profile: current)?.tabBorderWidth
                || old.frame != zone.frame || old.displayRoleID != zone.displayRoleID
        }.map(\.id))
    }

    static func includes(_ assignment: WindowAssignment, zones: Set<ZoneID>, profile: DisplayProfile,
                         busyZones: Set<ZoneID> = [], includeOverlap: Bool = false) -> Bool {
        guard assignment.managementMode == .managed, zones.contains(assignment.zoneID),
              !busyZones.contains(assignment.zoneID),
              let zone = profile.zones.first(where: { $0.id == assignment.zoneID }),
              includeOverlap || zone.windowPresentation == .peekStack || ZoneTabGroupPolicy.owner(for: zone, profile: profile) != nil,
              assignment.fitsZone(in: profile.id) else { return false }
        return true
    }
}

@MainActor
final class WindowUndoBatch {
    private let entries: [WindowUndoEntry]
    private var pending: Set<Int>
    private var failed = Set<Int>()
    private(set) var restored = 0
    var failedEntries: [WindowUndoEntry] { entries.indices.filter { failed.contains($0) }.map { entries[$0] } }

    init(entries: [WindowUndoEntry]) {
        self.entries = entries
        pending = Set(entries.indices)
    }

    func complete(index: Int, outcome: WindowPlacementOutcome) -> Bool {
        guard pending.remove(index) != nil else { return false }
        if outcome == .placed { restored += 1 } else { failed.insert(index) }
        return pending.isEmpty
    }
}

// Ownership is acquired before any persistence or window-management service starts.
final class ZonalInstanceLock {
    private var descriptor: Int32 = -1
    private let url: URL

    init(url: URL = ZonalStoragePaths.instanceLock) {
        self.url = url
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(fd)
            if failure == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        descriptor = fd
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

enum WorkspaceSaveResult: Equatable {
    case saved
    case unavailable
    case failed
}

struct ZoneTabDragDestination: Equatable {
    var zone: Zone
    var zoneFrame: CGRect
    var landingFrame: CGRect
}

struct ZoneTabDragPlan: Equatable {
    var assignmentID: UUID
    var windowID: LiveWindowID
    var profileID: String
    var displays: DisplaySnapshot
    var destinations: [ZoneTabDragDestination]
    var isFitted: Bool
    var sourceZoneFrame: CGRect? = nil

    func destination(at point: CGPoint) -> ZoneID? {
        let zones = destinations.map { ZoneFrame(zoneID: $0.zone.id, frame: $0.zoneFrame) }
        if let explicit = HotZoneResolver().targetZone(for: point, zones: zones) { return explicit }
        let containing = zones.filter { $0.frame.contains(point) }
        return containing.count == 1 && sourceZoneFrame?.contains(point) != true ? containing[0].zoneID : nil
    }

    func overlayTargets(at point: CGPoint) -> [HotZoneTarget] {
        let selected = destination(at: point)
        let targets = HotZoneResolver().dropTargets(for: destinations.map { ZoneFrame(zoneID: $0.zone.id, frame: $0.zoneFrame) })
        return destinations.compactMap { destination in
            guard let target = targets.first(where: { $0.zoneID == destination.zone.id }) else { return nil }
            return HotZoneTarget(zoneID: destination.zone.id,
                name: ZoneNameResolver().name(for: destination.zone.id, in: destinations.map(\.zone)),
                zoneFrame: destination.zone.frame, previewFrame: destination.zoneFrame, frame: target.frame,
                isMaximizeTargetActive: selected == destination.zone.id && isFitted,
                isMembershipActive: selected == destination.zone.id,
                landingFrame: selected == destination.zone.id ? destination.landingFrame : nil, preservesCustomSize: !isFitted)
        }
    }
}
