import AppKit
import Foundation
import OSLog

@MainActor
final class WorkspaceStateService {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WorkspaceState")

    private let profileManager: ProfileManager
    private let layoutEngine: LayoutEngine
    private let windowRegistry: WindowRegistry
    private let windowTracker: WindowTracker
    private let windowController: WindowController
    private let store: PersistenceStore

    private var selectedAssignmentID: UUID?
    private var selectedZoneID: ZoneID = .center
    private var currentMode: SwitcherMode = .allWindows
    private var focusVerificationGeneration: UUID?
    private var preparedFocusWindowID: LiveWindowID?
    var onWindowsChanged: (() -> Void)?
    var onWindowInventoryChanged: (([ManagedWindow]) -> Void)?
    var onOutlineEnvironmentChanged: ((ManagedWindow?) -> Void)?
    var onTrackedWindowFrameChanged: ((ManagedWindow) -> Void)?
    var onZonePresentationNeedsLayout: ((ZoneID) -> Void)?
    var onFocusedWindowChanged: ((ManagedWindow?) -> Void)?
    var onSwitcherFocusConfirmed: ((ManagedWindow) -> Void)?
    var onFocusRequest: (() -> Void)?
    private var switcherFocusGeneration: UUID?
    var onWindowGeometryChanged: ((ManagedWindow) -> Void)?
    private var pendingFrameUpdates: [LiveWindowID: DispatchWorkItem] = [:]
    private var sessionHeuristicRecoveries = 0
    private var sessionPlacementRecoveries = 0
    private var sessionDuplicateAssignmentsMerged = 0
    private var sessionNewAssignments = 0
    private var sessionUnresolvedSameAppAssignments = 0
    private var knownFocusFastPaths = 0
    private var focusEventSequence: UInt64 = 0
    private var deferredFocusEvents: [DeferredFocusEvent] = []
    private var focusHistoryBaseline = ZoneStackState.empty
    private var sessionRecovery = SessionRecoveryState()
    private var displayTransition = DisplayTransitionState()
    var displayTransitionGeneration: UUID? { displayTransition.generation }
    var isDisplayTransitionActive: Bool { displayTransitionGeneration != nil }
    private var lastRegularSpaceContext: WorkspaceContext?
    private var cachedContext: WorkspaceContext?
    private var inventoryWindowIDs = Set<LiveWindowID>()
    private var focusedIsFullScreen = false
    private var observedFrames: [LiveWindowID: CGRect] = [:]
    var onPersistenceFailure: (() -> Void)?
    var onManualAssignment: ((UUID, ZoneID, Bool) -> Void)?

    init(
        profileManager: ProfileManager,
        layoutEngine: LayoutEngine,
        windowRegistry: WindowRegistry,
        windowTracker: WindowTracker,
        windowController: WindowController,
        store: PersistenceStore
    ) {
        self.profileManager = profileManager
        self.layoutEngine = layoutEngine
        self.windowRegistry = windowRegistry
        self.windowTracker = windowTracker
        self.windowController = windowController
        self.store = store
    }

    func start() {
        focusHistoryBaseline = store.loadZoneStackState()
        focusEventSequence = 0
        deferredFocusEvents.removeAll()
        windowTracker.onFocusChanged = { [weak self] window in
            if let window {
                self?.markWindowFocused(window)
            } else {
                self?.focusedIsFullScreen = false
                self?.onFocusedWindowChanged?(nil)
            }
        }
        windowTracker.onWindowsChanged = { [weak self] windows in
            let currentIDs = Set(self?.windowTracker.currentSpaceWindows.map(\.id) ?? [])
            let previousWindows = Dictionary(uniqueKeysWithValues: (self?.cachedContext?.windows ?? []).map { ($0.id, $0) })
            let changedPresentationIDs = Set(windows.compactMap { window -> LiveWindowID? in
                guard let previous = previousWindows[window.id],
                      previous.isMinimized != window.isMinimized || previous.isFullScreen != window.isFullScreen else { return nil }
                return window.id
            })
            let changedIDs = (self?.inventoryWindowIDs ?? []).symmetricDifference(currentIDs).union(changedPresentationIDs)
            let previousZones = Set(self?.cachedContext?.windows.filter { changedIDs.contains($0.id) }
                .compactMap { self?.assignment(for: $0)?.zoneID } ?? [])
            self?.inventoryWindowIDs = currentIDs
            self?.windowController.retainWindows(windows)
            self?.reconcile()
            self?.projectObservedFocusEvents()
            if !changedIDs.isEmpty, let self {
                self.preparedFocusWindowID = nil
                let context = self.workspaceContext()
                let changedZones = previousZones.union(context.windows.filter { changedIDs.contains($0.id) }
                    .compactMap { self.assignment(for: $0, context: context)?.zoneID })
                for zone in context.profile.zones where (zone.windowPresentation != .overlap || self.tabOwner(for: zone, context: context) != nil) && changedZones.contains(zone.id) {
                    self.onZonePresentationNeedsLayout?(zone.id)
                }
            }
            self?.onWindowsChanged?()
            self?.onWindowInventoryChanged?(self?.windowTracker.currentSpaceWindows ?? [])
            self?.onFocusedWindowChanged?(self?.windowTracker.focusedWindow)
        }
        windowTracker.onWindowFrameChanged = { [weak self] window in
            if let self {
                if !self.windowController.isApplyingPlacement(to: window) {
                    self.preparedFocusWindowID = nil
                }
                self.observedFrames[window.id] = self.windowRegistry.cgBounds(for: window)
                if self.windowTracker.focusedWindow?.id == window.id {
                    self.focusedIsFullScreen = self.windowController.isFullScreen(window)
                }
            }
            self?.scheduleCustomFrameCapture(for: window)
            self?.onTrackedWindowFrameChanged?(window)
            self?.onWindowGeometryChanged?(window)
        }
        windowTracker.onDisplayInventorySettled = { [weak self] in
            guard let self else { return }
            self.reconcile()
            if !self.isSessionRecoveryActive {
                self.onOutlineEnvironmentChanged?(self.windowTracker.focusedWindow)
            }
        }
        windowTracker.start()
        reconcile()
    }

    func stop() {
        _ = store.flushPendingWorkspaceWrite()
        windowTracker.onDisplayInventorySettled = nil
        windowTracker.onFocusChanged = nil
        windowTracker.onWindowsChanged = nil
        onWindowInventoryChanged = nil
        onOutlineEnvironmentChanged = nil
        windowTracker.onWindowFrameChanged = nil
        onTrackedWindowFrameChanged = nil
        onZonePresentationNeedsLayout = nil
        onFocusedWindowChanged = nil
        onSwitcherFocusConfirmed = nil
        onFocusRequest = nil
        onWindowGeometryChanged = nil
        switcherFocusGeneration = nil
        focusVerificationGeneration = nil
        preparedFocusWindowID = nil
        deferredFocusEvents.removeAll()
        focusEventSequence = 0
        for item in pendingFrameUpdates.values {
            item.cancel()
        }
        pendingFrameUpdates.removeAll()
        sessionRecovery.finish()
        displayTransition = DisplayTransitionState()
        lastRegularSpaceContext = nil
        cachedContext = nil
        inventoryWindowIDs.removeAll()
        focusedIsFullScreen = false
        observedFrames.removeAll()
        windowTracker.stop()
        windowController.retainWindows([])
    }

    @discardableResult
    func beginSessionRecovery() -> Bool {
        cancelPendingFocus()
        let started = sessionRecovery.begin()
        guard started else { return false }
        for item in pendingFrameUpdates.values {
            item.cancel()
        }
        pendingFrameUpdates.removeAll()
        if let generation = displayTransitionGeneration { finishDisplayTransition(generation: generation) }
        return true
    }

    @discardableResult
    func beginDisplayTransition() -> UUID {
        cancelPendingFocus()
        for item in pendingFrameUpdates.values { item.cancel() }
        pendingFrameUpdates.removeAll()
        let generation = displayTransition.begin()
        if isSessionRecoveryActive {
            for id in sessionRecovery.userAdjustedWindowIDs { displayTransition.recordUserAdjustment(to: id) }
        }
        return generation
    }

    func finishDisplayTransition(generation: UUID) {
        guard displayTransition.finish(generation: generation) else { return }
        if !isSessionRecoveryActive { onOutlineEnvironmentChanged?(windowTracker.focusedWindow) }
    }

    func shouldRestoreAfterDisplayChange(_ window: ManagedWindow) -> Bool {
        displayTransition.shouldRestore(window.id)
    }

    func finishSessionRecovery() {
        sessionRecovery.finish()
        onOutlineEnvironmentChanged?(windowTracker.focusedWindow)
    }

    func beginSessionRestore() -> Bool {
        sessionRecovery.beginRestore()
    }

    func retrySessionRestore() { sessionRecovery.retryRestore() }

    func markSessionRecoveryInventoryReady() -> Bool {
        sessionRecovery.markInventoryReady()
    }

    func recordUserAdjustmentDuringRecovery(to window: ManagedWindow) {
        sessionRecovery.recordUserAdjustment(to: window.id)
        displayTransition.recordUserAdjustment(to: window.id)
        pendingFrameUpdates[window.id]?.cancel()
        pendingFrameUpdates.removeValue(forKey: window.id)
    }

    func shouldRestoreDuringSessionRecovery(_ window: ManagedWindow) -> Bool {
        sessionRecovery.shouldRestore(window.id)
    }

    var isSessionRecoveryActive: Bool {
        sessionRecovery.isActive
    }

    func restoreTargetsByAssignmentID() -> [UUID: WorkspaceRestoreTarget] {
        let snapshot = profileManager.currentSnapshot()
        guard let profile = profileManager.matchedProfile(for: snapshot) else { return [:] }
        let context = workspaceContext(snapshot: snapshot, profile: profile)
        let liveAssignments = context.windows.compactMap {
            assignment(for: $0, context: context)
        }
        return Dictionary(uniqueKeysWithValues: context.assignments.compactMap { assignment in
            guard let target = targetFrame(
                for: assignment,
                profile: profile,
                snapshot: snapshot,
                stackAssignments: liveAssignments
            ) else {
                return nil
            }
            return (
                assignment.id,
                WorkspaceRestoreTarget(frame: target.frame, container: target.container)
            )
        })
    }

    func refreshSwitcherSnapshot(mode: SwitcherMode, resetSelection: Bool) -> WorkspaceSnapshotModel {
        let model = switcherSnapshot(mode: mode, resetSelection: resetSelection)
        currentMode = mode
        selectedZoneID = model.selectedZoneID
        selectedAssignmentID = model.zones.flatMap(\.items).first { $0.identity == model.selectedWindowID }?.assignmentID
        return model
    }

    func switcherSnapshot(mode: SwitcherMode, resetSelection: Bool = false) -> WorkspaceSnapshotModel {
        var selectedZoneID = self.selectedZoneID
        var selectedAssignmentID = self.selectedAssignmentID
        let currentContext = workspaceContext()
        var context = switcherContext(for: currentContext)
        if let included = WindowDisplayScopePolicy().includedWindowIDs(
            scope: store.loadConfiguration().behavior.switcherDisplayScope,
            focused: windowTracker.focusedWindow?.id, frames: observedFrames,
            displays: context.snapshot.displays.map(\.frame)
        ) {
            context.windows = context.windows.filter { included.contains($0.id) }
        }
        let assignmentByWindowID = assignmentsByWindowID(context: context)
        let state = store.loadZoneStackState()
        let zoneFrames = zoneFrames(context: context)
        let zoneColumns = switcherZoneColumns(context: context, zoneFrames: zoneFrames)
        let focusedAssignmentID = focusedAssignmentID(
            context: context,
            assignmentByWindowID: assignmentByWindowID
        )

        let switcherZones: [SwitcherZone]
        switch mode {
        case .allWindows:
            let focusedZoneID = focusedAssignmentID.flatMap { assignmentID in
                context.assignments.first { $0.id == assignmentID }?.zoneID
            }
            let activeAssignmentIDs = SwitcherActivityPolicy().activeAssignmentIDs(
                state: state,
                focusedAssignmentID: focusedAssignmentID,
                focusedZoneID: focusedZoneID
            )
            let windows = orderedWindows(
                context.windows,
                assignmentByWindowID: assignmentByWindowID,
                history: state.globalRecency,
                currentAssignmentID: focusedAssignmentID
            )
            switcherZones = [
                SwitcherZone(
                    id: ZoneID(rawValue: "all-windows"),
                    name: "",
                    frame: .full,
                    items: items(
                        windows: windows,
                        assignmentByWindowID: assignmentByWindowID,
                        activeAssignmentIDs: activeAssignmentIDs,
                        profile: context.profile
                    )
                )
            ]
        case .byZone:
            let currentZoneID = focusedZoneID(context: context, assignmentByWindowID: assignmentByWindowID)
            var itemsByZoneID: [ZoneID: [SwitcherItem]] = [:]
            for zone in context.profile.zones {
                let windows = context.windows.filter {
                    assignmentByWindowID[$0.id]?.zoneID == zone.id
                }
                let ordered = orderedWindows(
                    windows,
                    assignmentByWindowID: assignmentByWindowID,
                    history: state.assignmentRecencyByZone[zone.id] ?? [],
                    currentAssignmentID: zone.id == currentZoneID
                        ? focusedAssignmentID
                        : state.activeAssignmentByZone[zone.id]
                )
                let activeAssignmentID = zone.id == currentZoneID
                    ? focusedAssignmentID ?? state.activeAssignmentByZone[zone.id]
                    : state.activeAssignmentByZone[zone.id]
                itemsByZoneID[zone.id] = items(
                    windows: ordered,
                    assignmentByWindowID: assignmentByWindowID,
                    activeAssignmentIDs: activeAssignmentID.map { Set([$0]) } ?? [],
                    profile: context.profile
                )
            }
            switcherZones = ZoneSwitcherProjection().zones(
                profileZones: context.profile.zones,
                orderedZoneIDs: zoneColumns.flatMap { $0 },
                itemsByZoneID: itemsByZoneID
            )
            if resetSelection || !switcherZones.contains(where: { $0.id == selectedZoneID }) {
                selectedZoneID = currentZoneID
            }
        }

        let allItems = switcherZones.flatMap(\.items)
        if resetSelection {
            let initialItems: [SwitcherItem]
            if mode == .byZone {
                initialItems = switcherZones.first { $0.id == selectedZoneID }?.items ?? []
            } else {
                initialItems = allItems
            }
            selectedAssignmentID = SwitcherSelectionPolicy().initialAssignmentID(
                in: initialItems.map(\.assignmentID)
            )
            if mode == .allWindows {
                selectedZoneID = allItems.first { $0.assignmentID == selectedAssignmentID }?.zoneID
                    ?? switcherZones.first?.id
                    ?? context.profile.mainZoneID
            }
        } else if !allItems.contains(where: { $0.assignmentID == selectedAssignmentID }) {
            selectedAssignmentID = SwitcherSelectionRecovery().assignmentID(
                current: selectedAssignmentID,
                mode: mode,
                zones: switcherZones,
                selectedZoneID: selectedZoneID
            )
            if mode == .allWindows {
                selectedZoneID = allItems.first?.zoneID ?? switcherZones.first?.id ?? context.profile.mainZoneID
            }
        }

        let selectedIdentity = allItems.first { $0.assignmentID == selectedAssignmentID }?.identity
        return WorkspaceSnapshotModel(
            showSwitcherShortcutGuide: store.loadConfiguration().behavior.showSwitcherShortcutGuide,
            nextWindowShortcutKeys: HotkeyBinding.nextWindowShortcutKeys(
                mode: mode, bindings: store.loadConfiguration().hotkeys,
                useNativeCommandTab: store.loadConfiguration().useNativeCommandTab || shouldUseNativeSwitcherInFullScreen()
            ),
            mode: mode,
            zones: switcherZones,
            zoneColumns: mode == .allWindows ? [switcherZones.map(\.id)] : zoneColumns,
            selectedZoneID: selectedZoneID,
            selectedWindowID: selectedIdentity,
            outlineStyle: WindowOutlineStyle(configuration: store.loadConfiguration())
        )
    }

    @discardableResult
    func focusNextWindow(direction: Int) -> Bool {
        let model = refreshSwitcherSnapshot(mode: .byZone, resetSelection: true)
        let selected = selectRelativeWindow(direction: direction, model: model)
        guard selected.selectedWindowID != nil else { return false }
        focusSelectedWindow()
        return true
    }

    @discardableResult
    func selectRelativeWindow(
        direction: Int,
        model: WorkspaceSnapshotModel? = nil
    ) -> WorkspaceSnapshotModel {
        let model = model ?? refreshSwitcherSnapshot(mode: currentMode, resetSelection: false)
        let items = SwitcherCycleScope().items(
            mode: currentMode,
            zones: model.zones,
            selectedZoneID: selectedZoneID
        )
        guard !items.isEmpty else { return projectSelection(onto: model) }
        let currentIndex = selectedAssignmentID.flatMap { selected in
            items.firstIndex { $0.assignmentID == selected }
        } ?? 0
        let nextIndex = (currentIndex + direction + items.count) % items.count
        selectedAssignmentID = items[nextIndex].assignmentID
        selectedZoneID = items[nextIndex].zoneID
        return projectSelection(onto: model)
    }

    @discardableResult
    func selectVerticalWindow(
        direction: Int,
        model: WorkspaceSnapshotModel? = nil
    ) -> WorkspaceSnapshotModel {
        let model = model ?? refreshSwitcherSnapshot(mode: .byZone, resetSelection: false)
        let items = SwitcherColumnCycleScope().items(
            zones: model.zones,
            columns: model.zoneColumns,
            selectedZoneID: selectedZoneID
        )
        guard !items.isEmpty else { return projectSelection(onto: model) }

        if let selectedAssignmentID,
           let currentIndex = items.firstIndex(where: { $0.assignmentID == selectedAssignmentID }) {
            let nextIndex = (currentIndex + direction + items.count) % items.count
            self.selectedAssignmentID = items[nextIndex].assignmentID
            selectedZoneID = items[nextIndex].zoneID
            return projectSelection(onto: model)
        }

        let candidate = direction < 0 ? items.last : items.first
        selectedAssignmentID = candidate?.assignmentID
        if let candidate {
            selectedZoneID = candidate.zoneID
        }
        return projectSelection(onto: model)
    }

    @discardableResult
    func selectZone(
        in direction: SwitcherArrowKey,
        model: WorkspaceSnapshotModel? = nil
    ) -> WorkspaceSnapshotModel {
        let model = model ?? refreshSwitcherSnapshot(mode: .byZone, resetSelection: false)
        guard let targetZoneID = layoutEngine.neighboringZoneID(
            from: selectedZoneID,
            direction: direction,
            columns: model.zoneColumns
        ) else { return projectSelection(onto: model) }
        selectedZoneID = targetZoneID
        selectedAssignmentID = model.zones
            .first { $0.id == selectedZoneID }?
            .items.first?
            .assignmentID
        return projectSelection(onto: model)
    }

    func assignSelectedWindowToZone(
        in direction: SwitcherArrowKey,
        model: WorkspaceSnapshotModel? = nil
    ) {
        let model = model ?? refreshSwitcherSnapshot(mode: .byZone, resetSelection: false)
        guard let targetZoneID = layoutEngine.neighboringZoneID(
            from: selectedZoneID,
            direction: direction,
            columns: model.zoneColumns
        ) else { return }
        assignSelectedWindow(to: targetZoneID)
    }

    func projectSelection(onto model: WorkspaceSnapshotModel) -> WorkspaceSnapshotModel {
        var projected = model
        let items = model.zones.flatMap(\.items)
        projected.selectedWindowID = items.first {
            $0.assignmentID == selectedAssignmentID
        }?.identity
        projected.selectedZoneID = selectedZoneID
        return projected
    }

    func neighboringZoneID(
        for window: ManagedWindow,
        direction: SwitcherArrowKey
    ) -> ZoneID? {
        let context = workspaceContext()
        let currentZoneID = zone(for: window, context: context)
        let frames = zoneFrames(context: context)
        let columns = switcherZoneColumns(context: context, zoneFrames: frames)
        return layoutEngine.neighboringZoneID(
            from: currentZoneID,
            direction: direction,
            columns: columns
        )
    }

    func assignSelectedWindow(to zoneID: ZoneID) {
        guard let selectedAssignmentID else { return }
        onManualAssignment?(selectedAssignmentID, zoneID, true)
        selectedZoneID = zoneID
    }

    func selectWindow(_ identity: WindowIdentity, in zoneID: ZoneID) {
        let context = workspaceContext()
        let map = assignmentsByWindowID(context: context)
        if let window = context.windows.first(where: { $0.identity == identity }) {
            selectedAssignmentID = map[window.id]?.id
        }
        selectedZoneID = zoneID
    }

    func selectSwitcherItem(assignmentID: UUID, zoneID: ZoneID) {
        selectedAssignmentID = assignmentID
        selectedZoneID = zoneID
    }

    func selectZone(_ zoneID: ZoneID) {
        selectedZoneID = zoneID
        let context = workspaceContext()
        let map = assignmentsByWindowID(context: context)
        selectedAssignmentID = context.windows.compactMap { window -> UUID? in
            guard map[window.id]?.zoneID == zoneID else { return nil }
            return map[window.id]?.id
        }.first
    }

    @discardableResult
    func assignWindow(
        _ window: ManagedWindow,
        to zoneID: ZoneID,
        customFrame: NormalizedFrame? = nil,
        clearCustomFrame: Bool = false,
        customFrameBeforeFit: CGRect? = nil
    ) -> WorkspaceSaveResult {
        let context = workspaceContext()
        guard context.profile.zones.contains(where: { $0.id == zoneID }),
              (!clearCustomFrame && customFrame == nil) || profileManager.matchedProfile(for: context.snapshot) != nil,
              var assignment = assignment(for: window, context: context) else { return .unavailable }
        if clearCustomFrame, !assignment.fitsZone(in: context.profile.id), let frame = customFrameBeforeFit,
           let source = fittedTarget(for: assignment, zoneID: assignment.zoneID, context: context) {
            assignment.savedCustomPlacementsByProfileID[context.profile.id] = ZoneCustomPlacementGeometry.capture(frame, in: source.frame)
        }
        assignment.identity = window.identity
        assignment.fingerprint = window.fingerprint
        assignment.zoneID = zoneID
        assignment.retention = .durable
        let roleID = context.profile.zones.first { $0.id == zoneID }?.displayRoleID ?? .workspace
        if clearCustomFrame {
            assignment.placementsByProfileID[context.profile.id] = .zoneFit(zoneID: zoneID)
        } else if let customFrame {
            assignment.placementsByProfileID[context.profile.id] = .custom(
                zoneID: zoneID,
                displayRoleID: roleID,
                normalizedDisplayFrame: customFrame
            )
        } else {
            assignment.placementsByProfileID[context.profile.id] = .unplaced(zoneID: zoneID)
        }
        assignment.updatedAt = Date()
        let captured = customFrame.flatMap { normalized in
            context.profile.zones.first { $0.id == zoneID }.flatMap { display(for: $0, context: context) }
                .map { normalized.rect(in: $0.placementFrame) }
        }
        return commitAssignment(assignment, customFrame: captured)
    }

    @discardableResult
    func assignCustomFrame(
        _ window: ManagedWindow,
        to zoneID: ZoneID,
        frame: CGRect
    ) -> WorkspaceSaveResult {
        let snapshot = profileManager.currentSnapshot()
        guard let profile = profileManager.matchedProfile(for: snapshot) else { return .unavailable }
        let context = workspaceContext(snapshot: snapshot, profile: profile)
        guard var assignment = assignment(for: window, context: context),
              let zone = profile.zones.first(where: { $0.id == zoneID }),
              let display = display(for: zone, context: context) else { return .unavailable }
        let roleID = zone.displayRoleID
            ?? profile.displayRoles.first { role in
                profileManager.display(
                    for: role.id,
                    profile: profile,
                    snapshot: snapshot
                )?.id == display.id
            }?.id
            ?? .workspace
        assignment.identity = window.identity
        assignment.fingerprint = window.fingerprint
        assignment.zoneID = zoneID
        assignment.retention = .durable
        assignment.placementsByProfileID[profile.id] = .custom(
            zoneID: zoneID,
            displayRoleID: roleID,
            normalizedDisplayFrame: NormalizedFrame.relativeFrame(
                for: frame,
                in: display.placementFrame
            )
        )
        assignment.updatedAt = Date()
        return commitAssignment(assignment, customFrame: frame)
    }

    @discardableResult
    func recordCustomFrame(for window: ManagedWindow, frame: CGRect) -> WorkspaceSaveResult {
        let snapshot = profileManager.currentSnapshot()
        // Never write profile-specific geometry while the display setup is
        // unknown. During hot-plug transitions selectedProfile is only an
        // editing fallback and must not receive live window frames.
        guard let profile = profileManager.matchedProfile(for: snapshot) else { return .unavailable }
        let context = workspaceContext(snapshot: snapshot, profile: profile)
        guard var assignment = assignment(for: window, context: context),
              let zone = context.profile.zones.first(where: { $0.id == assignment.zoneID }) else { return .unavailable }
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        let display = context.snapshot.display(containing: frameCenter)
            ?? display(for: zone, context: context)
        guard let display else { return .unavailable }
        let roleID = context.profile.displayRoles.first { role in
            profileManager.display(
                for: role.id,
                profile: context.profile,
                snapshot: context.snapshot
            )?.id == display.id
        }?.id ?? zone.displayRoleID ?? .workspace
        let normalized = NormalizedFrame.relativeFrame(for: frame, in: display.placementFrame)
        assignment.identity = window.identity
        assignment.fingerprint = window.fingerprint
        assignment.retention = .durable
        assignment.placementsByProfileID[context.profile.id] = .custom(
            zoneID: assignment.zoneID,
            displayRoleID: roleID,
            normalizedDisplayFrame: normalized
        )
        assignment.updatedAt = Date()
        return commitAssignment(assignment, customFrame: frame)
    }

    func tabSnapshots() -> [ZoneTabSnapshot] {
        // Rendering may resume from retained identities before placement recovery finishes.
        guard !focusedIsFullScreen else { return [] }
        let context = workspaceContext()
        guard context.profile.zones.contains(where: { $0.windowPresentation == .tabs }),
              profileManager.matchedProfile(for: context.snapshot) != nil else { return [] }
        let assignmentMap = assignmentsByWindowID(context: context)
        let state = store.loadZoneStackState()
        let focused = focusedAssignmentID(context: context, assignmentByWindowID: assignmentMap)
        return context.profile.zones.compactMap { zone in
            guard zone.windowPresentation == .tabs,
                  tabOwner(for: zone, context: context)?.id == zone.id,
                  let display = display(for: zone, context: context) else { return nil }
            let members = context.profile.zones.filter { tabOwner(for: $0, context: context)?.id == zone.id }
            let shared = members.count > 1
            var itemsByZone: [ZoneID: [SwitcherItem]] = [:]
            var stackItems: [SwitcherItem] = []
            var fittedWindowIDs = Set<LiveWindowID>()
            for member in members {
                let windows = context.windows.filter { window in
                    guard !window.isFullScreen, !window.isMinimized,
                          let assignment = assignmentMap[window.id] else { return false }
                    return assignment.managementMode == .managed && assignment.zoneID == member.id
                }
                let current = focused.flatMap { id in windows.contains { assignmentMap[$0.id]?.id == id } ? id : nil }
                    ?? state.activeAssignmentByZone[member.id]
                let ordered = orderedWindows(windows, assignmentByWindowID: assignmentMap,
                    history: state.assignmentRecencyByZone[member.id] ?? [], currentAssignmentID: current)
                let active = shared ? focused : ordered.first.flatMap { assignmentMap[$0.id]?.id }
                let projected = items(windows: ordered, assignmentByWindowID: assignmentMap,
                    activeAssignmentIDs: active.map { Set([$0]) } ?? [], profile: context.profile)
                stackItems += projected
                itemsByZone[member.id] = projected
                for window in windows where assignmentMap[window.id].map({
                        ZoneReflowPolicy.includes($0, zones: [member.id], profile: context.profile, includeOverlap: true)
                    }) == true {
                    fittedWindowIDs.insert(window.id)
                }
            }
            guard !stackItems.isEmpty else { return nil }
            let zoneByAssignment = Dictionary(uniqueKeysWithValues: stackItems.map { ($0.assignmentID, $0.zoneID) })
            // Keep the last focused member primary when focus leaves this group.
            let primaryZone = focused.flatMap { zoneByAssignment[$0] }
                ?? state.globalRecency.lazy.compactMap { zoneByAssignment[$0] }.first
                ?? (itemsByZone[zone.id]?.isEmpty == false ? zone.id : stackItems[0].zoneID)
            let ownItems = itemsByZone[primaryZone] ?? []
            let otherItems = members.filter { $0.id != primaryZone }.compactMap { itemsByZone[$0.id]?.first }
            return ZoneTabSnapshot(zoneID: zone.id, edge: store.loadConfiguration().tabEdge,
                layout: ZoneTabLayout(zoneFrame: layoutEngine.zoneFrame(for: zone, in: display.placementFrame, spacing: context.profile.zoneSpacing), edge: store.loadConfiguration().tabEdge, style: zone.tabStyle, borderWidth: zone.tabBorderWidth),
                items: ownItems, showsNames: store.loadConfiguration().tabShowsNames, outlineStyle: WindowOutlineStyle(configuration: store.loadConfiguration()),
                hasFittedWindows: !fittedWindowIDs.isEmpty, otherZoneItems: otherItems, stackItems: stackItems,
                fittedWindowIDs: fittedWindowIDs,
                moveDestinations: context.profile.zones.filter { self.display(for: $0, context: context) != nil },
                sizeActions: Dictionary(uniqueKeysWithValues: context.assignments.compactMap { assignment in
                    guard stackItems.contains(where: { $0.assignmentID == assignment.id }) else { return nil }
                    if !assignment.fitsZone(in: context.profile.id) { return (assignment.id, ZoneTabAction.fit) }
                    return assignment.savedCustomPlacementsByProfileID[context.profile.id] == nil
                        ? nil : (assignment.id, ZoneTabAction.restoreCustom)
                }))
        }
    }

    private func tabOwner(for zone: Zone, context: WorkspaceContext) -> Zone? {
        guard let display = display(for: zone, context: context) else { return nil }
        let frame = layoutEngine.zoneFrame(for: zone, in: display.placementFrame, spacing: context.profile.zoneSpacing)
        return ZoneTabGroupPolicy.owner(for: zone, profile: context.profile) { member, other in
            guard member.frame == other.frame,
                  (member.displayRoleID ?? .workspace) == (other.displayRoleID ?? .workspace),
                  let otherDisplay = self.display(for: other, context: context), otherDisplay.id == display.id else { return false }
            return frame.isClose(to: self.layoutEngine.zoneFrame(for: other, in: otherDisplay.placementFrame, spacing: context.profile.zoneSpacing), tolerance: 1)
        }
    }

    func focusTab(assignmentID: UUID) {
        // Resolve the ID captured at mouse-down, independently of subsequent MRU reordering.
        guard tabSnapshots().contains(where: { $0.orderingItems.contains { $0.assignmentID == assignmentID } }) else { return }
        selectedAssignmentID = assignmentID
        focusSelectedWindow()
    }

    func focusSelectedWindow(fromSwitcher: Bool = false) {
        cancelPendingFocus()
        guard let selectedAssignmentID else { return }
        let current = workspaceContext()
        let context = switcherContext(for: current)
        guard let assignment = context.assignments.first(where: { $0.id == selectedAssignmentID }),
              let window = matchedWindow(for: assignment, in: context.windows) else { return }
        let generation = UUID()
        focusVerificationGeneration = generation
        switcherFocusGeneration = fromSwitcher ? generation : nil
        preparedFocusWindowID = nil
        Self.logger.info("handoff.stage=selected window=\(window.id) uptime=\(ProcessInfo.processInfo.systemUptime)")
        let focus = { [weak self] in
            guard let self, self.focusVerificationGeneration == generation else { return }
            Self.logger.info("handoff.stage=nativeFocusRequested window=\(window.id) uptime=\(ProcessInfo.processInfo.systemUptime)")
            self.windowController.focus(window) { [weak self] in
                self?.verifyFocusedSelection(assignmentID: assignment.id, zoneID: assignment.zoneID,
                                            window: window, generation: generation, attempt: 0)
            }
        }
        // Prepare foreground geometry, then dispatch the rest of the stack before
        // native focus. MRU still advances only after focus is confirmed.
        let assignments = current.windows.compactMap { self.assignment(for: $0, context: current) }
        if !isSessionRecoveryActive, !isDisplayTransitionActive,
           current.windows.contains(where: { $0.id == window.id }),
           ZoneReflowPolicy.includes(assignment, zones: [assignment.zoneID], profile: current.profile),
           !windowController.hasActiveUserInteraction,
           !current.windows.contains(where: {
               self.windowController.hasPendingPlacement(to: $0)
                   && self.assignment(for: $0, context: current)?.zoneID == assignment.zoneID
           }),
           !windowController.isFullScreen(window), !windowController.isMinimized(window),
           let target = targetFrame(for: assignment, profile: current.profile, snapshot: current.snapshot,
                                    stackAssignments: assignments, activeAssignmentID: assignment.id) {
            windowController.move(window, to: target.frame, in: target.container, reason: .focusTransition) { [weak self] outcome in
                guard let self, self.focusVerificationGeneration == generation else { return }
                switch outcome {
                case .placed, .constrained:
                    self.preparedFocusWindowID = window.id
                    // Do not wait for focus verification/reconciliation to move the old member.
                    for other in current.windows where other.id != window.id {
                        guard !self.isSessionRecoveryActive,
                              !self.windowController.hasActiveUserInteraction,
                              !self.windowController.hasPendingPlacement(to: other),
                              let member = self.assignment(for: other, context: current),
                              ZoneReflowPolicy.includes(member, zones: [assignment.zoneID], profile: current.profile),
                              !self.windowController.isFullScreen(other), !self.windowController.isMinimized(other),
                              let target = self.targetFrame(for: member, profile: current.profile, snapshot: current.snapshot,
                                  stackAssignments: assignments, activeAssignmentID: assignment.id) else { continue }
                        self.windowController.move(other, to: target.frame, in: target.container, reason: .focusTransition)
                    }
                    focus()
                case .cancelledByUser, .superseded, .notSaved: self.focusVerificationGeneration = nil
                }
            }
        } else {
            focus()
        }
    }

    func markFocusedWindowActive() {
        if let focused = windowTracker.focusedWindow ?? windowRegistry.focusedWindow() {
            markWindowFocused(focused)
        }
    }

    func assignment(for window: ManagedWindow, context: WorkspaceContext? = nil) -> WindowAssignment? {
        let context = context ?? workspaceContext()
        if let exact = context.assignments.first(where: {
            $0.identity.matchesSameLiveWindow(as: window.identity)
        }) {
            return exact
        }
        let stableMatches = context.assignments.filter {
            exactFingerprintMatch($0.fingerprint, window.fingerprint)
        }
        return stableMatches.count == 1 ? stableMatches[0] : nil
    }

    func actionSnapshot(for window: ManagedWindow, frame: CGRect) -> WindowActionSnapshot {
        let context = workspaceContext()
        return WindowActionSnapshot(
            identity: window.identity,
            frame: frame,
            assignment: assignment(for: window, context: context)
        )
    }

    func actionSnapshot(forAssignmentID assignmentID: UUID) -> WindowActionSnapshot? {
        let context = workspaceContext()
        guard let assignment = context.assignments.first(where: { $0.id == assignmentID }),
              let window = windowRegistry.bestMatch(for: assignment, in: context.windows),
              let frame = windowController.frame(of: window) else { return nil }
        return actionSnapshot(for: window, frame: frame)
    }

    @discardableResult
    func restoreAssignmentState(
        from snapshot: WindowActionSnapshot,
        for window: ManagedWindow
    ) -> WorkspaceSaveResult {
        pendingFrameUpdates[window.id]?.cancel()
        pendingFrameUpdates.removeValue(forKey: window.id)
        let saved = store.updateWorkspace { workspace in
            let restored = WindowActionStateRestorer().restore(
                snapshotAssignment: snapshot.assignment,
                liveIdentity: window.identity,
                liveFingerprint: window.fingerprint,
                assignments: workspace.assignments,
                history: workspace.history,
                now: Date()
            )
            workspace.assignments = restored.assignments
            workspace.history = restored.history
        }
        focusHistoryBaseline = store.loadZoneStackState()
        deferredFocusEvents.removeAll()
        if !saved { onPersistenceFailure?() }
        return saved ? .saved : .failed
    }

    func zone(for window: ManagedWindow, context: WorkspaceContext? = nil) -> ZoneID {
        let context = context ?? workspaceContext()
        return assignment(for: window, context: context)?.zoneID ?? inferredZone(for: window, context: context)
    }

    func targetFrame(
        for assignment: WindowAssignment,
        profile: DisplayProfile,
        snapshot: DisplaySnapshot,
        stackAssignments: [WindowAssignment]? = nil,
        activeAssignmentID: UUID? = nil,
        currentFrame: CGRect? = nil
    ) -> (frame: CGRect, container: CGRect)? {
        guard let zone = profile.zones.first(where: { $0.id == assignment.zoneID }) else { return nil }
        let context = WorkspaceContext(
            snapshot: snapshot,
            profile: profile,
            windows: [],
            assignments: []
        )
        guard let display = display(for: zone, context: context) else { return nil }
        if assignment.placementsByProfileID[profile.id] == nil, !assignment.fitsZone(in: profile.id) {
            let window = matchedWindow(for: assignment, in: windowTracker.currentSpaceWindows)
            guard let frame = currentFrame ?? window.flatMap({ observedFrames[$0.id] ?? windowRegistry.cgBounds(for: $0) }),
                  frame.width > 0, frame.height > 0,
                  [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
            let available = display.placementFrame
            let size = CGSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
            let reachable = CGRect(x: min(max(frame.minX, available.minX), available.maxX - size.width),
                                   y: min(max(frame.minY, available.minY), available.maxY - size.height),
                                   width: size.width, height: size.height)
            return (reachable, available)
        }
        let placement = assignment.placementsByProfileID[profile.id]
            ?? .zoneFit(zoneID: assignment.zoneID)
        switch placement {
        case .zoneFit:
            let zoneFrame = layoutEngine.zoneFrame(for: zone, in: display.placementFrame, spacing: context.profile.zoneSpacing)
            if let owner = tabOwner(for: zone, context: context) {
                return (ZoneTabLayout(zoneFrame: layoutEngine.zoneFrame(for: owner, in: display.placementFrame, spacing: profile.zoneSpacing), edge: store.loadConfiguration().tabEdge, style: owner.tabStyle, borderWidth: owner.tabBorderWidth).windowFrame, display.placementFrame)
            }
            guard zone.windowPresentation == .peekStack,
                  let stackAssignments else {
                return (zoneFrame, display.placementFrame)
            }
            let fitted = stackAssignments.filter {
                guard $0.zoneID == zone.id,
                      $0.managementMode == .managed else { return false }
                return $0.fitsZone(in: profile.id)
            }
            let state = store.loadZoneStackState()
            let history = state.assignmentRecencyByZone[zone.id] ?? []
            let available = Set(fitted.map(\.id))
            let ordered = history.filter(available.contains)
                + fitted.map(\.id).filter { !history.contains($0) }
            let frames = ZonePeekStackLayoutPolicy(preferredPeekWidth: CGFloat(min(160, max(8, zone.peekWidth)))).frames(
                in: zoneFrame,
                assignmentIDs: ordered,
                // Custom/unplaced focus must not replace the last focused peek member.
                activeAssignmentID: [activeAssignmentID, state.activeAssignmentByZone[zone.id]]
                    .compactMap { $0 }.first(where: available.contains) ?? ordered.first,
                direction: zone.peekDirection
            )
            return (frames[assignment.id] ?? zoneFrame, display.placementFrame)
        case .custom(_, let roleID, let normalizedDisplayFrame):
            let customDisplay = profileManager.display(
                for: roleID,
                profile: profile,
                snapshot: snapshot
            ) ?? display
            var frame = normalizedDisplayFrame.rect(in: customDisplay.placementFrame)
            if let saved = assignment.savedCustomPlacementsByProfileID[profile.id] {
                frame.size = saved.size
                frame = ZoneCustomPlacementGeometry.keepVisible(frame, in: customDisplay.placementFrame)
            }
            return (frame, customDisplay.placementFrame)
        case .unplaced:
            return nil
        }
    }

    private func fittedTarget(for assignment: WindowAssignment, zoneID: ZoneID,
                              context: WorkspaceContext) -> (frame: CGRect, container: CGRect)? {
        var destination = assignment
        destination.zoneID = zoneID
        destination.placementsByProfileID[context.profile.id] = .zoneFit(zoneID: zoneID)
        return targetFrame(for: destination, profile: context.profile, snapshot: context.snapshot)
    }

    private func customPlacement(for assignment: WindowAssignment, context: WorkspaceContext) -> SavedCustomPlacement? {
        guard case .custom = assignment.placementsByProfileID[context.profile.id] else { return nil }
        if let saved = assignment.savedCustomPlacementsByProfileID[context.profile.id] { return saved }
        guard let custom = targetFrame(for: assignment, profile: context.profile, snapshot: context.snapshot),
              let source = fittedTarget(for: assignment, zoneID: assignment.zoneID, context: context) else { return nil }
        return ZoneCustomPlacementGeometry.capture(custom.frame, in: source.frame)
    }

    func tabMoveChange(for assignment: WindowAssignment, currentFrame: CGRect,
                       to zoneID: ZoneID, context: WorkspaceContext) -> ManualWindowChange? {
        guard let target = fittedTarget(for: assignment, zoneID: zoneID, context: context) else { return nil }
        if assignment.fitsZone(in: context.profile.id) { return .fit(zoneID) }
        guard let source = fittedTarget(for: assignment, zoneID: assignment.zoneID, context: context) else { return nil }
        let relative = ZoneCustomPlacementGeometry.capture(currentFrame, in: source.frame)
        return .move(zoneID, ZoneCustomPlacementGeometry.frame(relative, in: target.frame, display: target.container))
    }

    func tabDragPlan(assignmentID: UUID) -> ZoneTabDragPlan? {
        let context = workspaceContext()
        guard !isSessionRecoveryActive, !isDisplayTransitionActive,
              let assignment = context.assignments.first(where: { $0.id == assignmentID }),
              assignment.managementMode == .managed,
              let window = windowRegistry.bestMatch(for: assignment, in: context.windows),
              !window.isMinimized, !window.isFullScreen,
              let currentFrame = windowController.frame(of: window) else { return nil }
        let destinations = zoneFrames(context: context).compactMap { zoneFrame -> ZoneTabDragDestination? in
            guard zoneFrame.zoneID != assignment.zoneID,
                  let zone = context.profile.zones.first(where: { $0.id == zoneFrame.zoneID }),
                  let change = tabMoveChange(for: assignment, currentFrame: currentFrame, to: zone.id, context: context)
                else { return nil }
            let landing: CGRect
            switch change {
            case .move(_, let frame): landing = frame
            case .fit:
                guard let target = fittedTarget(for: assignment, zoneID: zone.id, context: context) else { return nil }
                landing = target.frame
            default: return nil
            }
            return ZoneTabDragDestination(zone: zone, zoneFrame: zoneFrame.frame, landingFrame: landing)
        }
        return ZoneTabDragPlan(assignmentID: assignmentID, windowID: window.id, profileID: context.profile.id,
                               displays: context.snapshot, destinations: destinations, isFitted: assignment.fitsZone(in: context.profile.id),
                               sourceZoneFrame: zoneFrames(context: context).first { $0.zoneID == assignment.zoneID }?.frame)
    }

    func restoreCustomChange(for assignment: WindowAssignment, context: WorkspaceContext) -> ManualWindowChange? {
        guard let relative = assignment.savedCustomPlacementsByProfileID[context.profile.id],
              let target = fittedTarget(for: assignment, zoneID: assignment.zoneID, context: context) else { return nil }
        return .move(assignment.zoneID, ZoneCustomPlacementGeometry.frame(relative, in: target.frame, display: target.container))
    }

    func currentProfileContext() -> WorkspaceContext {
        workspaceContext()
    }

    func hasFullScreenCompanionContext() -> Bool {
        fullScreenCompanionContext(for: workspaceContext()) != nil
    }

    func shouldUseNativeSwitcherInFullScreen() -> Bool {
        let fullScreen = focusedIsFullScreen
        guard fullScreen else { return false }
        return FullScreenCompanionPolicy().usesNativeSwitcher(
            isFullScreen: fullScreen, hasCompanion: hasFullScreenCompanionContext(),
            fallbackEnabled: store.loadConfiguration().useNativeCommandTabInFullScreen
        )
    }

    func windowAssignmentSummaries() -> [WindowAssignmentSummary] {
        let snapshot = profileManager.currentSnapshot()
        let profile = profileManager.matchedProfile(for: snapshot)
            ?? profileManager.selectedProfile(for: snapshot)
        let windows = windowTracker.currentSpaceWindows.filter { !$0.isProvisional }
        let assignments = store.loadAssignments()
        let configuration = store.loadConfiguration()
        let excluded = Set(configuration.excludedBundleIdentifiers)
        let zonalBundleIdentifier = Bundle.main.bundleIdentifier

        return assignments.map { assignment in
            let liveMatches = windows.filter { window in
                assignment.identity.matchesSameLiveWindow(as: window.identity)
                    || exactFingerprintMatch(assignment.fingerprint, window.fingerprint)
            }
            let liveWindow = liveMatches.count == 1 ? liveMatches[0] : nil
            let placement: WindowPlacementKind
            switch assignment.placementsByProfileID[profile.id] {
            case .zoneFit?: placement = .fitted
            case .custom?: placement = .custom
            case .unplaced?, nil: placement = .notPlaced
            }
            let bundleIdentifier = assignment.fingerprint.bundleIdentifier
            let fallbackName = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first?.localizedName ?? bundleIdentifier
            return WindowAssignmentSummary(
                id: assignment.id,
                bundleIdentifier: bundleIdentifier,
                appName: liveWindow?.appName ?? fallbackName,
                title: liveWindow?.title ?? assignment.fingerprint.titleHint,
                zoneID: assignment.zoneID,
                zoneName: ZoneNameResolver().name(for: assignment.zoneID, in: profile.zones),
                placementKind: placement,
                isLive: liveWindow != nil,
                isExcluded: excluded.contains(bundleIdentifier),
                managementMode: assignment.managementMode,
                isZonalUtility: bundleIdentifier == zonalBundleIdentifier,
                updatedAt: assignment.updatedAt
            )
        }.sorted { lhs, rhs in
            if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
            if lhs.appName != rhs.appName { return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    @discardableResult
    func updateAssignment(
        _ assignmentID: UUID,
        zoneID: ZoneID,
        fitToZone: Bool
    ) -> WorkspaceSaveResult {
        let snapshot = profileManager.currentSnapshot()
        let profile = profileManager.matchedProfile(for: snapshot)
            ?? profileManager.selectedProfile(for: snapshot)
        guard var assignment = store.loadAssignments().first(where: { $0.id == assignmentID }) else { return .unavailable }
        let oldZone = assignment.zoneID
        assignment.zoneID = zoneID
        assignment.retention = .durable
        if fitToZone {
            assignment.placementsByProfileID[profile.id] = .zoneFit(zoneID: zoneID)
        } else if oldZone != zoneID {
            assignment.placementsByProfileID[profile.id] = .unplaced(zoneID: zoneID)
        }
        assignment.updatedAt = Date()
        return commitAssignment(assignment)
    }

    private func commitAssignment(_ assignment: WindowAssignment, customFrame: CGRect? = nil) -> WorkspaceSaveResult {
        let context = workspaceContext()
        let saved = store.updateWorkspace { workspace in
            var assignment = assignment
            let previous = workspace.assignments.first { $0.id == assignment.id }
            let oldZone = previous?.zoneID
            let captured = customFrame.flatMap { frame in
                fittedTarget(for: assignment, zoneID: assignment.zoneID, context: context).map {
                    ZoneCustomPlacementGeometry.capture(frame, in: $0.frame)
                }
            }
            if profileManager.matchedProfile(for: context.snapshot) != nil,
               let custom = captured ?? customPlacement(for: assignment, context: context)
                    ?? assignment.savedCustomPlacementsByProfileID[context.profile.id]
                    ?? previous.flatMap({ customPlacement(for: $0, context: context) }) {
                assignment.savedCustomPlacementsByProfileID[context.profile.id] = custom
            }
            if let index = workspace.assignments.firstIndex(where: { $0.id == assignment.id }) {
                workspace.assignments[index] = assignment
            } else {
                workspace.assignments.append(assignment)
            }
            if let oldZone, oldZone != assignment.zoneID {
                var reducer = WindowHistoryReducer(state: workspace.history)
                reducer.moveAssignment(assignment.id, from: oldZone, to: assignment.zoneID)
                workspace.history = reducer.state
            }
        }
        focusHistoryBaseline = store.loadZoneStackState()
        deferredFocusEvents.removeAll()
        if !saved { onPersistenceFailure?() }
        return saved ? .saved : .failed
    }

    func forgetAssignment(_ assignmentID: UUID) {
        let saved = store.updateWorkspace { workspace in
            workspace.assignments.removeAll { $0.id == assignmentID }
            var reducer = WindowHistoryReducer(state: workspace.history)
            reducer.prune(validAssignmentIDs: Set(workspace.assignments.map(\.id)))
            workspace.history = reducer.state
        }
        if !saved { onPersistenceFailure?() }
    }

    func setManagementMode(_ mode: WindowManagementMode, assignmentID: UUID) {
        let saved = store.updateWorkspace { workspace in
            guard let index = workspace.assignments.firstIndex(where: { $0.id == assignmentID }) else {
                return
            }
            workspace.assignments[index].managementMode = mode
            workspace.assignments[index].retention = .durable
            workspace.assignments[index].updatedAt = Date()
        }
        if !saved { onPersistenceFailure?() }
    }

    func isManaged(_ window: ManagedWindow) -> Bool {
        let context = workspaceContext()
        guard !store.loadConfiguration().excludedBundleIdentifiers.contains(window.fingerprint.bundleIdentifier) else { return false }
        return assignment(for: window, context: context)?.managementMode != .ignored
    }

    func profileContext(
        snapshot: DisplaySnapshot,
        profile: DisplayProfile
    ) -> WorkspaceContext {
        workspaceContext(snapshot: snapshot, profile: profile)
    }

    func detailedDiagnosticLines() -> [String] {
        let assignments = store.loadAssignments()
        let configuredPlacementCount = assignments.filter { assignment in
            assignment.placementsByProfileID.values.contains { placement in
                switch placement {
                case .zoneFit, .custom: true
                case .unplaced: false
                }
            }
        }.count
        let strongFingerprintCount = assignments.filter {
            $0.fingerprint.stableIdentifier != nil || $0.fingerprint.documentURL != nil
        }.count
        let durableCount = assignments.filter { $0.retention == .durable }.count
        return [
            "Assignment recovery this run: heuristic=\(sessionHeuristicRecoveries) placement=\(sessionPlacementRecoveries) duplicatesMerged=\(sessionDuplicateAssignmentsMerged)",
            "Assignments created this run: \(sessionNewAssignments) (with unresolved same-app predecessors: \(sessionUnresolvedSameAppAssignments))",
            "Assignment storage: durable=\(durableCount) session=\(assignments.count - durableCount) configured=\(configuredPlacementCount) unplacedOnly=\(assignments.count - configuredPlacementCount) strongFingerprint=\(strongFingerprintCount) weakFingerprint=\(assignments.count - strongFingerprintCount)",
            "Focus projection queue: deferred=\(deferredFocusEvents.count)",
            "Known-window focus fast paths: \(knownFocusFastPaths)",
            "Full-screen companion available: \(hasFullScreenCompanionContext())"
        ]
    }

    private func switcherContext(for current: WorkspaceContext) -> WorkspaceContext {
        fullScreenCompanionContext(for: current) ?? current
    }

    private func fullScreenCompanionContext(for current: WorkspaceContext) -> WorkspaceContext? {
        guard let focused = windowTracker.focusedWindow,
              let cached = lastRegularSpaceContext,
              FullScreenCompanionPolicy().canUseCache(
                  isFullScreen: focusedIsFullScreen, focusedIdentity: focused.identity,
                  cachedIdentities: cached.windows.map(\.identity),
                  cachedProfileID: cached.profile.id, currentProfileID: current.profile.id,
                  cachedDisplays: cached.snapshot, currentDisplays: current.snapshot
              ) else { return nil }
        var result = cached
        result.assignments = store.loadAssignments()
        return result
    }

    private func markWindowFocused(_ rawWindow: ManagedWindow) {
        Self.logger.info("handoff.stage=observedFocus window=\(rawWindow.id) uptime=\(ProcessInfo.processInfo.systemUptime)")
        onFocusedWindowChanged?(rawWindow)
        focusedIsFullScreen = windowController.isFullScreen(rawWindow)
        // Inventory/display callbacks own discovery. Exact known focus needs only history projection.
        if !KnownWindowFocusPolicy.canSkipReconciliation(identity: rawWindow.identity,
                cached: cachedContext?.windows ?? [], current: windowTracker.currentSpaceWindows,
                recovering: isSessionRecoveryActive) {
            reconcile()
        } else {
            knownFocusFastPaths += 1
        }
        if preparedFocusWindowID != rawWindow.id { preparedFocusWindowID = nil }
        let previousActive = store.loadZoneStackState().activeAssignmentByZone
        appendFocusEvent(target: .liveWindow(rawWindow.id))
        projectObservedFocusEvents()
        if !focusedIsFullScreen {
            let context = workspaceContext()
            if !context.windows.isEmpty {
                lastRegularSpaceContext = context
            }
            if let assignment = assignment(for: rawWindow, context: context),
               FocusLayoutPolicy.needsLayout(assignmentID: assignment.id,
                   previousActive: previousActive[assignment.zoneID], prepared: preparedFocusWindowID == rawWindow.id),
               ZoneReflowPolicy.includes(assignment, zones: [assignment.zoneID], profile: context.profile) {
                onZonePresentationNeedsLayout?(assignment.zoneID)
            }
        }
    }

    func cancelPendingFocus() {
        focusVerificationGeneration = nil
        switcherFocusGeneration = nil
        onFocusRequest?()
        preparedFocusWindowID = nil
        windowController.cancelPendingFocus()
    }

    private func verifyFocusedSelection(
        assignmentID: UUID,
        zoneID: ZoneID,
        window: ManagedWindow,
        generation: UUID,
        attempt: Int
    ) {
        guard focusVerificationGeneration == generation else { return }
        windowRegistry.focusedWindow { [weak self] focusedWindow in
            guard let self, self.focusVerificationGeneration == generation else { return }
            if let focusedWindow, self.windowRegistry.elementsMatch(focusedWindow, window) {
                let previousActive = self.store.loadZoneStackState().activeAssignmentByZone[zoneID]
                self.recordObservedFocus(assignmentID: assignmentID, zoneID: zoneID)
                self.focusVerificationGeneration = nil
                self.onFocusedWindowChanged?(focusedWindow)
                if self.switcherFocusGeneration == generation {
                    self.switcherFocusGeneration = nil
                    self.onSwitcherFocusConfirmed?(focusedWindow)
                }
                let context = self.workspaceContext()
                if let assignment = self.assignment(for: focusedWindow, context: context),
                   FocusLayoutPolicy.needsLayout(assignmentID: assignment.id,
                       previousActive: previousActive, prepared: self.preparedFocusWindowID == window.id),
                   ZoneReflowPolicy.includes(assignment, zones: [zoneID], profile: context.profile) {
                    self.onZonePresentationNeedsLayout?(zoneID)
                }
                return
            }
            let retryDelays: [TimeInterval] = [0.05, 0.15, 0.4, 0.8]
            guard attempt < retryDelays.count else {
                self.focusVerificationGeneration = nil
                Self.logger.info("Switcher focus was not confirmed; MRU was left unchanged")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[attempt]) { [weak self] in
                guard let self, self.focusVerificationGeneration == generation else { return }
                self.windowController.focus(window) { [weak self] in
                    self?.verifyFocusedSelection(assignmentID: assignmentID, zoneID: zoneID,
                        window: window, generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    private func recordObservedFocus(assignmentID: UUID, zoneID: ZoneID) {
        appendFocusEvent(
            target: .assignment(
                AssignmentFocusTarget(assignmentID: assignmentID, zoneID: zoneID)
            )
        )
        projectObservedFocusEvents()
    }

    private func appendFocusEvent(target: DeferredFocusTarget) {
        // Compact resolved history periodically so a long-running menu-bar app
        // does not retain an unbounded session event list. Any still unresolved
        // events are deliberately abandoned at this distant boundary rather
        // than being replayed later with a misleading recency.
        if deferredFocusEvents.count >= 2_048 {
            projectObservedFocusEvents()
            focusHistoryBaseline = store.loadZoneStackState()
            deferredFocusEvents.removeAll()
        }
        focusEventSequence &+= 1
        deferredFocusEvents.append(
            DeferredFocusEvent(sequence: focusEventSequence, target: target)
        )
    }

    private func projectObservedFocusEvents() {
        guard !deferredFocusEvents.isEmpty else { return }
        let context = workspaceContext()
        let assignments = assignmentsByWindowID(context: context).mapValues {
            AssignmentFocusTarget(assignmentID: $0.id, zoneID: $0.zoneID)
        }
        let projection = FocusHistoryProjector().project(
            baseline: focusHistoryBaseline,
            events: deferredFocusEvents,
            assignmentByWindowID: assignments
        )
        let persistedState = store.loadZoneStackState()
        let persisted = projection.state == persistedState
            || store.stageZoneStackState(projection.state)
        if persisted {
            focusHistoryBaseline = projection.compactedBaseline
            deferredFocusEvents = projection.remainingEvents
        }
    }

    private func scheduleCustomFrameCapture(for window: ManagedWindow) {
        pendingFrameUpdates[window.id]?.cancel()
        let policy = CustomFrameCapturePolicy()
        guard policy.shouldCapture(
            isSessionRecoveryActive: sessionRecovery.isActive,
            isApplyingPlacement: windowController.isApplyingPlacement(to: window),
            hasActiveUserInteraction: windowController.hasActiveUserInteraction,
            isFullScreen: windowController.isFullScreen(window),
            isMinimized: windowController.isMinimized(window),
            isDisplayTransitionActive: isDisplayTransitionActive
        ) else {
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingFrameUpdates.removeValue(forKey: window.id) }
            guard policy.shouldCapture(
                      isSessionRecoveryActive: self.sessionRecovery.isActive,
                      isApplyingPlacement: self.windowController.isApplyingPlacement(to: window),
                      hasActiveUserInteraction: self.windowController.hasActiveUserInteraction,
                      isFullScreen: self.windowController.isFullScreen(window),
                      isMinimized: self.windowController.isMinimized(window),
                      isDisplayTransitionActive: self.isDisplayTransitionActive
                  ),
                  let frame = self.windowController.frame(of: window) else { return }
            self.recordCustomFrame(for: window, frame: frame)
        }
        pendingFrameUpdates[window.id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func workspaceContext(
        snapshot snapshotOverride: DisplaySnapshot? = nil,
        profile profileOverride: DisplayProfile? = nil
    ) -> WorkspaceContext {
        let snapshot = snapshotOverride ?? cachedContext?.snapshot ?? profileManager.currentSnapshot()
        return WorkspaceContext(
            snapshot: snapshot,
            profile: profileOverride ?? cachedContext?.profile ?? profileManager.selectedProfile(for: snapshot),
            windows: cachedContext?.windows ?? [],
            assignments: store.loadAssignments()
        )
    }

    func reconcile() {
        let snapshot = profileManager.currentSnapshot()
        let profile = profileManager.matchedProfile(for: snapshot) ?? profileManager.selectedProfile(for: snapshot)
        let discoveredWindows = windowTracker.currentSpaceWindows
        observedFrames = windowRegistry.currentSpaceFrames()
        let excludedBundleIdentifiers = Set(store.loadConfiguration().excludedBundleIdentifiers)
        let windows = discoveredWindows.filter {
            !excludedBundleIdentifiers.contains($0.identity.bundleIdentifier)
        }
        let assignableWindows = windows.filter { !$0.isProvisional }
        var assignments = store.loadAssignments()
        let assignmentCountBeforeTransientCleanup = assignments.count
        assignments.removeAll { assignment in
            let isTransientHost = WindowInclusionPolicy().isTransientHost(
                subrole: assignment.fingerprint.axSubrole,
                stableIdentifier: assignment.fingerprint.stableIdentifier,
                titleHint: assignment.fingerprint.titleHint
            )
            let isStaleSessionAssignment = assignment.retention == .session
                && !windowTracker.windows.contains {
                    assignment.identity.matchesSameLiveWindow(as: $0.identity)
                }
            return isTransientHost || isStaleSessionAssignment
        }
        var claimed = Set<UUID>()
        var claimedWindowIDs = Set<LiveWindowID>()
        var changed = assignments.count != assignmentCountBeforeTransientCleanup
        var stackState = store.loadZoneStackState()
        let originalStackState = stackState
        let canonicalization = WindowAssignmentCanonicalizer().canonicalize(
            assignments: assignments,
            liveIdentities: assignableWindows.map(\.identity),
            globalRecency: stackState.globalRecency
        )
        assignments = canonicalization.assignments
        if !canonicalization.replacements.isEmpty {
            var reducer = WindowHistoryReducer(state: stackState)
            var baselineReducer = WindowHistoryReducer(state: focusHistoryBaseline)
            let assignmentZoneIDs = Dictionary(
                uniqueKeysWithValues: canonicalization.assignments.map {
                    ($0.id, $0.zoneID)
                }
            )
            reducer.replaceAssignmentIDs(
                canonicalization.replacements,
                assignmentZoneIDs: assignmentZoneIDs
            )
            baselineReducer.replaceAssignmentIDs(
                canonicalization.replacements,
                assignmentZoneIDs: assignmentZoneIDs
            )
            focusHistoryBaseline = baselineReducer.state
            stackState = reducer.state
            changed = true
            sessionDuplicateAssignmentsMerged += canonicalization.replacements.count
            Self.logger.info(
                "Merged \(canonicalization.replacements.count) duplicate live window assignments"
            )
        }

        // Resolve geometry lazily once per scan, including unavailable reads. Every
        // claimant is compared against the same snapshot rather than AX read order.
        var recoveryFrames: [LiveWindowID: CGRect] = [:]
        var attemptedRecoveryFrames = Set<LiveWindowID>()
        func recoveryFrame(_ window: ManagedWindow) -> CGRect? {
            if attemptedRecoveryFrames.insert(window.id).inserted,
               let frame = windowController.frame(of: window) { recoveryFrames[window.id] = frame }
            return recoveryFrames[window.id]
        }

        for window in assignableWindows {
            if let exactIndex = assignments.firstIndex(where: {
                $0.identity.matchesSameLiveWindow(as: window.identity)
            }) {
                claimed.insert(assignments[exactIndex].id)
                claimedWindowIDs.insert(window.id)
                if assignments[exactIndex].identity != window.identity
                    || assignments[exactIndex].fingerprint != window.fingerprint {
                    assignments[exactIndex].identity = window.identity
                    assignments[exactIndex].fingerprint = window.fingerprint
                    changed = true
                }
                continue
            }

            let stableIndices = assignments.indices.filter { index in
                !claimed.contains(assignments[index].id)
                    && !assignableWindows.contains { other in
                        other.id != window.id && assignments[index].identity.matchesSameLiveWindow(as: other.identity)
                    }
                    && exactFingerprintMatch(assignments[index].fingerprint, window.fingerprint)
            }
            let stableWindows = assignableWindows.filter {
                exactFingerprintMatch($0.fingerprint, window.fingerprint)
            }
            if stableIndices.count == 1 && stableWindows.count == 1 {
                let index = stableIndices[0]
                assignments[index].identity = window.identity
                assignments[index].fingerprint = window.fingerprint
                claimed.insert(assignments[index].id)
                claimedWindowIDs.insert(window.id)
                changed = true
                continue
            }

            let remainingWindows = assignableWindows.filter {
                !claimedWindowIDs.contains($0.id)
            }
            let heuristicIndices = assignments.indices.filter { index in
                guard !claimed.contains(assignments[index].id),
                      !assignableWindows.contains(where: { assignments[index].identity.matchesSameLiveWindow(as: $0.identity) }) else { return false }
                switch windowRegistry.match(
                    for: assignments[index].fingerprint,
                    liveHint: nil,
                    in: remainingWindows
                ) {
                case .confident(let candidate):
                    return candidate.id == window.id
                case .exact, .ambiguous, .unmatched:
                    return false
                }
            }
            if heuristicIndices.count == 1 {
                let index = heuristicIndices[0]
                assignments[index].identity = window.identity
                assignments[index].fingerprint = window.fingerprint
                claimed.insert(assignments[index].id)
                claimedWindowIDs.insert(window.id)
                changed = true
                sessionHeuristicRecoveries += 1
                continue
            }

            if let liveFrame = recoveryFrame(window) {
                let placementCandidates = assignments.indices.compactMap { index
                    -> WindowPlacementRecoveryCandidate? in
                    guard !claimed.contains(assignments[index].id),
                          !assignableWindows.contains(where: { assignments[index].identity.matchesSameLiveWindow(as: $0.identity) }),
                          assignments[index].fingerprint.bundleIdentifier
                            == window.fingerprint.bundleIdentifier,
                          let target = targetFrame(
                              for: assignments[index],
                              profile: profile,
                              snapshot: snapshot
                          ) else {
                        return nil
                    }
                    return WindowPlacementRecoveryCandidate(
                        assignmentID: assignments[index].id,
                        targetFrame: target.frame
                    )
                }
                if let recoveredID = WindowPlacementRecoveryMatcher().assignmentID(
                    for: liveFrame,
                    candidates: placementCandidates
                ), let candidate = placementCandidates.first(where: { $0.assignmentID == recoveredID }),
                   assignableWindows.filter({ other in
                       guard other.fingerprint.bundleIdentifier == window.fingerprint.bundleIdentifier else { return false }
                       // An unreadable sibling could occupy the same frame; do not guess.
                       guard let frame = recoveryFrame(other) else { return true }
                       return WindowPlacementRecoveryMatcher().assignmentID(for: frame, candidates: [candidate]) != nil
                   }).count == 1,
                   let index = assignments.firstIndex(where: { $0.id == recoveredID }) {
                    assignments[index].identity = window.identity
                    assignments[index].fingerprint = window.fingerprint
                    claimed.insert(assignments[index].id)
                    claimedWindowIDs.insert(window.id)
                    changed = true
                    sessionPlacementRecoveries += 1
                    Self.logger.info(
                        "Recovered a window assignment from a unique saved placement"
                    )
                    continue
                }
            }

            let provisional = WorkspaceContext(
                snapshot: snapshot,
                profile: profile,
                windows: windows,
                assignments: assignments
            )
            let zoneID = inferredZone(for: window, context: provisional)
            if assignments.contains(where: {
                !claimed.contains($0.id)
                    && $0.fingerprint.bundleIdentifier
                        == window.fingerprint.bundleIdentifier
            }) {
                sessionUnresolvedSameAppAssignments += 1
            }
            let assignment = WindowAssignment(
                id: UUID(),
                identity: window.identity,
                fingerprint: window.fingerprint,
                zoneID: zoneID,
                placementsByProfileID: [profile.id: .unplaced(zoneID: zoneID)],
                retention: .session,
                updatedAt: Date()
            )
            assignments.append(assignment)
            claimed.insert(assignment.id)
            claimedWindowIDs.insert(window.id)
            changed = true
            sessionNewAssignments += 1
        }

        var reducer = WindowHistoryReducer(state: stackState)
        var baselineReducer = WindowHistoryReducer(state: focusHistoryBaseline)
        let validAssignmentIDs = Set(assignments.map(\.id))
        reducer.prune(validAssignmentIDs: validAssignmentIDs)
        baselineReducer.prune(validAssignmentIDs: validAssignmentIDs)
        focusHistoryBaseline = baselineReducer.state
        stackState = reducer.state
        if changed || stackState != originalStackState {
            let saved = store.updateWorkspace {
                $0.assignments = assignments
                $0.history = stackState
            }
            if !saved { onPersistenceFailure?() }
        }
        cachedContext = WorkspaceContext(
            snapshot: snapshot,
            profile: profile,
            windows: windows,
            assignments: assignments
        )
    }

    private func assignmentsByWindowID(context: WorkspaceContext) -> [LiveWindowID: WindowAssignment] {
        Dictionary(uniqueKeysWithValues: context.windows.filter { !$0.isProvisional }.compactMap { window in
            assignment(for: window, context: context).map { (window.id, $0) }
        })
    }

    private func orderedWindows(
        _ windows: [ManagedWindow],
        assignmentByWindowID: [LiveWindowID: WindowAssignment],
        history: [UUID],
        currentAssignmentID: UUID?
    ) -> [ManagedWindow] {
        let availableAssignmentIDs = windows.compactMap {
            assignmentByWindowID[$0.id]?.id
        }
        let orderedAssignmentIDs = SwitcherMRUOrder().orderedAssignmentIDs(
            available: availableAssignmentIDs,
            current: currentAssignmentID,
            history: history
        )
        let rankByAssignmentID = Dictionary(
            uniqueKeysWithValues: orderedAssignmentIDs.enumerated().map { ($0.element, $0.offset) }
        )
        return windows.sorted { lhs, rhs in
            let lhsID = assignmentByWindowID[lhs.id]?.id
            let rhsID = assignmentByWindowID[rhs.id]?.id
            let lhsIndex = lhsID.flatMap { rankByAssignmentID[$0] } ?? Int.max
            let rhsIndex = rhsID.flatMap { rankByAssignmentID[$0] } ?? Int.max
            if lhsIndex == rhsIndex {
                return lhs.id.sortKey < rhs.id.sortKey
            }
            return lhsIndex < rhsIndex
        }
    }

    private func items(
        windows: [ManagedWindow],
        assignmentByWindowID: [LiveWindowID: WindowAssignment],
        activeAssignmentIDs: Set<UUID>,
        profile: DisplayProfile
    ) -> [SwitcherItem] {
        windows.compactMap { window in
            guard let assignment = assignmentByWindowID[window.id] else { return nil }
            let zone = profile.zones.first { $0.id == assignment.zoneID }
            return SwitcherItem(
                assignmentID: assignment.id,
                identity: window.identity,
                appName: window.appName,
                title: window.title,
                icon: window.icon,
                zoneID: assignment.zoneID,
                zoneName: ZoneNameResolver().name(for: assignment.zoneID, in: profile.zones),
                zoneFrame: zone?.frame,
                isActive: activeAssignmentIDs.contains(assignment.id),
                isZonalUtility: window.identity.bundleIdentifier == Bundle.main.bundleIdentifier
            )
        }
    }

    private func focusedAssignmentID(
        context: WorkspaceContext,
        assignmentByWindowID: [LiveWindowID: WindowAssignment]
    ) -> UUID? {
        guard let focused = windowTracker.focusedWindow else { return nil }
        if let canonical = context.windows.first(where: { windowRegistry.elementsMatch($0, focused) }) {
            return assignmentByWindowID[canonical.id]?.id
        }
        return nil
    }

    private func focusedZoneID(
        context: WorkspaceContext,
        assignmentByWindowID: [LiveWindowID: WindowAssignment]
    ) -> ZoneID {
        guard let focusedID = focusedAssignmentID(context: context, assignmentByWindowID: assignmentByWindowID),
              let assignment = context.assignments.first(where: { $0.id == focusedID }) else {
            return context.profile.mainZoneID
        }
        return assignment.zoneID
    }

    private func inferredZone(for window: ManagedWindow, context: WorkspaceContext) -> ZoneID {
        if let configuredZoneID = store.loadConfiguration().windowDefaultZoneRules.first(where: {
            $0.bundleIdentifier == window.identity.bundleIdentifier
        })?.zoneID,
           context.profile.zones.contains(where: { $0.id == configuredZoneID }) {
            return configuredZoneID
        }
        guard let frame = windowController.frame(of: window) ?? windowRegistry.cgBounds(for: window) else {
            return context.profile.mainZoneID
        }
        let candidates = zoneFrames(context: context).map { zoneFrame in
            (zoneFrame.zoneID, zoneFrame.frame.intersection(frame).area)
        }.sorted { $0.1 > $1.1 }
        guard let best = candidates.first, best.1 > 0 else {
            return context.profile.mainZoneID
        }
        return best.0
    }

    private func zoneFrames(context: WorkspaceContext) -> [ZoneFrame] {
        var frames: [DisplayRoleID: CGRect] = [:]
        for role in context.profile.displayRoles {
            if let display = profileManager.display(
                for: role.id,
                profile: context.profile,
                snapshot: context.snapshot
            ) {
                frames[role.id] = display.placementFrame
            }
        }
        return layoutEngine.zoneFrames(
            for: context.profile,
            displayFramesByRole: frames,
            fallbackDisplayFrame: context.snapshot.primaryDisplay?.placementFrame
        )
    }

    private func display(for zone: Zone, context: WorkspaceContext) -> DisplaySnapshot.Display? {
        profileManager.display(
            for: zone.displayRoleID,
            profile: context.profile,
            snapshot: context.snapshot
        )
    }

    private func switcherZoneColumns(
        context: WorkspaceContext,
        zoneFrames: [ZoneFrame]? = nil
    ) -> [[ZoneID]] {
        var columns = layoutEngine.switcherZoneColumns(
            for: zoneFrames ?? self.zoneFrames(context: context),
            profileOrder: context.profile.zones.map(\.id)
        )
        let placed = Set(columns.flatMap { $0 })
        columns.append(contentsOf: context.profile.zones
            .map(\.id)
            .filter { !placed.contains($0) }
            .map { [$0] })
        return columns
    }

    private func matchedWindow(
        for assignment: WindowAssignment,
        in windows: [ManagedWindow]
    ) -> ManagedWindow? {
        switch windowRegistry.match(
            for: assignment.fingerprint,
            liveHint: assignment.identity,
            in: windows
        ) {
        case .exact(let window), .confident(let window):
            return window
        case .ambiguous, .unmatched:
            Self.logger.info("Skipped an ambiguous or unmatched window assignment")
            return nil
        }
    }

    private func exactFingerprintMatch(
        _ lhs: PersistentWindowFingerprint,
        _ rhs: PersistentWindowFingerprint
    ) -> Bool {
        guard lhs.bundleIdentifier == rhs.bundleIdentifier else { return false }
        if let lhsStable = lhs.stableIdentifier, let rhsStable = rhs.stableIdentifier {
            return lhsStable == rhsStable
        }
        if let lhsDocument = lhs.documentURL, let rhsDocument = rhs.documentURL {
            return lhsDocument == rhsDocument
        }
        return false
    }
}

struct ZoneSwitcherProjection {
    func zones(
        profileZones: [Zone],
        orderedZoneIDs: [ZoneID],
        itemsByZoneID: [ZoneID: [SwitcherItem]]
    ) -> [SwitcherZone] {
        let zonesByID = Dictionary(
            profileZones.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let completeOrder = orderedZoneIDs
            + profileZones.map(\.id).filter { !orderedZoneIDs.contains($0) }
        return completeOrder.compactMap { zoneID in
            guard let zone = zonesByID[zoneID] else { return nil }
            return SwitcherZone(
                id: zone.id,
                name: zone.name,
                frame: zone.frame,
                items: itemsByZoneID[zone.id] ?? []
            )
        }
    }
}

struct SwitcherCycleScope {
    func items(
        mode: SwitcherMode,
        zones: [SwitcherZone],
        selectedZoneID: ZoneID
    ) -> [SwitcherItem] {
        switch mode {
        case .allWindows:
            return zones.flatMap(\.items)
        case .byZone:
            return zones.first { $0.id == selectedZoneID }?.items ?? []
        }
    }
}

struct WorkspaceContext {
    var snapshot: DisplaySnapshot
    var profile: DisplayProfile
    var windows: [ManagedWindow]
    var assignments: [WindowAssignment]
}

private extension CGRect {
    var area: CGFloat {
        isNull ? 0 : max(0, width) * max(0, height)
    }
}
