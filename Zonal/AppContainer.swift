import AppKit
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()
    static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "Automation")

    @Published private(set) var menuSnapshot = StatusMenuSnapshot(
        accessibilityTrusted: false,
        inputMonitoringGranted: false,
        keyboardCaptureAvailable: false,
        trackingActive: false,
        displaySetupName: "Detecting…",
        matchedProfileName: nil
    )
    @Published private(set) var windowScanStatus: String?
    @Published private(set) var windowManagementRevision = 0
    @Published private(set) var launchAtLoginState: LaunchAtLoginState = .disabled
    @Published private(set) var launchAtLoginErrorMessage: String?
    @Published private(set) var healthFindings: [ZonalHealthFinding] = []

    private let permissions = PermissionsController()
    private let launchAtLoginService: LaunchAtLoginServicing = SystemLaunchAtLoginService()
    let store = PersistenceStore()
    lazy var profileManager = ProfileManager(store: store)
    private lazy var layoutEngine = LayoutEngine()
    lazy var windowRegistry = WindowRegistry()
    private lazy var windowTracker = WindowTracker(registry: windowRegistry)
    lazy var windowController = WindowController()
    private lazy var activeWindowOutline: ActiveWindowOutlineController = ActiveWindowOutlineController(
        store: store,
        windowServer: OutlineWindowServer(),
        isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.pid },
        visibilityCheckInterval: 1.0,
        onFocusNeedsRefresh: { [weak self] in
            // Our Settings window uses authoritative native focus callbacks.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.windowTracker.refreshOutlineFocus { [weak self] window in
                self?.activeWindowOutline.update(window: window)
            }
        },
        isSuspended: { [weak self] in self?.restoreEngine.isTabPresentationSuspended ?? true }
    )
    lazy var workspaceState = WorkspaceStateService(
        profileManager: profileManager,
        layoutEngine: layoutEngine,
        windowRegistry: windowRegistry,
        windowTracker: windowTracker,
        windowController: windowController,
        store: store
    )
    lazy var restoreEngine = RestoreEngine(
        profileManager: profileManager,
        windowRegistry: windowRegistry,
        windowTracker: windowTracker,
        windowController: windowController,
        workspaceState: workspaceState,
        store: store
    )
    private lazy var zoneTabs = ZoneTabController(
        snapshots: { [weak self] in self?.workspaceState.tabSnapshots() ?? [] },
        focus: { [weak self] id in self?.workspaceState.focusTab(assignmentID: id) },
        performAction: { [weak self] id, action in self?.restoreEngine.performTabAction(assignmentID: id, action: action) },
        prepareDrag: { [weak self] id in self?.workspaceState.tabDragPlan(assignmentID: id) },
        isSuspended: { [weak self] in self?.restoreEngine.isTabPresentationSuspended ?? true }
    )
    lazy var switcher = SwitcherController(workspaceState: workspaceState)
    private lazy var hotZoneOverlay = HotZoneOverlayController()
    private lazy var windowMovementObserver: WindowMovementObserver = {
        let observer = WindowMovementObserver(
            profileManager: profileManager,
            layoutEngine: layoutEngine,
            windowRegistry: windowRegistry,
            windowController: windowController,
            workspaceState: workspaceState,
            overlayController: hotZoneOverlay,
            store: store
        )
        observer.onPlacementFeedback = { [weak self] snapshot, content in
            self?.restoreEngine.presentPlacementFeedback(
                snapshot: snapshot,
                content: content
            )
        }
        observer.onManualAction = { [weak self] window, change, snapshot, completion in
            self?.restoreEngine.performManualAction(window: window, change: change, before: snapshot, completion: completion)
        }
        observer.onInteractionDiagnostic = { [weak self] event in
            guard let self,
                  self.store.loadConfiguration().showInteractionDiagnostics else { return }
            self.restoreEngine.presentInteractionDiagnostic(event)
        }
        return observer
    }()
    private lazy var hotkeys = HotkeyManager(
        restoreEngine: restoreEngine,
        windowRegistry: windowRegistry,
        store: store,
        workspaceState: workspaceState,
        switcher: switcher
    )
    private var statusTimer: Timer?
    var automationServer: LocalAutomationSocketServer?
    private var isStarted = false
    private let instanceLock = ZonalInstanceLock()
    private var lastAppliedConfiguration: ZonalConfiguration?
    private var terminationObserver: NSObjectProtocol?
    private var appliedPresentationProfile: DisplayProfile?
    private var didPresentPermissionSetup = false

    var accessibilityStatusTitle: String {
        menuSnapshot.accessibilityTrusted
            ? "Accessibility: Granted"
            : "Accessibility: Missing"
    }

    var menuBarMode: MenuBarMode {
        store.loadConfiguration().menuBarMode
    }

    @discardableResult
    func start() -> Bool {
        guard !isStarted else { return true }
        do {
            guard try instanceLock.acquire() else {
                Self.logger.info("Another Zonal process already owns window management")
                if Bundle.main.bundleIdentifier == "com.sebmarste.zonal.dev" {
                    let alert = NSAlert()
                    alert.messageText = "Another copy of Zonal is running"
                    alert.informativeText = "Quit the other copy before starting Zonal Development. Only one copy can manage your windows at a time."
                    alert.runModal()
                }
                return false
            }
        } catch {
            Self.logger.error("Could not acquire process ownership: \(error.localizedDescription, privacy: .public)")
            return false
        }
        isStarted = true
        store.bootstrap()
        if store.readOnlyReason != nil {
            DispatchQueue.main.async { SettingsWindowController.shared.show() }
            return true
        }
        applyTheme()
        lastAppliedConfiguration = store.loadConfiguration()
        workspaceState.start()
        appliedPresentationProfile = workspaceState.currentProfileContext().profile
        workspaceState.onZonePresentationNeedsLayout = { [weak self] zone in
            self?.restoreEngine.scheduleZoneReflow(zone, immediately: true)
        }
        workspaceState.onPersistenceFailure = { [weak self] in self?.restoreEngine.presentPersistenceFailure() }
        workspaceState.onManualAssignment = { [weak self] id, zone, fit in
            self?.restoreEngine.updateWindowAssignment(id, zoneID: zone, fitToZone: fit)
        }
        workspaceState.onFocusedWindowChanged = { [weak self] window in
            self?.activeWindowOutline.update(window: window)
            self?.hotkeys.refreshCaptureSnapshot()
            self?.zoneTabs.refresh()
        }
        workspaceState.onWindowInventoryChanged = { [weak self] windows in
            self?.activeWindowOutline.prewarm(windows: windows)
        }
        workspaceState.onOutlineEnvironmentChanged = { [weak self] window in
            guard let self else { return }
            self.activeWindowOutline.resynchronize(window: window)
            self.activeWindowOutline.prewarm(windows: self.windowTracker.currentSpaceWindows)
        }
        windowTracker.onSessionActivityChanged = { [weak self] active in
            guard let self else { return }
            if active {
                self.zoneTabs.start()
                self.activeWindowOutline.start()
                self.startStatusRefreshTimer()
                self.refreshLaunchAtLoginState()
                self.refreshMenuStatus()
            } else {
                self.zoneTabs.stop()
                self.activeWindowOutline.stop()
                self.statusTimer?.invalidate()
                self.statusTimer = nil
                self.switcher.suspend()
            }
        }
        windowTracker.onWindowObserverReady = { [weak self] window in
            self?.activeWindowOutline.updateFrame(for: window)
        }
        workspaceState.onSwitcherFocusConfirmed = { [weak self] window in
            self?.activeWindowOutline.pulseAfterSwitcherFocus(window)
        }
        workspaceState.onFocusRequest = { [weak self] in self?.activeWindowOutline.cancelPulse() }
        activeWindowOutline.onWindowOrderingChanged = { [weak self] in self?.zoneTabs.refresh() }
        zoneTabs.start()
        activeWindowOutline.start()
        activeWindowOutline.resynchronize(window: windowTracker.focusedWindow)
        activeWindowOutline.prewarm(windows: windowTracker.currentSpaceWindows)
        workspaceState.onWindowGeometryChanged = { [weak self] window in
            guard let self else { return }
            self.zoneTabs.requestRefresh()
            guard !self.windowController.isApplyingPlacement(to: window) else { return }
            self.activeWindowOutline.updateFrame(for: window)
        }
        windowController.onPlacementStarted = { [weak self] id, _, _ in
            self?.windowMovementObserver.placementWillBegin(for: id)
            self?.activeWindowOutline.placementStarted(for: id)
        }
        windowController.onPlacementSettled = { [weak self] id in
            self?.activeWindowOutline.placementSettled(for: id)
        }
        windowController.onPlacementVerified = { [weak self] id, frame in
            self?.activeWindowOutline.placementVerified(for: id, frame: frame)
        }
        hotkeys.start()
        hotkeys.onUserKeyDown = { [weak self] in self?.workspaceState.cancelPendingFocus() }
        windowMovementObserver.onMouseDown = { [weak self] in self?.workspaceState.cancelPendingFocus() }
        hotkeys.onEscape = { [weak self] in self?.zoneTabs.interaction.cancel() ?? false }
        windowMovementObserver.onTabPointerEvent = { [weak self] type, point in self?.zoneTabs.interaction.pointer(type, at: point) ?? false }
        windowMovementObserver.isTabInteractionActive = { [weak self] in self?.zoneTabs.interaction.isActive ?? false }
        windowMovementObserver.onWindowDragChanged = { [weak self] id in
            self?.activeWindowOutline.windowDragChanged(id)
            self?.zoneTabs.windowDragChanged(id)
        }
        restoreEngine.onUndoChanged = { [weak self] in self?.windowManagementRevision &+= 1 }
        restoreEngine.start()
        windowMovementObserver.start()
        startLocalAutomation()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.switcher.preparePresentation()
        }
        refreshLaunchAtLoginState()
        startStatusRefreshTimer()
        refreshMenuStatus()
        presentPermissionSetupIfNeeded()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        return true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        hotkeys.stop()
        restoreEngine.stop()
        windowMovementObserver.stop()
        workspaceState.stop()
        activeWindowOutline.stop()
        zoneTabs.stop()
        windowController.onPlacementStarted = nil
        windowController.onPlacementSettled = nil
        windowController.onPlacementVerified = nil
        stopLocalAutomation()
        statusTimer?.invalidate()
        statusTimer = nil
        _ = store.flushPendingWorkspaceWrite()
        instanceLock.release()
    }

    func requestAccessibilityPermission() {
        permissions.requestAccessibilityTrust()
        refreshMenuAfterPermissionPrompt()
    }

    func openAccessibilitySettings() {
        permissions.openAccessibilitySettings()
        refreshMenuAfterPermissionPrompt()
    }

    func requestInputMonitoringPermission() {
        permissions.requestInputMonitoring()
        refreshMenuAfterPermissionPrompt()
    }

    func openInputMonitoringSettings() {
        permissions.openInputMonitoringSettings()
        refreshMenuAfterPermissionPrompt()
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(isEnabled)
            launchAtLoginErrorMessage = nil
        } catch {
            launchAtLoginErrorMessage = error.localizedDescription
        }
        refreshLaunchAtLoginState()
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func applyProfileNow(_ profileID: String) {
        guard store.readOnlyReason == nil else { return }
        var configuration = store.loadConfiguration()
        guard configuration.profiles.contains(where: { $0.id == profileID }) else { return }
        if configuration.activeProfileID != profileID {
            configuration.activeProfileID = profileID
            guard store.saveConfiguration(configuration) else {
                restoreEngine.presentPersistenceFailure(retry: { [weak self] in self?.applyProfileNow(profileID) })
                return
            }
        }
        profileManager.reloadProfiles()
        refreshMenuStatus()
        restoreEngine.applyProfileNow(profileID)
    }

    func applyMatchingProfileFromMenu(_ profileID: String) {
        // A display change while the menu is open must not apply an obsolete setup.
        let snapshot = profileManager.currentSnapshot()
        guard profileManager.matchingProfiles(for: snapshot).contains(where: { $0.id == profileID }),
              profileManager.matchedProfile(for: snapshot)?.id != profileID else { return }
        applyProfileNow(profileID)
    }

    func settingsVisibilityDidChange() {
        refreshLaunchAtLoginState()
        // Activation-policy changes alter whether the Settings window is a
        // regular switchable app window. Reconcile immediately instead of
        // waiting for the recovery scan.
        DispatchQueue.main.async { [weak self] in
            self?.windowTracker.reconcile()
        }
    }

    func settingsWindowDidChange(_ window: NSWindow, geometryChanged: Bool, isFocused: Bool) {
        activeWindowOutline.update(settingsWindow: window, geometryChanged: geometryChanged, isFocused: isFocused)
    }

    func profileTransitionPreview(_ profileID: String) -> ProfileTransitionPreview? {
        restoreEngine.previewProfile(profileID)
    }

    func configurationDidChange(previous: ZonalConfiguration? = nil) {
        guard store.readOnlyReason == nil else { return }
        let configuration = store.loadConfiguration()
        let prior = previous ?? lastAppliedConfiguration
        lastAppliedConfiguration = configuration
        hotkeys.refreshCaptureSnapshot()
        if prior?.theme != configuration.theme { applyTheme() }
        if prior?.showActiveWindowOutline != configuration.showActiveWindowOutline
            || prior?.activeWindowOutlineColor != configuration.activeWindowOutlineColor
            || prior?.activeWindowOutlineWidth != configuration.activeWindowOutlineWidth
            || prior?.behavior.outlinePulseMode != configuration.behavior.outlinePulseMode {
            if prior?.behavior.outlinePulseMode != configuration.behavior.outlinePulseMode {
                activeWindowOutline.cancelPulse()
            }
            activeWindowOutline.prewarm(windows: windowTracker.currentSpaceWindows)
            activeWindowOutline.refresh()
        }
        if ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: prior, current: configuration) {
            workspaceState.reconcile()
            let profile = workspaceState.currentProfileContext().profile
            let reflowZones = prior?.tabEdge != configuration.tabEdge
                ? Set(profile.zones.map(\.id))
                : ZoneReflowPolicy.changedZones(from: appliedPresentationProfile, to: profile)
            for zone in reflowZones {
                restoreEngine.scheduleZoneReflow(zone, includeOverlap: true)
            }
            appliedPresentationProfile = profile
        }
        windowManagementRevision &+= 1
        refreshMenuStatus()
    }

    private func applyTheme() {
        NSApplication.shared.appearance = store.loadConfiguration().theme.appearanceName
            .flatMap(NSAppearance.init(named:))
    }

    func windowAssignmentSummaries() -> [WindowAssignmentSummary] {
        workspaceState.windowAssignmentSummaries()
    }

    func updateWindowAssignment(
        _ assignmentID: UUID,
        zoneID: ZoneID,
        fitToZone: Bool
    ) {
        restoreEngine.updateWindowAssignment(assignmentID, zoneID: zoneID, fitToZone: fitToZone)
        windowManagementRevision &+= 1
    }

    func forgetWindowAssignment(_ assignmentID: UUID) {
        workspaceState.forgetAssignment(assignmentID)
        windowManagementRevision &+= 1
    }

    func setWindowManagementMode(_ mode: WindowManagementMode, assignmentID: UUID) {
        workspaceState.setManagementMode(mode, assignmentID: assignmentID)
        windowManagementRevision &+= 1
    }

    func showSwitcher(_ mode: SwitcherMode) {
        switcher.show(mode: mode)
    }

    func restoreNow() {
        guard store.readOnlyReason == nil else { return }
        restoreEngine.restoreNow(trigger: .manual)
    }

    func undoLastWindowAction() {
        guard store.readOnlyReason == nil else { return }
        restoreEngine.undoLastAction()
    }

    var recentWindowActions: [WindowUndoTransaction] { restoreEngine.recentActions }

    var canUndoLastWindowAction: Bool {
        restoreEngine.canUndoLastAction
    }

    func rescanWindows() {
        guard store.readOnlyReason == nil else { return }
        let initialCount = windowTracker.rescan(reason: "user-requested") { [weak self] finalCount in
            self?.windowScanStatus = "Scan complete: \(finalCount) windows found"
            self?.refreshMenuStatus()
        }
        windowScanStatus = "Scanning windows… \(initialCount) found so far"
    }

    @discardableResult
    func runHealthCheck() -> [ZonalHealthFinding] {
        refreshLaunchAtLoginState()
        healthFindings = ZonalDoctor().check(
            permissions: permissions, loginState: launchAtLoginState,
            configuration: store.loadConfiguration(), profileManager: profileManager,
            automationRunning: automationServer != nil
        )
        return healthFindings
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    func privacySafeDiagnostics() -> String {
        let context = workspaceState.currentProfileContext()
        let configuration = store.loadConfiguration()
        return SupportReport.diagnostics(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            accessibility: permissions.isAccessibilityTrusted,
            inputMonitoring: permissions.isInputMonitoringGranted,
            keyboardCapture: hotkeys.isKeyboardCaptureAvailable(),
            tracking: menuSnapshot.trackingActive,
            displayCount: profileManager.currentSnapshot().displays.count,
            profileCount: configuration.profiles.count,
            zoneCount: context.profile.zones.count,
            windowCount: context.windows.count,
            restoreCounts: store.loadRestoreHistory().prefix(5).map {
                SupportReport.RestoreCounts(moved: $0.moved, unchanged: $0.unchanged, skipped: $0.skipped, failed: $0.failed)
            })
    }

    func detailedDiagnostics() -> String {
        let displaySnapshot = profileManager.currentSnapshot()
        let matchedProfile = profileManager.matchedProfile(for: displaySnapshot)
        let workspace = workspaceState.switcherSnapshot(mode: .allWindows)
        let context = workspaceState.currentProfileContext()
        let windowCount = workspace.zones.reduce(0) { $0 + $1.items.count }
        let matchedAssignmentIDs = Set(context.windows.compactMap {
            workspaceState.assignment(for: $0, context: context)?.id
        })
        let displayDetails = displaySnapshot.displays.map {
            "\($0.name): x=\(Int($0.frame.minX)) y=\(Int($0.frame.minY)) w=\(Int($0.frame.width)) h=\(Int($0.frame.height)) scale=\($0.scale) builtIn=\($0.isBuiltIn)"
        }.joined(separator: " | ")
        let restores = store.loadRestoreHistory().prefix(5).map {
            "\($0.date.formatted(.iso8601)): trigger=\($0.trigger) profile=\($0.profileName) moved=\($0.moved) unchanged=\($0.unchanged) skipped=\($0.skipped) failed=\($0.failed) unmatched=\($0.unmatched)"
        }
        return ([
            "Zonal diagnostics",
            "API version: \(LocalAutomationProtocol.currentVersion)",
            "Accessibility: \(menuSnapshot.accessibilityTrusted)",
            "Input monitoring: \(menuSnapshot.inputMonitoringGranted)",
            "Keyboard capture: \(menuSnapshot.keyboardCaptureAvailable)",
            "Window tracking: \(menuSnapshot.trackingActive)",
            "Display setup: \(profileManager.setupName(for: displaySnapshot))",
            "Display topology: \(displayDetails)",
            "Matched profile: \(matchedProfile?.name ?? "none")",
            "Managed windows: \(windowCount)",
            "Assignments: \(context.assignments.count) total / \(matchedAssignmentIDs.count) live / \(context.assignments.count - matchedAssignmentIDs.count) unresolved",
            "Zones: \(context.profile.zones.count)",
        ] + zoneTabs.detailedDiagnosticLines() + activeWindowOutline.detailedDiagnosticLines()
            + windowTracker.detailedDiagnosticLines()
            + windowMovementObserver.detailedDiagnosticLines()
            + workspaceState.detailedDiagnosticLines()
            + restoreEngine.detailedDiagnosticLines()
            + windowController.detailedDiagnosticLines() + [
            "Automation socket: \(LocalAutomationProtocol.socketURL.path)",
            "Recent restores:"
        ] + (restores.isEmpty ? ["none"] : restores)).joined(separator: "\n")
    }

    func currentStatusMenuSnapshot() -> StatusMenuSnapshot {
        var snapshot = menuSnapshot
        let displays = profileManager.currentSnapshot()
        let selected = profileManager.matchedProfile(for: displays)
        snapshot.displaySetupName = profileManager.setupName(for: displays)
        snapshot.matchedProfileName = selected?.name
        snapshot.matchingProfiles = profileManager.matchingProfiles(for: displays).map {
            StatusMenuProfile(id: $0.id, name: $0.name, isSelected: $0.id == selected?.id)
        }
        return snapshot
    }

    private func refreshMenuStatus() {
        guard store.readOnlyReason == nil else { return }
        let accessibilityTrusted = permissions.isAccessibilityTrusted
        if permissions.canListenForInputEvents,
           !windowMovementObserver.isMouseCaptureAvailable() {
            windowMovementObserver.start()
        }
        if accessibilityTrusted && !hotkeys.isKeyboardCaptureAvailable() {
            hotkeys.start()
            hotkeys.onUserKeyDown = { [weak self] in self?.workspaceState.cancelPendingFocus() }
        }
        var snapshot = currentStatusMenuSnapshot()
        snapshot.accessibilityTrusted = accessibilityTrusted
        snapshot.inputMonitoringGranted = permissions.isInputMonitoringGranted
        snapshot.keyboardCaptureAvailable = hotkeys.isKeyboardCaptureAvailable()
        snapshot.trackingActive = accessibilityTrusted && windowTracker.isRunning
        if menuSnapshot != snapshot { menuSnapshot = snapshot }
        StatusItemController.shared.refresh(mode: menuBarMode, snapshot: menuSnapshot)
    }

    private func refreshLaunchAtLoginState() {
        let currentState = launchAtLoginService.state
        if launchAtLoginState != currentState {
            launchAtLoginState = currentState
            launchAtLoginErrorMessage = nil
        }
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    func recheckPermissions() {
        guard isStarted, store.readOnlyReason == nil else { return }
        refreshMenuStatus()
    }

    private func refreshMenuAfterPermissionPrompt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshMenuStatus()
        }
    }

    private func startStatusRefreshTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMenuStatus()
            }
        }
        statusTimer?.tolerance = 2
    }

    private func presentPermissionSetupIfNeeded() {
        let needsGuidedSetup = store.loadConfiguration().setupVersion < 1
        guard !didPresentPermissionSetup,
              !permissions.isAccessibilityTrusted || needsGuidedSetup else {
            return
        }
        didPresentPermissionSetup = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SettingsWindowController.shared.show()
        }
    }

}
