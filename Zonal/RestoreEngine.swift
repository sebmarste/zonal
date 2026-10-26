import AppKit
import Foundation
import OSLog

enum RestoreTrigger: Equatable {
    case launch
    case applicationLifecycle
    case systemResume
    case spaceChange
    case displayChange
    case manual
    case profileApply

    var actionTitle: String { HotkeyCommand.restore.title }

    var logLabel: String {
        switch self {
        case .launch: "launch"
        case .applicationLifecycle: "application lifecycle"
        case .systemResume: "system resume"
        case .spaceChange: "Space change"
        case .displayChange: "display change"
        case .manual: "manual"
        case .profileApply: "profile apply"
        }
    }

    var priority: Int {
        switch self {
        case .launch: 0
        case .applicationLifecycle: 1
        case .spaceChange: 2
        case .systemResume: 3
        case .displayChange: 4
        case .manual, .profileApply: 5
        }
    }

    func preferred(over other: RestoreTrigger) -> RestoreTrigger {
        priority >= other.priority ? self : other
    }

    var discoverySettleDelay: TimeInterval {
        switch self {
        case .launch, .displayChange:
            // The tracker performs follow-up scans through 1.5 seconds. Start
            // display-stability sampling only after that readiness window.
            1.7
        case .systemResume:
            // Session recovery is coordinated by inactive/active events and
            // starts from one fresh synchronous inventory pass.
            0
        default:
            0.65
        }
    }

    var requiresInventoryBarrier: Bool {
        switch self {
        case .launch, .systemResume, .spaceChange, .displayChange, .manual, .profileApply:
            true
        case .applicationLifecycle:
            false
        }
    }
}

struct RestoreRunSummary: Equatable {
    var moved: Int
    var unchanged: Int
    var skipped: Int
    var failed = 0
    var userAdjusted = 0
}

struct RestoreWindowScope {
    func includes(
        bundleIdentifier: String,
        trigger: RestoreTrigger,
        applicationBundleIdentifiers: Set<String>?
    ) -> Bool {
        guard trigger == .applicationLifecycle,
              let applicationBundleIdentifiers,
              !applicationBundleIdentifiers.isEmpty else {
            return true
        }
        return applicationBundleIdentifiers.contains(bundleIdentifier)
    }
}

struct ProfileTransitionPreview: Equatable, Identifiable {
    var profileID: String
    var profileName: String
    var willMove: Int
    var alreadyPlaced: Int
    var skipped: Int
    var unmatched: Int
    var issues: [RestoreIssue] = []

    var id: String { profileID }
}

enum RestoreIssueReason: String, Codable, Equatable {
    case notOnCurrentSpace
    case fullScreen
    case minimized
    case leftAlone
    case missingPlacement
    case frameUnavailable
    case appConstrainedPlacement
    case superseded

    var title: String {
        switch self {
        case .notOnCurrentSpace: "Not confirmed on the current Space"
        case .fullScreen: "Full-screen windows are left untouched"
        case .minimized: "Minimized windows are left untouched"
        case .leftAlone: "Window is set to be left alone"
        case .missingPlacement: "No placement exists for this display layout"
        case .frameUnavailable: "The current window frame could not be read"
        case .appConstrainedPlacement: "The app constrained the requested placement"
        case .superseded: "A newer placement replaced this restore"
        }
    }
}

struct RestoreIssue: Codable, Equatable, Identifiable {
    var id: UUID
    var appName: String
    var reason: RestoreIssueReason

    init(id: UUID = UUID(), appName: String, reason: RestoreIssueReason) {
        self.id = id
        self.appName = appName
        self.reason = reason
    }
}

struct RestoreRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var trigger: String
    var profileName: String
    var moved: Int
    var unchanged: Int
    var skipped: Int
    var failed: Int
    var unmatched: Int
    var issues: [RestoreIssue]

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        trigger: String,
        profileName: String,
        moved: Int,
        unchanged: Int,
        skipped: Int,
        failed: Int = 0,
        unmatched: Int = 0,
        issues: [RestoreIssue] = []
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.profileName = profileName
        self.moved = moved
        self.unchanged = unchanged
        self.skipped = skipped
        self.failed = failed
        self.unmatched = unmatched
        self.issues = issues
    }

}

enum WindowActionNotificationTone: Equatable {
    case accent
    case success
    case warning
}

struct WindowActionNotification: Equatable {
    var title: String
    var detail: String
    var symbolName: String
    var tone: WindowActionNotificationTone
    var actionTitle: String?
}

struct RestoreToastPolicy {
    func content(
        for trigger: RestoreTrigger,
        profileName: String,
        summary: RestoreRunSummary
    ) -> WindowActionNotification? {
        switch trigger {
        case .launch, .applicationLifecycle:
            return nil
        case .spaceChange, .systemResume:
            guard summary.moved > 0 || summary.failed > 0 else { return nil }
            return restoredContent(profileName: profileName, summary: summary)
        case .displayChange:
            guard summary.moved > 0 || summary.skipped > 0 || summary.failed > 0 else { return nil }
            return restoredContent(profileName: profileName, summary: summary)
        case .profileApply:
            if summary.moved == 0, summary.skipped == 0, summary.failed == 0 {
                return WindowActionNotification(
                    title: profileName,
                    detail: "Already up to date",
                    symbolName: "checkmark",
                    tone: .success,
                    actionTitle: nil
                )
            }
            return restoredContent(profileName: profileName, summary: summary)
        case .manual:
            if summary.moved == 0, summary.skipped == 0, summary.failed == 0 {
                return WindowActionNotification(
                    title: "Nothing to restore",
                    detail: "All assigned windows are already in place",
                    symbolName: "checkmark",
                    tone: .success,
                    actionTitle: nil
                )
            }
            return restoredContent(profileName: profileName, summary: summary)

        }
    }

    private func restoredContent(
        profileName: String,
        summary: RestoreRunSummary
    ) -> WindowActionNotification {
        let detail: String
        let tone: WindowActionNotificationTone
        let symbolName: String
        if summary.moved == 0 {
            var parts: [String] = []
            if summary.failed > 0 {
                parts.append(count(summary.failed, singular: "window could not be restored", plural: "windows could not be restored"))
            }
            if summary.skipped > 0 {
                parts.append(count(summary.skipped, singular: "window skipped", plural: "windows skipped"))
            }
            detail = parts.joined(separator: " · ")
            tone = .warning
            symbolName = "exclamationmark.triangle"
        } else {
            var parts = [count(summary.moved, singular: "window restored", plural: "windows restored")]
            if summary.userAdjusted > 0 {
                parts.append(count(summary.userAdjusted, singular: "user adjustment kept", plural: "user adjustments kept"))
            }
            if summary.failed > 0 {
                parts.append(count(summary.failed, singular: "failed", plural: "failed"))
            }
            if summary.skipped > 0 {
                parts.append(count(summary.skipped, singular: "skipped", plural: "skipped"))
            }
            detail = parts.joined(separator: " · ")
            tone = summary.skipped > 0 || summary.failed > 0 ? .warning : .success
            symbolName = summary.skipped > 0 || summary.failed > 0 ? "exclamationmark.triangle" : "checkmark"
        }
        return WindowActionNotification(
            title: profileName,
            detail: detail,
            symbolName: symbolName,
            tone: tone,
            actionTitle: summary.moved > 0 ? "Undo" : nil
        )
    }

    private func count(_ value: Int, singular: String, plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

@MainActor
final class RestoreEngine {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "Restore")

    private let profileManager: ProfileManager
    private let windowRegistry: WindowRegistry
    private let windowTracker: WindowTracker
    private let windowController: WindowController
    private let workspaceState: WorkspaceStateService
    private let store: PersistenceStore
    private let clock: any ZonalClock
    private lazy var hud = WindowActionNotificationController(store: store)
    private let diagnosticHUD = InteractionDiagnosticHUDController()

    private var pendingWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var pendingSignature: DisplaySignature?
    private var pendingTrigger: RestoreTrigger?
    private var pendingApplicationBundleIdentifiers = Set<String>()
    private var stabilityCount = 0
    private var stabilityStartedAt: Date?
    private var undoStack: [WindowUndoTransaction] = []
    private var isUndoing = false
    var onUndoChanged: (() -> Void)?
    private var reflowZones = Set<ZoneID>()
    private var overlapReflowZones = Set<ZoneID>()
    private var reflowWork: DispatchWorkItem?
    private var forcedProfileID: String?
    private var lastUnmatchedSignatureShown: DisplaySignature?
    private var restoreBarrierGeneration: UUID?
    private var isPerformingInventoryBarrier = false
    private var sessionRestoreTargets: [UUID: WorkspaceRestoreTarget] = [:]
    private var lastKnownSessionDisplayExpectation: SessionDisplayExpectation?
    private var lastKnownSessionRestoreTargets: [UUID: WorkspaceRestoreTarget] = [:]
    private var sessionDisplayReadiness = SessionDisplayReadinessState()
    private var sessionDisplayWorkItem: DispatchWorkItem?
    private var sessionDisplayChangePending = false
    private var recentSessionSignals: [String] = []
    private var sessionSignalPolicy = SessionRecoverySignalPolicy()
    var isTabPresentationSuspended: Bool { !sessionSignalPolicy.canPresentTabs }
    private var startupInventoryUntil = Date.distantPast

    init(
        profileManager: ProfileManager,
        windowRegistry: WindowRegistry,
        windowTracker: WindowTracker,
        windowController: WindowController,
        workspaceState: WorkspaceStateService,
        store: PersistenceStore,
        clock: any ZonalClock = SystemZonalClock()
    ) {
        self.profileManager = profileManager
        self.windowRegistry = windowRegistry
        self.windowTracker = windowTracker
        self.windowController = windowController
        self.workspaceState = workspaceState
        self.store = store
        self.clock = clock
    }

    func start() {
        undoStack = store.loadUndoJournal()
        startupInventoryUntil = clock.now.addingTimeInterval(RestoreTrigger.launch.discoverySettleDelay)
        rememberCurrentDisplaySetup()
        windowTracker.onWindowDiscovered = { [weak self] window in
            guard let self, self.clock.now >= self.startupInventoryUntil else { return }
            self.scheduleRestore(
                trigger: .applicationLifecycle,
                applicationBundleIdentifier: window.identity.bundleIdentifier,
                refreshWindows: false
            )
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionSignal(
                        name == NSWorkspace.sessionDidResignActiveNotification ? .inactive : .displaySleep,
                        name: name.rawValue
                    )
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionSignal(.wake, name: name.rawValue)
                }
            })
        }
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSessionSignal(.active, name: NSWorkspace.sessionDidBecomeActiveNotification.rawValue)
            }
        })
        let distributedCenter = DistributedNotificationCenter.default()
        let screenLocked = Notification.Name("com.apple.screenIsLocked")
        let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
        distributedObservers.append(
            distributedCenter.addObserver(forName: screenLocked, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionSignal(.inactive, name: screenLocked.rawValue)
                }
            }
        )
        distributedObservers.append(
            distributedCenter.addObserver(forName: screenUnlocked, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionSignal(.active, name: screenUnlocked.rawValue)
                }
            }
        )
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRestore(trigger: .spaceChange)
            }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let bundleIdentifier,
                      bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }
                self?.scheduleRestore(
                    trigger: .applicationLifecycle,
                    applicationBundleIdentifier: bundleIdentifier
                )
            }
        })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDisplayChange() }
            }
        )
        scheduleRestore(trigger: .launch)
    }

    func stop() {
        pendingWorkItem?.cancel()
        reflowWork?.cancel()
        reflowZones.removeAll()
        overlapReflowZones.removeAll()
        sessionDisplayWorkItem?.cancel()
        sessionDisplayWorkItem = nil
        restoreBarrierGeneration = nil
        isPerformingInventoryBarrier = false
        sessionRestoreTargets.removeAll()
        sessionDisplayReadiness.finish()
        sessionDisplayChangePending = false
        workspaceState.finishSessionRecovery()
        windowTracker.onWindowDiscovered = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
        hud.hide()
    }

    func scheduleRestore(
        trigger: RestoreTrigger,
        applicationBundleIdentifier: String? = nil,
        refreshWindows: Bool = true
    ) {
        guard store.loadConfiguration().behavior.allows(trigger) else {
            if trigger == .systemResume { finishSessionRecovery() }
            return
        }
        if trigger == .systemResume {
            restoreSessionAfterUnlock()
            return
        }
        if workspaceState.isSessionRecoveryActive {
            return
        }
        if isPerformingInventoryBarrier, trigger == .applicationLifecycle {
            return
        }
        restoreBarrierGeneration = nil
        isPerformingInventoryBarrier = false
        if refreshWindows
            && (trigger == .launch || trigger == .systemResume || trigger == .displayChange) {
            windowTracker.rescan(reason: "restore-scheduled-\(trigger.logLabel)")
        }
        pendingWorkItem?.cancel()
        pendingTrigger = pendingTrigger.map { trigger.preferred(over: $0) } ?? trigger
        let effectiveTrigger = pendingTrigger ?? trigger
        if trigger == .applicationLifecycle {
            if let applicationBundleIdentifier {
                pendingApplicationBundleIdentifiers.insert(applicationBundleIdentifier)
            }
        } else if trigger.priority > RestoreTrigger.applicationLifecycle.priority {
            pendingApplicationBundleIdentifiers.removeAll()
        }
        stabilityStartedAt = stabilityStartedAt ?? clock.now
        let item = DispatchWorkItem { [weak self] in
            self?.restoreWhenStable()
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + effectiveTrigger.discoverySettleDelay,
            execute: item
        )
    }

    private func handleDisplayChange() {
        if workspaceState.isSessionRecoveryActive {
            sessionDisplayReadiness.invalidateCandidate()
            sessionDisplayChangePending = true
            return
        }
        // macOS emits frame changes before our delayed restore can verify placement.
        let generation = workspaceState.beginDisplayTransition()
        if store.loadConfiguration().behavior.allows(.displayChange) {
            scheduleRestore(trigger: .displayChange)
        } else {
            windowTracker.rescan(reason: "display-change-without-restore") { [weak self] _ in
                self?.workspaceState.finishDisplayTransition(generation: generation)
            }
        }
    }

    private func handleSessionSignal(_ signal: SessionRecoverySignalPolicy.Signal, name: String) {
        recordSessionSignal(name)
        switch sessionSignalPolicy.action(for: signal) {
        case .freeze: beginSessionRecovery()
        case .restore: restoreSessionAfterUnlock()
        }
        windowTracker.setSessionInactive(!sessionSignalPolicy.canPresentTabs)
    }

    private func beginSessionRecovery() {
        rememberCurrentDisplaySetup(onlyIfConsistentWithLastKnown: true)
        guard workspaceState.beginSessionRecovery() else { return }
        sessionRestoreTargets = lastKnownSessionRestoreTargets
        cancelPendingRestoreScheduling()
        Self.logger.info(
            "Session recovery began with \(self.sessionRestoreTargets.count) frozen targets and expectedProfile=\(self.lastKnownSessionDisplayExpectation?.profileID ?? "none", privacy: .public)"
        )
    }

    private func cancelPendingRestoreScheduling() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingTrigger = nil
        pendingApplicationBundleIdentifiers.removeAll()
        pendingSignature = nil
        stabilityCount = 0
        stabilityStartedAt = nil
        restoreBarrierGeneration = nil
        isPerformingInventoryBarrier = false
    }

    private func restoreSessionAfterUnlock() {
        guard store.loadConfiguration().behavior.restoreOnWake else { finishSessionRecovery(); return }
        beginSessionRecovery()
        guard workspaceState.isSessionRecoveryActive else { return }
        guard sessionDisplayReadiness.startedAt == nil else { return }
        sessionDisplayReadiness.begin(
            expectation: lastKnownSessionDisplayExpectation,
            now: clock.now
        )
        cancelPendingRestoreScheduling()
        windowTracker.rescan(reason: "session-active-restore") { [weak self] _ in
            guard let self,
                  self.workspaceState.markSessionRecoveryInventoryReady() else { return }
            self.attemptSessionRestoreWhenDisplayReady()
        }
    }

    private func attemptSessionRestoreWhenDisplayReady() {
        guard workspaceState.isSessionRecoveryActive else { return }
        let snapshot = profileManager.currentSnapshot()
        let profile = profileManager.matchedProfile(for: snapshot)
        let setupBindingID = profile.flatMap {
            profileManager.matchedSetupBinding(for: $0, snapshot: snapshot)?.id
        }
        switch sessionDisplayReadiness.observe(
            profileID: profile?.id,
            setupBindingID: setupBindingID,
            signature: profileManager.signature(for: snapshot),
            now: clock.now
        ) {
        case .ready:
            sessionDisplayWorkItem?.cancel()
            sessionDisplayWorkItem = nil
            windowTracker.reconcile { [weak self] in
                guard let self, self.workspaceState.beginSessionRestore() else { return }
                self.applyRestore(trigger: .systemResume)
            }
        case .waiting:
            let item = DispatchWorkItem { [weak self] in
                self?.attemptSessionRestoreWhenDisplayReady()
            }
            sessionDisplayWorkItem?.cancel()
            sessionDisplayWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        case .timedOut:
            Self.logger.warning(
                "Session recovery timed out without a stable configured display setup; saved placements were preserved"
            )
            // Stale focus reflows must not resize windows when recovery could not verify a destination.
            reflowWork?.cancel()
            reflowZones.removeAll()
            overlapReflowZones.removeAll()
            sessionDisplayChangePending = false
            finishSessionRecovery()
        }
    }

    private func rememberCurrentDisplaySetup(
        onlyIfConsistentWithLastKnown: Bool = false
    ) {
        guard !workspaceState.isSessionRecoveryActive else { return }
        let snapshot = profileManager.currentSnapshot()
        guard let profile = profileManager.matchedProfile(for: snapshot),
              let setupBinding = profileManager.matchedSetupBinding(
                  for: profile,
                  snapshot: snapshot
              ) else { return }
        let expectation = SessionDisplayExpectation(
            profileID: profile.id,
            setupBindingID: setupBinding.id,
            signature: profileManager.signature(for: snapshot)
        )
        if onlyIfConsistentWithLastKnown,
           let lastKnownSessionDisplayExpectation,
           expectation != lastKnownSessionDisplayExpectation {
            return
        }
        lastKnownSessionDisplayExpectation = expectation
        lastKnownSessionRestoreTargets = workspaceState.restoreTargetsByAssignmentID()
    }

    func restoreNow(trigger: RestoreTrigger) {
        pendingWorkItem?.cancel()
        pendingTrigger = nil
        pendingApplicationBundleIdentifiers.removeAll()
        stabilityStartedAt = nil
        stabilityCount = 0
        pendingSignature = nil
        if trigger.requiresInventoryBarrier {
            applyAfterInventoryBarrier(trigger: trigger)
        } else {
            applyRestore(trigger: trigger)
        }
    }

    func applyProfileNow(_ profileID: String) {
        forcedProfileID = profileID
        restoreNow(trigger: .profileApply)
    }

    func previewProfile(_ profileID: String) -> ProfileTransitionPreview? {
        let snapshot = profileManager.currentSnapshot()
        guard let profile = store.loadProfiles(forceReload: true).first(where: { $0.id == profileID }) else {
            return nil
        }
        let context = workspaceState.currentProfileContext()
        var willMove = 0
        var alreadyPlaced = 0
        var skipped = 0
        var issues: [RestoreIssue] = []
        let liveAssignments = context.windows.compactMap {
            workspaceState.assignment(for: $0, context: context)
        }

        for window in context.windows {
            guard let assignment = workspaceState.assignment(for: window, context: context) else { continue }
            if assignment.managementMode == .ignored {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .leftAlone))
                continue
            }
            if windowController.isFullScreen(window) {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .fullScreen))
                continue
            }
            if windowController.isMinimized(window) {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .minimized))
                continue
            }
            guard let target = workspaceState.targetFrame(
                for: assignment,
                profile: profile,
                snapshot: snapshot,
                stackAssignments: liveAssignments
            ) else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .missingPlacement))
                continue
            }
            guard let frame = windowController.frame(of: window) else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .frameUnavailable))
                continue
            }
            if PlacementNoOpPolicy.shouldSkip(actual: frame, target: target.frame) {
                alreadyPlaced += 1
            } else {
                willMove += 1
            }
        }

        let matchedAssignmentIDs = Set(context.windows.compactMap { window in
            workspaceState.assignment(for: window, context: context)?.id
        })
        let excludedBundleIdentifiers = Set(store.loadConfiguration().excludedBundleIdentifiers)
        let unmatched = context.assignments.filter {
            !excludedBundleIdentifiers.contains($0.fingerprint.bundleIdentifier)
                && !matchedAssignmentIDs.contains($0.id)
        }.count
        return ProfileTransitionPreview(
            profileID: profile.id,
            profileName: profile.name,
            willMove: willMove,
            alreadyPlaced: alreadyPlaced,
            skipped: skipped,
            unmatched: unmatched,
            issues: issues
        )
    }

    func scheduleZoneReflow(_ zoneID: ZoneID, includeOverlap: Bool = false, immediately: Bool = false) {
        reflowZones.insert(zoneID)
        if includeOverlap { overlapReflowZones.insert(zoneID) }
        scheduleReflowWork(delay: immediately ? 0 : 0.08)
    }

    private func scheduleReflowWork(delay: TimeInterval = 0.08) {
        reflowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reflowPendingZones() }
        reflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reflowPendingZones() {
        let zones = reflowZones
        let overlapZones = overlapReflowZones
        // Resume from finishSessionRecovery rather than polling throughout a locked session.
        guard !workspaceState.isSessionRecoveryActive, !workspaceState.isDisplayTransitionActive else { return }
        guard !isUndoing, !windowController.hasActiveUserInteraction else {
            scheduleReflowWork()
            return
        }
        reflowZones.removeAll()
        overlapReflowZones.removeAll()
        let context = workspaceState.currentProfileContext()
        let assignments = context.windows.compactMap { workspaceState.assignment(for: $0, context: context) }
        let busyZones = Set(context.windows.compactMap { window -> ZoneID? in
            guard windowController.hasPendingPlacement(to: window),
                  let assignment = workspaceState.assignment(for: window, context: context),
                  zones.contains(assignment.zoneID) else { return nil }
            return assignment.zoneID
        })
        // Wait for manual placement before reflowing its zone; never supersede its completion.
        if !busyZones.isEmpty {
            reflowZones.formUnion(busyZones)
            overlapReflowZones.formUnion(overlapZones.intersection(busyZones))
            scheduleReflowWork()
        }
        for window in context.windows {
            guard let assignment = workspaceState.assignment(for: window, context: context),
                  ZoneReflowPolicy.includes(assignment, zones: zones, profile: context.profile,
                      busyZones: busyZones, includeOverlap: overlapZones.contains(assignment.zoneID)),
                  !windowController.isFullScreen(window), !windowController.isMinimized(window),
                  let target = workspaceState.targetFrame(for: assignment, profile: context.profile,
                                                        snapshot: context.snapshot, stackAssignments: assignments) else { continue }
            windowController.move(window, to: target.frame, in: target.container, reason: .zoneReflow)
        }
    }

    func performTabAction(assignmentID: UUID, action: ZoneTabAction) {
        let context = workspaceState.currentProfileContext()
        guard !isTabPresentationSuspended,
              let assignment = context.assignments.first(where: { $0.id == assignmentID }),
              assignment.managementMode == .managed,
              let window = windowRegistry.bestMatch(for: assignment, in: context.windows),
              !windowController.isFullScreen(window), !windowController.isMinimized(window),
              let frame = windowController.frame(of: window) else { return }
        let change: ManualWindowChange?
        switch action {
        case .move(let zoneID):
            guard zoneID != assignment.zoneID else { return }
            change = workspaceState.tabMoveChange(for: assignment, currentFrame: frame, to: zoneID, context: context)
        case .fit:
            change = .fit(assignment.zoneID)
        case .restoreCustom:
            change = workspaceState.restoreCustomChange(for: assignment, context: context)
        case .close:
            windowController.close(window) { [weak self] accepted in
                guard !accepted else { return }
                self?.hud.show(WindowActionNotification(title: "Could Not Close Window",
                    detail: "The app did not accept the close request", symbolName: "xmark.rectangle", tone: .warning), onAction: nil)
            }
            return
        }
        guard let change else { return }
        performManualAction(window: window, change: change, bringToFrontAfterMove: true)
    }

    func updateWindowAssignment(_ assignmentID: UUID, zoneID: ZoneID, fitToZone: Bool) {
        let context = workspaceState.currentProfileContext()
        guard let assignment = context.assignments.first(where: { $0.id == assignmentID }) else { return }
        if let window = windowRegistry.bestMatch(for: assignment, in: context.windows) {
            performManualAction(window: window, change: fitToZone ? .fit(zoneID) : .membership(zoneID))
        } else {
            workspaceState.updateAssignment(assignmentID, zoneID: zoneID, fitToZone: fitToZone)
        }
    }

    func performManualAction(
        window: ManagedWindow, change: ManualWindowChange, before: WindowActionSnapshot? = nil,
        bringToFrontAfterMove: Bool = false,
        completion: ((WindowPlacementOutcome) -> Void)? = nil
    ) {
        guard let before = before ?? windowController.frame(of: window).map({
            workspaceState.actionSnapshot(for: window, frame: $0)
        }) else { completion?(.constrained); return }
        if case .custom = change { prepareManualUndo(snapshot: before, name: change.name) }
        let previousZone = workspaceState.zone(for: window)
        let saveResult: WorkspaceSaveResult
        switch change {
        case .fit(let zone):
            saveResult = workspaceState.assignWindow(window, to: zone, clearCustomFrame: true, customFrameBeforeFit: before.frame)
        case .move(let zone, let frame):
            saveResult = workspaceState.assignCustomFrame(window, to: zone, frame: frame)
        case .membership(let zone):
            if let assignment = workspaceState.assignment(for: window) {
                saveResult = workspaceState.updateAssignment(assignment.id, zoneID: zone, fitToZone: false)
            } else { saveResult = .unavailable }
        case .custom(let zone, let frame, _):
            saveResult = workspaceState.assignCustomFrame(window, to: zone ?? previousZone, frame: frame)
        }
        guard saveResult == .saved else {
            if saveResult == .failed {
                if case .custom = change { presentPersistenceFailure() }
                else {
                    presentPersistenceFailure(retry: { [weak self] in
                        self?.performManualAction(window: window, change: change, before: before,
                            bringToFrontAfterMove: bringToFrontAfterMove, completion: completion)
                    })
                }
            }
            else {
                hud.show(WindowActionNotification(title: "Window Position Not Saved",
                    detail: "Configure this display setup before saving a placement",
                    symbolName: "display.trianglebadge.exclamationmark", tone: .warning,
                    actionTitle: "Configure"), onAction: { AppContainer.shared.openSettings() })
            }
            completion?(.notSaved)
            return
        }
        if case .custom = change {} else { prepareManualUndo(snapshot: before, name: change.name) }
        switch change {
        case .fit, .move:
            if !bringToFrontAfterMove { workspaceState.markFocusedWindowActive() }
            let context = workspaceState.currentProfileContext()
            guard let assignment = workspaceState.assignment(for: window, context: context),
                  let target = workspaceState.targetFrame(for: assignment, profile: context.profile,
                      snapshot: context.snapshot, stackAssignments: context.windows.compactMap {
                          workspaceState.assignment(for: $0, context: context)
                      }) else { completion?(.constrained); return }
            let requestedFrame: CGRect
            if case .move(_, let frame) = change { requestedFrame = frame } else { requestedFrame = target.frame }
            windowController.move(window, to: requestedFrame, in: target.container, reason: .assignment) { [weak self] outcome in
                completion?(outcome)
                guard let self else { return }
                if bringToFrontAfterMove, outcome == .placed || outcome == .constrained {
                    self.windowController.focus(window)
                }
                if completion == nil {
                    self.hud.show(WindowActionNotification(
                        title: outcome == .placed ? "Window Moved" : "Could Not Move Window",
                        detail: outcome == .placed
                            ? (assignment.fitsZone(in: context.profile.id) ? "Window fitted to its zone" : "Window moved to its zone")
                            : "The app did not accept the requested placement",
                        symbolName: "rectangle.portrait.and.arrow.forward",
                        tone: outcome == .placed ? .accent : .warning, actionTitle: "Undo"
                    ), onAction: { [weak self] in self?.undoLastAction() })
                }
                self.scheduleZoneReflow(previousZone)
                self.scheduleZoneReflow(assignment.zoneID)
            }
        case .custom, .membership:
            completion?(.placed)
            scheduleZoneReflow(previousZone)
            scheduleZoneReflow(workspaceState.zone(for: window))
        }
    }

    func detailedDiagnosticLines() -> [String] {
        let signals = recentSessionSignals.isEmpty
            ? "none"
            : recentSessionSignals.joined(separator: " | ")
        return [
            "Recovery display gate: active=\(workspaceState.isSessionRecoveryActive) expectedProfile=\(sessionDisplayReadiness.expectation?.profileID ?? "none") stableSamples=\(sessionDisplayReadiness.stableSamples)/\(sessionDisplayReadiness.requiredStableSamples) frozenTargets=\(sessionRestoreTargets.count)",
            "Recent session signals: \(signals)"
        ]
    }

    private func recordSessionSignal(_ signal: String) {
        recentSessionSignals.append("\(clock.now.formatted(.iso8601)) \(signal)")
        if recentSessionSignals.count > 12 {
            recentSessionSignals.removeFirst(recentSessionSignals.count - 12)
        }
        Self.logger.info("Session signal: \(signal, privacy: .public)")
    }

    func undoLastAction() {
        guard !isUndoing, let transaction = undoStack.last, !transaction.entries.isEmpty else { return }
        isUndoing = true
        onUndoChanged?()
        let context = workspaceState.currentProfileContext()
        let batch = WindowUndoBatch(entries: transaction.entries)
        // Keep the journal entry on disk until every placement has a verified outcome.
        for (index, entry) in transaction.entries.enumerated() {
            let complete: (WindowPlacementOutcome) -> Void = { [weak self] outcome in
                guard let self else { return }
                guard batch.complete(index: index, outcome: outcome) else { return }
                let previousJournal = self.undoStack
                guard self.store.flushPendingWorkspaceWrite() else {
                    self.isUndoing = false
                    self.onUndoChanged?()
                    self.presentJournalFailure()
                    return
                }
                if let journalIndex = self.undoStack.firstIndex(where: { $0.id == transaction.id }) {
                    if batch.failedEntries.isEmpty {
                        self.undoStack.remove(at: journalIndex)
                    } else {
                        self.undoStack[journalIndex].entries = batch.failedEntries
                    }
                }
                if !self.persistUndoStack() {
                    self.undoStack = previousJournal
                    self.isUndoing = false
                    self.onUndoChanged?()
                    return
                }
                self.isUndoing = false
                self.onUndoChanged?()
                self.presentUndoResult(restored: batch.restored, failed: batch.failedEntries.count)
            }
            guard let window = windowRegistry.bestMatch(for: entry.identity, in: context.windows),
                  !windowController.isFullScreen(window), !windowController.isMinimized(window) else {
                complete(.constrained)
                continue
            }
            windowController.move(window, to: entry.frame, reason: .undo) { [weak self] outcome in
                if outcome == .placed, let snapshot = entry.assignmentSnapshot,
                   self?.workspaceState.restoreAssignmentState(from: snapshot, for: window) != .saved {
                    self?.presentPersistenceFailure()
                    complete(.constrained)
                    return
                }
                complete(outcome)
            }
        }
    }

    var recentActions: [WindowUndoTransaction] { undoStack.reversed() }

    var canUndoLastAction: Bool { !isUndoing && !undoStack.isEmpty }

    private func presentUndoResult(restored: Int, failed: Int) {
        let detail: String
        if failed == 0 {
            detail = restored == 1 ? "1 window returned" : "\(restored) windows returned"
        } else {
            detail = "\(restored) returned · \(failed) unavailable or constrained"
        }
        hud.show(
            WindowActionNotification(
                title: failed == 0 ? "Action Undone" : "Undo Incomplete",
                detail: detail,
                symbolName: "arrow.uturn.backward",
                tone: failed == 0 ? .accent : .warning,
                actionTitle: failed == 0 ? nil : "Retry"
            ),
            onAction: failed == 0 ? nil : { [weak self] in self?.undoLastAction() }
        )
    }

    func presentPlacementFeedback(
        snapshot: WindowActionSnapshot,
        content: WindowActionNotification
    ) {
        hud.show(
            content,
            onAction: content.actionTitle == nil ? nil : { [weak self] in
                self?.undoLastAction()
            }
        )
    }

    func prepareManualUndo(snapshot: WindowActionSnapshot, name: String) {
        registerUndo(
            WindowUndoTransaction(
                name: name,
                entries: [
                    WindowUndoEntry(
                        identity: snapshot.identity,
                        frame: snapshot.frame,
                        assignmentSnapshot: snapshot
                    )
                ]
            )
        )
    }

    func presentInteractionDiagnostic(_ event: WindowInteractionEvent) {
        guard event.kind != .observing else { return }
        diagnosticHUD.show(event)
    }

    private func registerUndo(_ transaction: WindowUndoTransaction) {
        undoStack.append(transaction)
        if undoStack.count > 20 {
            undoStack.removeFirst(undoStack.count - 20)
        }
        persistUndoStack()
    }

    @discardableResult
    private func persistUndoStack() -> Bool {
        let saved = store.saveUndoJournal(undoStack)
        onUndoChanged?()
        if !saved { presentJournalFailure() }
        return saved
    }

    func presentPersistenceFailure(retry: (() -> Void)? = nil) {
        hud.show(WindowActionNotification(
            title: "Could Not Save Changes",
            detail: "Check available disk space and try again",
            symbolName: "exclamationmark.triangle", tone: .warning, actionTitle: "Retry"
        ), onAction: retry ?? { [weak self] in
            guard let self else { return }
            if self.store.flushPendingWorkspaceWrite() { self.hud.hide() }
            else { self.presentPersistenceFailure() }
        })
    }

    private func presentJournalFailure() {
        hud.show(WindowActionNotification(
            title: "Could Not Save Window History",
            detail: "Undo state is retained in memory. Check available disk space before quitting.",
            symbolName: "exclamationmark.triangle", tone: .warning, actionTitle: nil
        ), onAction: nil)
    }

    func assignFocusedWindow(to zoneID: ZoneID) {
        guard let window = windowRegistry.focusedWindow(),
              let frame = windowController.frame(of: window) else { return }
        performManualAction(window: window, change: .fit(zoneID),
                            before: workspaceState.actionSnapshot(for: window, frame: frame))
    }

    @discardableResult
    func assignFocusedWindow(in direction: SwitcherArrowKey) -> ZoneID? {
        guard let window = windowRegistry.focusedWindow(),
              let zoneID = workspaceState.neighboringZoneID(
                  for: window,
                  direction: direction
              ) else {
            return nil
        }
        guard let frame = windowController.frame(of: window) else { return nil }
        performManualAction(window: window, change: .fit(zoneID),
                            before: workspaceState.actionSnapshot(for: window, frame: frame))
        return zoneID
    }

    @discardableResult
    func focusZone(_ zoneID: ZoneID) -> Bool {
        let context = workspaceState.currentProfileContext()
        let history = store.loadZoneStackState().assignmentRecencyByZone[zoneID] ?? []
        let assignments = context.assignments
            .filter { $0.zoneID == zoneID }
            .sorted { lhs, rhs in
                let lhsIndex = history.firstIndex(of: lhs.id) ?? Int.max
                let rhsIndex = history.firstIndex(of: rhs.id) ?? Int.max
                return lhsIndex < rhsIndex
            }
        for assignment in assignments {
            guard let window = windowRegistry.bestMatch(for: assignment, in: context.windows) else { continue }
            windowController.focus(window)
            return true
        }
        return false
    }

    @discardableResult
    func focusNextWindowInStack(direction: Int) -> Bool {
        workspaceState.focusNextWindow(direction: direction)
    }

    private func restoreWhenStable() {
        let trigger = pendingTrigger ?? .applicationLifecycle
        let snapshot = profileManager.currentSnapshot()
        let signature = profileManager.signature(for: snapshot)
        if signature == pendingSignature {
            stabilityCount += 1
        } else {
            pendingSignature = signature
            stabilityCount = 1
        }

        let elapsed = stabilityStartedAt.map { clock.now.timeIntervalSince($0) } ?? 0
        guard stabilityCount >= 2 || elapsed >= 10 else {
            scheduleRestore(
                trigger: trigger,
                applicationBundleIdentifier: nil,
                refreshWindows: false
            )
            return
        }
        pendingTrigger = nil
        let applicationBundleIdentifiers = pendingApplicationBundleIdentifiers
        pendingApplicationBundleIdentifiers.removeAll()
        stabilityStartedAt = nil
        stabilityCount = 0
        pendingSignature = nil
        let scope = applicationBundleIdentifiers.isEmpty
            ? nil
            : applicationBundleIdentifiers
        if trigger.requiresInventoryBarrier {
            applyAfterInventoryBarrier(
                trigger: trigger,
                applicationBundleIdentifiers: scope
            )
        } else {
            applyRestore(
                trigger: trigger,
                applicationBundleIdentifiers: scope
            )
        }
    }

    private func applyAfterInventoryBarrier(
        trigger: RestoreTrigger,
        applicationBundleIdentifiers: Set<String>? = nil
    ) {
        let generation = UUID()
        restoreBarrierGeneration = generation
        isPerformingInventoryBarrier = true
        windowTracker.rescan(reason: "restore-barrier-\(trigger.logLabel)") { [weak self] _ in
            guard let self,
                  self.restoreBarrierGeneration == generation else { return }
            self.restoreBarrierGeneration = nil
            self.isPerformingInventoryBarrier = false
            self.applyRestore(
                trigger: trigger,
                applicationBundleIdentifiers: applicationBundleIdentifiers
            )
        }
    }

    private func applyRestore(
        trigger: RestoreTrigger,
        applicationBundleIdentifiers: Set<String>? = nil
    ) {
        let displayGeneration = workspaceState.displayTransitionGeneration
        guard store.loadConfiguration().behavior.allows(trigger) else {
            finishDisplayTransition(generation: displayGeneration)
            if trigger == .systemResume { finishSessionRecovery() }
            return
        }
        guard !windowController.hasActiveUserInteraction else {
            Self.logger.debug("Deferred restore while a user window gesture is active")
            pendingWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.applyRestore(
                    trigger: trigger,
                    applicationBundleIdentifiers: applicationBundleIdentifiers
                )
            }
            pendingWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
            return
        }
        let snapshot = profileManager.currentSnapshot()
        let profiles = store.loadProfiles(forceReload: true)
        let forcedProfile = forcedProfileID.flatMap { profileID in
            profiles.first { $0.id == profileID }
        }
        forcedProfileID = nil
        guard let profile = forcedProfile ?? profileManager.matchedProfile(for: snapshot) else {
            if trigger == .systemResume {
                workspaceState.retrySessionRestore()
                sessionDisplayReadiness.invalidateCandidate()
                attemptSessionRestoreWhenDisplayReady()
                return
            }
            if trigger != .applicationLifecycle,
               trigger != .spaceChange,
               lastUnmatchedSignatureShown != profileManager.signature(for: snapshot) {
                hud.show(
                    WindowActionNotification(
                        title: "Display setup not configured",
                        detail: "Windows were left unchanged",
                        symbolName: "display.trianglebadge.exclamationmark",
                        tone: .warning,
                        actionTitle: "Configure"
                    ),
                    onAction: {
                        AppContainer.shared.openSettings()
                    }
                )
                lastUnmatchedSignatureShown = profileManager.signature(for: snapshot)
            }
            Self.logger.info("Skipped restore because no display setup matched")
            finishDisplayTransition(generation: displayGeneration)
            if trigger == .systemResume {
                finishSessionRecovery()
            }
            return
        }
        if trigger == .systemResume {
            let destination = profileManager.matchedSetupBinding(for: profile, snapshot: snapshot).map {
                SessionDisplayExpectation(profileID: profile.id, setupBindingID: $0.id,
                                          signature: profileManager.signature(for: snapshot))
            }
            guard let destination, destination == sessionDisplayReadiness.readyDestination else {
                workspaceState.retrySessionRestore()
                sessionDisplayReadiness.invalidateCandidate()
                attemptSessionRestoreWhenDisplayReady()
                return
            }
            sessionDisplayChangePending = false
            Self.logger.info("Session restore destination=\(destination.profileID, privacy: .public) frozenTargets=\(self.sessionDisplayReadiness.usesFrozenTargets)")
            if !sessionDisplayReadiness.usesFrozenTargets {
                sessionRestoreTargets = workspaceState.restoreTargetsByAssignmentID()
            }
        }
        lastUnmatchedSignatureShown = nil
        if trigger != .systemResume {
            if let setupBinding = profileManager.matchedSetupBinding(
                for: profile,
                snapshot: snapshot
            ) {
                lastKnownSessionDisplayExpectation = SessionDisplayExpectation(
                    profileID: profile.id,
                    setupBindingID: setupBinding.id,
                    signature: profileManager.signature(for: snapshot)
                )
                lastKnownSessionRestoreTargets = workspaceState.restoreTargetsByAssignmentID()
            }
        }

        workspaceState.reconcile()
        let context = workspaceState.profileContext(snapshot: snapshot, profile: profile)
        var unchanged = 0
        var skipped = 0
        var userAdjusted = 0
        var nextUndo: [WindowUndoEntry] = []
        var candidates: [RestorePlanCandidate] = []
        var issues: [RestoreIssue] = []
        let windowScope = RestoreWindowScope()
        let liveAssignments = context.windows.compactMap {
            workspaceState.assignment(for: $0, context: context)
        }
        let matchedAssignmentIDs = Set(context.windows.compactMap { window in
            workspaceState.assignment(for: window, context: context)?.id
        })
        let excludedBundleIdentifiers = Set(store.loadConfiguration().excludedBundleIdentifiers)
        let unmatched = context.assignments.filter {
            !excludedBundleIdentifiers.contains($0.fingerprint.bundleIdentifier)
                && !matchedAssignmentIDs.contains($0.id)
        }.count

        for window in context.windows {
            guard windowTracker.isConfirmedOnCurrentSpace(window) else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .notOnCurrentSpace))
                continue
            }
            guard let assignment = workspaceState.assignment(for: window, context: context) else {
                continue
            }
            guard assignment.managementMode == .managed else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .leftAlone))
                continue
            }
            if trigger == .systemResume,
               !workspaceState.shouldRestoreDuringSessionRecovery(window) {
                userAdjusted += 1
                continue
            }
            if !workspaceState.shouldRestoreAfterDisplayChange(window) {
                userAdjusted += 1
                continue
            }
            if !windowScope.includes(
                bundleIdentifier: assignment.fingerprint.bundleIdentifier,
                trigger: trigger,
                applicationBundleIdentifiers: applicationBundleIdentifiers
            ) {
                continue
            }
            if windowController.isFullScreen(window) {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .fullScreen))
                continue
            }
            if windowController.isMinimized(window) {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .minimized))
                continue
            }
            guard let previousFrame = windowController.frame(of: window) else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .frameUnavailable))
                continue
            }
            let currentTarget = workspaceState.targetFrame(
                for: assignment,
                profile: profile,
                snapshot: snapshot,
                stackAssignments: liveAssignments,
                currentFrame: previousFrame
            ).map { WorkspaceRestoreTarget(frame: $0.frame, container: $0.container) }
            let target = trigger == .systemResume
                ? sessionRestoreTargets[assignment.id]
                : currentTarget
            guard let target else {
                skipped += 1
                issues.append(RestoreIssue(appName: window.appName, reason: .missingPlacement))
                continue
            }
            candidates.append(
                RestorePlanCandidate(
                    windowID: window.id,
                    identity: window.identity,
                    currentFrame: previousFrame,
                    targetFrame: target.frame,
                    containerFrame: target.container
                )
            )
        }

        let plan = RestorePlanner().plan(candidates)
        unchanged = plan.unchangedWindowIDs.count
        let windowByID = Dictionary(uniqueKeysWithValues: context.windows.map { ($0.id, $0) })
        guard !plan.moves.isEmpty else {
            finishRestore(
                trigger: trigger,
                profile: profile,
                moved: 0,
                unchanged: unchanged,
                skipped: skipped,
                failed: 0,
                unmatched: unmatched,
                issues: issues,
                userAdjusted: userAdjusted,
                undoEntries: [],
                displayGeneration: displayGeneration
            )
            return
        }

        var didFinish = false
        var pendingPlacements = plan.moves.count
        var verifiedMoves = 0
        var failedMoves = 0
        for move in plan.moves {
            guard let window = windowByID[move.windowID] else {
                pendingPlacements -= 1
                skipped += 1
                continue
            }
            windowController.move(
                window,
                to: move.targetFrame,
                in: move.containerFrame,
                reason: .restore
            ) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .placed:
                    verifiedMoves += 1
                    nextUndo.append(
                        WindowUndoEntry(
                            identity: move.identity,
                            frame: move.currentFrame,
                            assignmentSnapshot: nil
                        )
                    )
                case .constrained:
                    failedMoves += 1
                    issues.append(RestoreIssue(appName: window.appName, reason: .appConstrainedPlacement))
                case .cancelledByUser:
                    userAdjusted += 1
                case .superseded, .notSaved:
                    skipped += 1
                    issues.append(RestoreIssue(appName: window.appName, reason: .superseded))
                }
                pendingPlacements -= 1
                guard pendingPlacements == 0, !didFinish else { return }
                didFinish = true
                self.finishRestore(
                    trigger: trigger,
                    profile: profile,
                    moved: verifiedMoves,
                    unchanged: unchanged,
                    skipped: skipped,
                    failed: failedMoves,
                    unmatched: unmatched,
                    issues: issues,
                    userAdjusted: userAdjusted,
                    undoEntries: nextUndo,
                    displayGeneration: displayGeneration
                )
            }
        }
        if pendingPlacements == 0 && !didFinish {
            didFinish = true
            finishRestore(
                trigger: trigger,
                profile: profile,
                moved: verifiedMoves,
                unchanged: unchanged,
                skipped: skipped,
                failed: failedMoves,
                unmatched: unmatched,
                issues: issues,
                userAdjusted: userAdjusted,
                undoEntries: nextUndo,
                displayGeneration: displayGeneration
            )
        }
    }

    private func finishRestore(
        trigger: RestoreTrigger,
        profile: DisplayProfile,
        moved: Int,
        unchanged: Int,
        skipped: Int,
        failed: Int,
        unmatched: Int,
        issues: [RestoreIssue],
        userAdjusted: Int,
        undoEntries nextUndo: [WindowUndoEntry],
        displayGeneration: UUID? = nil
    ) {
        if !nextUndo.isEmpty {
            registerUndo(WindowUndoTransaction(name: trigger.actionTitle, entries: nextUndo))
        }
        let summary = RestoreRunSummary(
            moved: moved,
            unchanged: unchanged,
            skipped: skipped,
            failed: failed,
            userAdjusted: userAdjusted
        )
        store.appendRestoreRecord(
            RestoreRecord(
                trigger: trigger.logLabel,
                profileName: profile.name,
                moved: moved,
                unchanged: unchanged,
                skipped: skipped,
                failed: failed,
                unmatched: unmatched,
                issues: issues
            )
        )
        Self.logger.info("Restore completed for \(trigger.logLabel): \(moved) verified, \(unchanged) unchanged, \(skipped) skipped, \(failed) failed, \(userAdjusted) user-adjusted")
        if let content = RestoreToastPolicy().content(
            for: trigger,
            profileName: profile.name,
            summary: summary
        ) {
            hud.show(content, onAction: content.actionTitle == nil ? nil : { [weak self] in
                self?.undoLastAction()
            })
        }
        finishDisplayTransition(generation: displayGeneration)
        if trigger == .systemResume {
            if !sessionDisplayChangePending {
                lastKnownSessionDisplayExpectation = sessionDisplayReadiness.readyDestination
                lastKnownSessionRestoreTargets = sessionRestoreTargets
            }
            finishSessionRecovery()
        }
    }

    private func finishDisplayTransition(generation: UUID?) {
        guard let generation else { return }
        workspaceState.finishDisplayTransition(generation: generation)
        if !reflowZones.isEmpty { scheduleReflowWork() }
    }

    private func finishSessionRecovery() {
        sessionDisplayWorkItem?.cancel()
        sessionDisplayWorkItem = nil
        sessionDisplayReadiness.finish()
        let changedDuringRestore = sessionDisplayChangePending
        sessionDisplayChangePending = false
        if changedDuringRestore { _ = workspaceState.beginDisplayTransition() }
        workspaceState.finishSessionRecovery()
        sessionRestoreTargets.removeAll()
        if changedDuringRestore { scheduleRestore(trigger: .displayChange) }
        else if !reflowZones.isEmpty { scheduleReflowWork() }
        Self.logger.info("Session recovery finished")
    }
}
