import CoreGraphics
import Foundation

struct ZonalDoctorPolicy {
    func signatureFinding(identifier: String?, team: String?, isValid: Bool) -> ZonalHealthFinding {
        if identifier == "com.sebmarste.zonal.dev", isValid {
            return ZonalHealthFinding(id: "signature", level: .ok, title: "Development signature",
                detail: "Local development build with isolated data. Rebuilding may require granting permissions again.")
        }
        let expected = identifier == "com.sebmarste.zonal" && team == "XW6G452649"
        return ZonalHealthFinding(
            id: "signature", level: !isValid ? .error : expected ? .ok : .warning,
            title: "Code signature",
            detail: !isValid ? "The app signature is missing or invalid. Reinstall a signed release."
                : expected ? "Valid Zonal signature · team XW6G452649"
                : "Unexpected signing identity: \(identifier ?? "none") · team \(team ?? "none (ad-hoc)"). Permissions may belong to a different copy."
        )
    }

    func automationFinding(isRunning: Bool) -> ZonalHealthFinding {
        ZonalHealthFinding(
            id: "automation", level: isRunning ? .ok : .warning, title: "Automation service",
            detail: isRunning ? "This Zonal instance is listening for local commands."
                : "This Zonal instance has no running automation service."
        )
    }
}

struct FullScreenCompanionPolicy {
    func canUseCache(
        isFullScreen: Bool, focusedIdentity: WindowIdentity?, cachedIdentities: [WindowIdentity],
        cachedProfileID: String, currentProfileID: String,
        cachedDisplays: DisplaySnapshot, currentDisplays: DisplaySnapshot
    ) -> Bool {
        guard isFullScreen, let focusedIdentity, cachedProfileID == currentProfileID,
              cachedDisplays.displays.count == currentDisplays.displays.count,
              cachedDisplays.displays.allSatisfy({ cached in
                  currentDisplays.displays.contains {
                      $0.id == cached.id && $0.persistentID == cached.persistentID
                          && $0.frame == cached.frame && $0.scale == cached.scale
                  }
              }) else { return false }
        return cachedIdentities.filter { $0.matchesSameLiveWindow(as: focusedIdentity) }.count == 1
    }

    func usesNativeSwitcher(isFullScreen: Bool, hasCompanion: Bool, fallbackEnabled: Bool) -> Bool {
        isFullScreen && !hasCompanion && fallbackEnabled
    }
}

struct ScreenFrameCandidate: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
}

struct PointerScreenSelectionPolicy {
    func visibleFrame(
        containing pointer: CGPoint,
        candidates: [ScreenFrameCandidate],
        fallback: CGRect
    ) -> CGRect {
        candidates.first { $0.frame.contains(pointer) }?.visibleFrame ?? fallback
    }
}

enum FloatingHUDCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeading, bottomTrailing, topLeading, topTrailing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        }
    }
}

struct FloatingHUDPlacementPolicy {
    func frame(
        visibleFrame: CGRect,
        panelSize: CGSize,
        effectOutset: CGFloat,
        surfaceInset: CGFloat,
        corner: FloatingHUDCorner
    ) -> CGRect {
        let x: CGFloat
        switch corner {
        case .bottomLeading, .topLeading:
            x = visibleFrame.minX + surfaceInset - effectOutset
        case .bottomTrailing, .topTrailing:
            x = visibleFrame.maxX - panelSize.width - surfaceInset + effectOutset
        }
        return CGRect(
            x: x,
            y: corner == .topLeading || corner == .topTrailing
                ? visibleFrame.maxY - panelSize.height - surfaceInset + effectOutset
                : visibleFrame.minY + surfaceInset - effectOutset,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}

struct SwitcherHostingReusePolicy {
    func shouldCreateHostingView(
        hasHostingView: Bool,
        hasPresentationState: Bool
    ) -> Bool {
        !hasHostingView || !hasPresentationState
    }
}

enum ZoneSnapAxis: Equatable {
    case horizontal
    case vertical
}

struct ZoneSnapGuide: Equatable {
    var axis: ZoneSnapAxis
    var position: Double
    var label: String
}

struct ZoneSnapResult: Equatable {
    var frame: NormalizedFrame
    var guides: [ZoneSnapGuide]
}

struct ZoneGeometrySnappingPolicy {
    func snappedDrag(
        proposed: NormalizedFrame,
        movingZoneID: ZoneID,
        zones: [Zone],
        horizontalThreshold: Double,
        verticalThreshold: Double,
        isDisabled: Bool
    ) -> ZoneSnapResult {
        guard !isDisabled else {
            return ZoneSnapResult(frame: proposed.roundedToPercentStep(), guides: [])
        }
        let candidates = snapCandidates(excluding: movingZoneID, zones: zones)
        let horizontal = closestAlignment(
            movingEdges: [proposed.x, proposed.x + proposed.width],
            candidates: candidates.horizontal,
            threshold: horizontalThreshold
        )
        let vertical = closestAlignment(
            movingEdges: [proposed.y, proposed.y + proposed.height],
            candidates: candidates.vertical,
            threshold: verticalThreshold
        )
        let frame = NormalizedFrame(
            x: proposed.x + (horizontal?.delta ?? 0),
            y: proposed.y + (vertical?.delta ?? 0),
            width: proposed.width,
            height: proposed.height
        ).roundedToPercentStep()
        return ZoneSnapResult(
            frame: frame,
            guides: guides(horizontal: horizontal, vertical: vertical)
        )
    }

    func snappedBottomRightResize(
        proposed: NormalizedFrame,
        resizingZoneID: ZoneID,
        zones: [Zone],
        horizontalThreshold: Double,
        verticalThreshold: Double,
        isDisabled: Bool
    ) -> ZoneSnapResult {
        guard !isDisabled else {
            return ZoneSnapResult(frame: proposed.roundedToPercentStep(), guides: [])
        }
        let candidates = snapCandidates(excluding: resizingZoneID, zones: zones)
        let horizontal = closestAlignment(
            movingEdges: [proposed.x + proposed.width],
            candidates: candidates.horizontal,
            threshold: horizontalThreshold
        )
        let vertical = closestAlignment(
            movingEdges: [proposed.y + proposed.height],
            candidates: candidates.vertical,
            threshold: verticalThreshold
        )
        let frame = NormalizedFrame(
            x: proposed.x,
            y: proposed.y,
            width: proposed.width + (horizontal?.delta ?? 0),
            height: proposed.height + (vertical?.delta ?? 0)
        ).roundedToPercentStep()
        return ZoneSnapResult(
            frame: frame,
            guides: guides(horizontal: horizontal, vertical: vertical)
        )
    }

    private struct Candidate {
        var position: Double
        var label: String
    }

    private struct Alignment {
        var delta: Double
        var candidate: Candidate
    }

    private func snapCandidates(
        excluding excludedZoneID: ZoneID,
        zones: [Zone]
    ) -> (horizontal: [Candidate], vertical: [Candidate]) {
        var horizontal = [
            Candidate(position: 0, label: "Display edge"),
            Candidate(position: 1, label: "Display edge"),
        ]
        var vertical = horizontal
        for zone in zones where zone.id != excludedZoneID {
            horizontal.append(Candidate(position: zone.frame.x, label: zone.name))
            horizontal.append(Candidate(position: zone.frame.x + zone.frame.width, label: zone.name))
            vertical.append(Candidate(position: zone.frame.y, label: zone.name))
            vertical.append(Candidate(position: zone.frame.y + zone.frame.height, label: zone.name))
        }
        return (horizontal, vertical)
    }

    private func closestAlignment(
        movingEdges: [Double],
        candidates: [Candidate],
        threshold: Double
    ) -> Alignment? {
        movingEdges.flatMap { edge in
            candidates.map { candidate in
                Alignment(delta: candidate.position - edge, candidate: candidate)
            }
        }
        .filter { abs($0.delta) <= threshold }
        .min { abs($0.delta) < abs($1.delta) }
    }

    private func guides(
        horizontal: Alignment?,
        vertical: Alignment?
    ) -> [ZoneSnapGuide] {
        var result: [ZoneSnapGuide] = []
        if let horizontal {
            result.append(ZoneSnapGuide(
                axis: .vertical,
                position: horizontal.candidate.position,
                label: horizontal.candidate.label
            ))
        }
        if let vertical {
            result.append(ZoneSnapGuide(
                axis: .horizontal,
                position: vertical.candidate.position,
                label: vertical.candidate.label
            ))
        }
        return result
    }
}

struct ZoneSharedBoundaryPolicy {
    func resizedLayout(
        zoneID: ZoneID,
        from originalFrames: [ZoneID: NormalizedFrame],
        to proposedFrame: NormalizedFrame,
        linkHorizontalBoundary: Bool,
        linkVerticalBoundary: Bool,
        adjacencyTolerance: Double = 0.005
    ) -> [ZoneID: NormalizedFrame] {
        guard let original = originalFrames[zoneID] else { return originalFrames }
        var result = originalFrames
        var selected = proposedFrame

        if linkHorizontalBoundary {
            let neighbors = originalFrames.filter { candidateID, candidate in
                candidateID != zoneID
                    && abs(candidate.x - (original.x + original.width)) <= adjacencyTolerance
                    && overlaps(
                        original.y...(original.y + original.height),
                        candidate.y...(candidate.y + candidate.height)
                    )
            }
            if let limitingMaxX = neighbors.values.map({ $0.x + $0.width - 0.05 }).min() {
                selected.width = min(selected.width, limitingMaxX - selected.x)
            }
            let boundary = selected.x + selected.width
            for (candidateID, candidate) in neighbors {
                let fixedMaxX = candidate.x + candidate.width
                result[candidateID] = NormalizedFrame(
                    x: boundary,
                    y: candidate.y,
                    width: fixedMaxX - boundary,
                    height: candidate.height
                ).roundedToPercentStep()
            }
        }

        if linkVerticalBoundary {
            let neighbors = originalFrames.filter { candidateID, candidate in
                candidateID != zoneID
                    && abs(candidate.y - (original.y + original.height)) <= adjacencyTolerance
                    && overlaps(
                        original.x...(original.x + original.width),
                        candidate.x...(candidate.x + candidate.width)
                    )
            }
            if let limitingMaxY = neighbors.values.map({ $0.y + $0.height - 0.05 }).min() {
                selected.height = min(selected.height, limitingMaxY - selected.y)
            }
            let boundary = selected.y + selected.height
            for (candidateID, candidate) in neighbors {
                let fixedMaxY = candidate.y + candidate.height
                var updated = result[candidateID] ?? candidate
                updated.y = boundary
                updated.height = fixedMaxY - boundary
                result[candidateID] = updated.roundedToPercentStep()
            }
        }

        result[zoneID] = selected.roundedToPercentStep()
        return result
    }

    private func overlaps(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> Bool {
        min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound) > 0.01
    }
}

struct SwitcherFilterPolicy {
    func filtered(_ model: WorkspaceSnapshotModel, query: String) -> WorkspaceSnapshotModel {
        let tokens = normalizedTokens(query)
        guard !tokens.isEmpty else { return model }

        var filtered = model
        filtered.zones = model.zones.map { zone in
            var next = zone
            next.items = zone.items.filter { matches($0, tokens: tokens) }
            return next
        }
        let matches = filtered.zones.flatMap(\.items)
        if !matches.contains(where: { $0.identity == model.selectedWindowID }),
           let first = matches.first {
            filtered.selectedWindowID = first.identity
            filtered.selectedZoneID = first.zoneID
        } else if matches.isEmpty {
            filtered.selectedWindowID = nil
        }
        return filtered
    }

    func matches(_ item: SwitcherItem, query: String) -> Bool {
        matches(item, tokens: normalizedTokens(query))
    }

    private func matches(_ item: SwitcherItem, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = normalized([item.appName, item.title ?? ""].joined(separator: " "))
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func normalizedTokens(_ query: String) -> [String] {
        normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

struct SwitcherTextInputPolicy {
    func acceptedText(_ charactersIgnoringModifiers: String?) -> String? {
        guard let charactersIgnoringModifiers,
              !charactersIgnoringModifiers.isEmpty,
              charactersIgnoringModifiers.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
              }) else {
            return nil
        }
        return charactersIgnoringModifiers
    }
}

struct SwitcherHoverActivationPolicy {
    var minimumMovement: CGFloat = 0.5

    func shouldActivate(pointerLocation: CGPoint, since anchor: CGPoint) -> Bool {
        hypot(pointerLocation.x - anchor.x, pointerLocation.y - anchor.y) >= minimumMovement
    }
}

extension CGRect {
    func matchesPlacement(to other: CGRect, sizeTolerance: CGFloat = 2) -> Bool {
        // Placement targets are point-aligned; allow arithmetic noise, never a visible position offset.
        abs(minX - other.minX) <= 0.01
            && abs(minY - other.minY) <= 0.01
            && abs(width - other.width) <= sizeTolerance
            && abs(height - other.height) <= sizeTolerance
    }

    func isClose(to other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}

protocol ZonalClock {
    var now: Date { get }
}

struct SystemZonalClock: ZonalClock {
    var now: Date { Date() }
}

struct FocusObservationPolicy {
    func accepts(
        observedProcessIdentifier: pid_t?,
        expectedProcessIdentifier: pid_t?
    ) -> Bool {
        guard let expectedProcessIdentifier else { return true }
        return observedProcessIdentifier == expectedProcessIdentifier
    }

    func shouldRecord(
        previousWindowID: LiveWindowID?,
        observedWindowID: LiveWindowID,
        recordEvenIfUnchanged: Bool
    ) -> Bool {
        recordEvenIfUnchanged || previousWindowID != observedWindowID
    }
}

struct SessionDisplayExpectation: Equatable {
    var profileID: String
    var setupBindingID: UUID
    var signature: DisplaySignature
}

enum SessionDisplayReadinessDecision: Equatable {
    case waiting
    case ready
    case timedOut
}

struct SessionDisplayReadinessState: Equatable {
    var requiredStableSamples = 2
    // A configured destination can finish immediately after settling; allow slow wake hardware to appear.
    var timeout: TimeInterval = 30
    var changedSetupSettleDelay: TimeInterval = 1.7

    private var candidate: SessionDisplayExpectation?
    private var candidateSince: Date?
    private(set) var readyDestination: SessionDisplayExpectation?
    private(set) var expectation: SessionDisplayExpectation?
    private(set) var startedAt: Date?
    private(set) var stableSamples = 0

    mutating func begin(expectation: SessionDisplayExpectation?, now: Date) {
        self.expectation = expectation
        startedAt = now
        invalidateCandidate()
    }

    mutating func invalidateCandidate() {
        candidate = nil
        candidateSince = nil
        readyDestination = nil
        stableSamples = 0
    }

    var usesFrozenTargets: Bool { readyDestination != nil && readyDestination == expectation }

    mutating func observe(
        profileID: String?,
        setupBindingID: UUID?,
        signature: DisplaySignature,
        now: Date
    ) -> SessionDisplayReadinessDecision {
        guard let startedAt else { return .timedOut }
        guard let profileID, let setupBindingID else {
            invalidateCandidate()
            return now.timeIntervalSince(startedAt) >= timeout ? .timedOut : .waiting
        }
        let destination = SessionDisplayExpectation(profileID: profileID,
            setupBindingID: setupBindingID, signature: signature)
        if candidate != destination {
            invalidateCandidate()
            candidate = destination
            candidateSince = now
        }
        stableSamples += 1
        let settled = destination == expectation
            || now.timeIntervalSince(candidateSince ?? now) >= changedSetupSettleDelay
        if settled && stableSamples >= requiredStableSamples {
            readyDestination = destination
            return .ready
        }
        return now.timeIntervalSince(startedAt) >= timeout ? .timedOut : .waiting
    }

    mutating func finish() {
        expectation = nil
        startedAt = nil
        invalidateCandidate()
    }
}

struct RestorePlanCandidate: Equatable {
    var windowID: LiveWindowID
    var identity: WindowIdentity
    var currentFrame: CGRect
    var targetFrame: CGRect
    var containerFrame: CGRect
}

struct WorkspaceRestoreTarget: Equatable {
    var frame: CGRect
    var container: CGRect
}

// Unlock can precede didWake; a wake while active must also schedule recovery.
struct SessionRecoverySignalPolicy {
    enum Signal { case inactive, active, displaySleep, wake }
    enum Action { case freeze, restore }
    private(set) var isSessionActive = true
    private(set) var areDisplaysAsleep = false
    var canPresentTabs: Bool { isSessionActive && !areDisplaysAsleep }

    mutating func action(for signal: Signal) -> Action {
        switch signal {
        case .inactive: isSessionActive = false; return .freeze
        case .active: isSessionActive = true; areDisplaysAsleep = false; return .restore
        case .displaySleep: areDisplaysAsleep = true; return .freeze
        case .wake: areDisplaysAsleep = false; return isSessionActive ? .restore : .freeze
        }
    }
}

struct SessionRecoveryState: Equatable {
    private(set) var isActive = false
    private(set) var isInventoryReady = false
    private(set) var hasRestoreStarted = false
    private(set) var userAdjustedWindowIDs = Set<LiveWindowID>()

    @discardableResult
    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        isInventoryReady = false
        hasRestoreStarted = false
        userAdjustedWindowIDs.removeAll()
        return true
    }

    @discardableResult
    mutating func markInventoryReady() -> Bool {
        guard isActive, !isInventoryReady else { return false }
        isInventoryReady = true
        return true
    }

    mutating func beginRestore() -> Bool {
        guard isActive, isInventoryReady, !hasRestoreStarted else { return false }
        hasRestoreStarted = true
        return true
    }

    mutating func retryRestore() { hasRestoreStarted = false }

    mutating func recordUserAdjustment(to windowID: LiveWindowID) {
        guard isActive else { return }
        userAdjustedWindowIDs.insert(windowID)
    }

    func shouldRestore(_ windowID: LiveWindowID) -> Bool {
        !userAdjustedWindowIDs.contains(windowID)
    }

    mutating func finish() {
        isActive = false
        isInventoryReady = false
        hasRestoreStarted = false
        userAdjustedWindowIDs.removeAll()
    }
}

struct DisplayTransitionState {
    private(set) var generation: UUID?
    private var userAdjustedWindowIDs = Set<LiveWindowID>()

    mutating func begin() -> UUID {
        let next = UUID()
        generation = next
        return next
    }

    mutating func recordUserAdjustment(to windowID: LiveWindowID) {
        if generation != nil { userAdjustedWindowIDs.insert(windowID) }
    }

    func shouldRestore(_ windowID: LiveWindowID) -> Bool {
        !userAdjustedWindowIDs.contains(windowID)
    }

    @discardableResult
    mutating func finish(generation expected: UUID) -> Bool {
        guard generation == expected else { return false }
        generation = nil
        userAdjustedWindowIDs.removeAll()
        return true
    }
}

struct CustomFrameCapturePolicy {
    func shouldCapture(
        isSessionRecoveryActive: Bool,
        isApplyingPlacement: Bool,
        hasActiveUserInteraction: Bool,
        isFullScreen: Bool,
        isMinimized: Bool,
        isDisplayTransitionActive: Bool = false
    ) -> Bool {
        !isSessionRecoveryActive
            && !isDisplayTransitionActive
            && !isApplyingPlacement
            && !hasActiveUserInteraction
            && !isFullScreen
            && !isMinimized
    }
}

struct RestorePlan: Equatable {
    var moves: [RestorePlanCandidate]
    var unchangedWindowIDs: [LiveWindowID]
}

struct RestorePlanner {
    func plan(_ candidates: [RestorePlanCandidate]) -> RestorePlan {
        var moves: [RestorePlanCandidate] = []
        var unchanged: [LiveWindowID] = []
        for candidate in candidates {
            if PlacementNoOpPolicy.shouldSkip(actual: candidate.currentFrame, target: candidate.targetFrame) {
                unchanged.append(candidate.windowID)
            } else {
                moves.append(candidate)
            }
        }
        return RestorePlan(moves: moves, unchangedWindowIDs: unchanged)
    }
}

struct ZonePeekStackLayoutPolicy {
    var preferredPeekWidth: CGFloat = 48
    var maximumPeekFraction: CGFloat = 0.4

    func frames(
        in zoneFrame: CGRect,
        assignmentIDs: [UUID],
        activeAssignmentID: UUID?,
        direction: ZonePeekDirection = .left
    ) -> [UUID: CGRect] {
        guard assignmentIDs.count > 1 else {
            return assignmentIDs.first.map { [$0: zoneFrame] } ?? [:]
        }
        var ordered = assignmentIDs
        if let activeAssignmentID,
           let index = ordered.firstIndex(of: activeAssignmentID) {
            ordered.remove(at: index)
            ordered.append(activeAssignmentID)
        }
        let peek = min(
            preferredPeekWidth,
            (direction == .top || direction == .bottom ? zoneFrame.height : zoneFrame.width)
                * maximumPeekFraction / CGFloat(ordered.count - 1)
        )
        let reserved = CGFloat(ordered.count - 1) * peek
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { index, id in
            let offset = CGFloat(index) * peek
            var frame = zoneFrame
            switch direction {
            case .left: frame.origin.x += offset; frame.size.width -= reserved
            case .right: frame.origin.x += reserved - offset; frame.size.width -= reserved
            case .top: frame.origin.y += offset; frame.size.height -= reserved
            case .bottom: frame.origin.y += reserved - offset; frame.size.height -= reserved
            }
            return (id, frame)
        })
    }
}

struct ConfigurationEditor {
    func sanitized(_ input: ZonalConfiguration) -> ZonalConfiguration {
        var configuration = input.profiles.isEmpty ? .default : input
        ensureEveryProfileContainsEveryZone(&configuration)

        var seenProfileIDs = Set<String>()
        for profileIndex in configuration.profiles.indices {
            var profile = configuration.profiles[profileIndex]
            if profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || seenProfileIDs.contains(profile.id) {
                profile.id = uniqueProfileID(in: configuration, excluding: seenProfileIDs)
            }
            seenProfileIDs.insert(profile.id)
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = "Profile \(profileIndex + 1)"
            }
            if profile.zones.isEmpty {
                profile.zones = [Zone(id: .main, name: "Main", frame: .full)]
            }

            var seenZoneIDs = Set<ZoneID>()
            for zoneIndex in profile.zones.indices {
                if seenZoneIDs.contains(profile.zones[zoneIndex].id) {
                    profile.zones[zoneIndex].id = uniqueZoneID(
                        in: configuration,
                        excluding: seenZoneIDs
                    )
                }
                seenZoneIDs.insert(profile.zones[zoneIndex].id)
                if profile.zones[zoneIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.zones[zoneIndex].name = "Zone \(zoneIndex + 1)"
                }
                profile.zones[zoneIndex].tabBorderWidth = ZoneTabMetrics.clampedBorderWidth(profile.zones[zoneIndex].tabBorderWidth)
                profile.zones[zoneIndex].frame = profile.zones[zoneIndex].frame.roundedToPercentStep()
                if profile.zones[zoneIndex].displayRoleID == nil,
                   let firstRoleID = profile.displayRoles.first?.id {
                    profile.zones[zoneIndex].displayRoleID = firstRoleID
                }
            }
            if !profile.zones.contains(where: { $0.id == profile.mainZoneID }) {
                profile.mainZoneID = profile.zones.first?.id ?? .main
            }
            configuration.profiles[profileIndex] = profile
        }

        if configuration.activeProfileID.flatMap({ activeID in
            configuration.profiles.first { $0.id == activeID }?.id
        }) == nil {
            configuration.activeProfileID = configuration.profiles.first?.id
        }
        let validZoneIDs = Set(configuration.profiles.first?.zones.map(\.id) ?? [])
        configuration.hotkeys.removeAll { hotkey in
            if case .restore = hotkey.command { return true }
            guard let zoneID = zoneID(for: hotkey.command) else { return false }
            return !validZoneIDs.contains(zoneID)
        }
        configuration.schemaVersion = 5
        configuration.activeWindowOutlineWidth = min(
            8,
            max(1, configuration.activeWindowOutlineWidth)
        )
        configuration.excludedBundleIdentifiers = Array(
            Set(configuration.excludedBundleIdentifiers.filter { !$0.isEmpty })
        ).sorted()
        var seenRuleBundles = Set<String>()
        configuration.windowDefaultZoneRules = configuration.windowDefaultZoneRules.filter { rule in
            !rule.bundleIdentifier.isEmpty
                && validZoneIDs.contains(rule.zoneID)
                && seenRuleBundles.insert(rule.bundleIdentifier).inserted
        }
        return configuration
    }

    func ensureEveryProfileContainsEveryZone(_ configuration: inout ZonalConfiguration) {
        var orderedZoneIDs: [ZoneID] = []
        var canonicalZones: [ZoneID: Zone] = [:]
        for zone in configuration.profiles.flatMap(\.zones) where canonicalZones[zone.id] == nil {
            orderedZoneIDs.append(zone.id)
            canonicalZones[zone.id] = zone
        }
        for profileIndex in configuration.profiles.indices {
            for zoneID in orderedZoneIDs
                where !configuration.profiles[profileIndex].zones.contains(where: { $0.id == zoneID }) {
                if let zone = canonicalZones[zoneID] {
                    configuration.profiles[profileIndex].zones.append(
                        Zone(
                            id: zone.id,
                            name: zone.name,
                            frame: .full,
                            windowPresentation: zone.windowPresentation,
                            peekWidth: zone.peekWidth,
                            peekDirection: zone.peekDirection,
                            tabStyle: zone.tabStyle,
                            tabBorderWidth: zone.tabBorderWidth
                        )
                    )
                }
            }
        }
    }

    private func uniqueProfileID(
        in configuration: ZonalConfiguration,
        excluding excluded: Set<String>
    ) -> String {
        let existing = Set(configuration.profiles.map(\.id)).union(excluded)
        var index = configuration.profiles.count + 1
        while existing.contains("profile-\(index)") { index += 1 }
        return "profile-\(index)"
    }

    private func uniqueZoneID(
        in configuration: ZonalConfiguration,
        excluding excluded: Set<ZoneID>
    ) -> ZoneID {
        let existing = Set(configuration.profiles.first?.zones.map(\.id) ?? []).union(excluded)
        var index = (configuration.profiles.first?.zones.count ?? 0) + 1
        while existing.contains(ZoneID(rawValue: "zone-\(index)")) { index += 1 }
        return ZoneID(rawValue: "zone-\(index)")
    }

    private func zoneID(for command: HotkeyCommand) -> ZoneID? {
        switch command {
        case .focusZone(let zoneID), .moveFocusedWindow(let zoneID): zoneID
        default: nil
        }
    }
}
