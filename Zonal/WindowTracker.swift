import AppKit
import ApplicationServices
import Darwin
import OSLog

struct WindowTrackingJournalEntry: Equatable {
    var sequence: UInt64
    var date: Date
    var event: String
    var processIdentifier: Int32?
    var bundleIdentifier: String?
    var windowID: LiveWindowID?
    var idResolutionSource: WindowIDResolutionSource?
    var spaceEpoch: UInt64
    var observerGeneration: UInt64
    var detail: String?
}

struct WindowTrackingJournal {
    var capacity = 200
    private(set) var entries: [WindowTrackingJournalEntry] = []
    private var sequence: UInt64 = 0

    mutating func append(
        event: String,
        processIdentifier: Int32? = nil,
        bundleIdentifier: String? = nil,
        windowID: LiveWindowID? = nil,
        idResolutionSource: WindowIDResolutionSource? = nil,
        spaceEpoch: UInt64,
        observerGeneration: UInt64,
        detail: String? = nil,
        date: Date = Date()
    ) {
        sequence &+= 1
        entries.append(WindowTrackingJournalEntry(
            sequence: sequence,
            date: date,
            event: event,
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            idResolutionSource: idResolutionSource,
            spaceEpoch: spaceEpoch,
            observerGeneration: observerGeneration,
            detail: detail
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

struct AXObserverHealth {
    var callbacks: UInt64 = 0
    var focusWindows: UInt64 = 0
    var focusAbsences: UInt64 = 0
    var incompleteFocusReads: UInt64 = 0
    var registrationRequests: UInt64 = 0
    var completedRegistrations: UInt64 = 0
    var registrationFailures: UInt64 = 0
    var lastCallbackAt: Date?
    var lastRegistrationError: Int32?
}

@MainActor
final class WindowTracker {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowTracker")
    nonisolated static let focusBoundaryTimeout: Float = 0.05

    private let registry: WindowRegistry
    private var windowsByID: [LiveWindowID: ManagedWindow] = [:]
    private var observersByPID: [pid_t: AXObserver] = [:]
    private var observerRegistrationQueues: [pid_t: DispatchQueue] = [:]
    private var observedWindowElementsByPID: [pid_t: [AXUIElement]] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var reconciliationTimer: Timer?
    private var pendingSessionResume: DispatchWorkItem?
    var isReconciliationTimerActive: Bool { reconciliationTimer != nil }
    private var rescanGeneration: UUID?
    private var pendingDisplayChangeGeneration: UUID?
    private var pendingRescanCompletions: [(Int) -> Void] = []
    private var reconciliationGeneration: UUID?
    private var pendingReconciliationReset = false
    private var pendingReconciliationCompletions: [() -> Void] = []
    private var needsFollowUpReconciliation = false
    private let rescanPolicy = WindowRescanPolicy()
    private let eventRefreshPolicy = WindowEventRefreshPolicy()
    private var pendingEventRefresh: DispatchWorkItem?
    private var focusRecoveryWork: DispatchWorkItem?
    private var focusRecoveryGeneration: UUID?
    private let focusedWindowProvider: () -> ManagedWindow?
    private let usesInjectedFocusProvider: Bool
    private let frontmostProcessIdentifier: () -> pid_t?
    private(set) var observerHealthByPID: [pid_t: AXObserverHealth] = [:]
    private var lastReconciliationUptime: TimeInterval?
    private var reconciliationCount: UInt64 = 0
    private var eventRefreshRequestCount: UInt64 = 0
    private var eventRefreshPerformedCount: UInt64 = 0
    private var eventRefreshCoalescedCount: UInt64 = 0
    private var incrementalEventCount: UInt64 = 0
    private var incrementalFallbackCount: UInt64 = 0
    private var lastReconciliationDuration: TimeInterval = 0
    private var maximumReconciliationDuration: TimeInterval = 0
    private var currentSpaceEpoch: UInt64 = 1
    private let spaceEpochPolicy = SpaceEpochPolicy()
    private var retainedWindowIDs = Set<LiveWindowID>()
    private var completeAbsenceCountByWindowID: [LiveWindowID: Int] = [:]
    private let absencePolicy = WindowAbsencePolicy()
    private var focusSequencer = FocusEventSequencer()
    private var journal = WindowTrackingJournal()
    private var observerGeneration: UInt64 = 1
    private var focusNotificationGeneration = UUID()
    private var outlineFocusReadGeneration: UUID?
    private var outlineExcludedElement: AXUIElement?
    private var isSessionInactive = false
    private var recoveryGraceUntil: Date?
    private(set) var lastReconciliationAt: Date?
    private(set) var lastAXEventAt: Date?
    private(set) var lastAXEventName: String?
    private(set) var lastRetainedWindowCount = 0
    private var hasConfirmedFocusAbsence = false
    private(set) var focusedWindowID: LiveWindowID?
    private(set) var isRunning = false

    var onFocusChanged: ((ManagedWindow?) -> Void)?
    var onWindowsChanged: (([ManagedWindow]) -> Void)?
    var onSessionActivityChanged: ((Bool) -> Void)?
    var onWindowDiscovered: ((ManagedWindow) -> Void)?
    var onWindowFrameChanged: ((ManagedWindow) -> Void)?
    var onWindowObserverReady: ((ManagedWindow) -> Void)?
    var onDisplayInventorySettled: (() -> Void)?
    var onActiveSpaceChanged: (() -> Void)?

    init(registry: WindowRegistry, focusedWindowProvider: (() -> ManagedWindow?)? = nil,
         frontmostProcessIdentifier: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.registry = registry
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.focusedWindowProvider = focusedWindowProvider ?? { registry.focusedWindow() }
        self.usesInjectedFocusProvider = focusedWindowProvider != nil
    }

    var windows: [ManagedWindow] {
        windowsByID.values.sorted { $0.id.sortKey < $1.id.sortKey }
    }

    var currentSpaceWindows: [ManagedWindow] {
        windows.filter { window in
            spaceEpochPolicy.isIncluded(
                windowEpoch: window.spaceEpoch,
                isOnCurrentSpace: window.isOnCurrentSpace,
                isMinimized: window.isMinimized,
                currentEpoch: currentSpaceEpoch
            )
        }
    }

    var focusedWindow: ManagedWindow? {
        if let focusedWindowID, let cached = windowsByID[focusedWindowID] {
            return cached
        }
        return focusRecoveryGeneration == nil && !hasConfirmedFocusAbsence ? focusedWindowProvider() : nil
    }

    func detailedDiagnosticLines() -> [String] {
        let scan = registry.lastScanDiagnostics
        let perBundle = Dictionary(grouping: windows, by: {
            $0.identity.bundleIdentifier
        })
        let bundleSummary = perBundle.keys.sorted().map {
            "\($0)=\(perBundle[$0]?.count ?? 0)"
        }.joined(separator: ", ")
        let failedApplications = scan.failedApplicationBundleIdentifiers.sorted()
            .joined(separator: ", ")
        let recentEvents = journal.entries.suffix(30).map { entry in
            let app = entry.bundleIdentifier ?? "none"
            let source = entry.idResolutionSource?.rawValue ?? "none"
            let detail = entry.detail.map { " detail=\($0)" } ?? ""
            return "tracking.event seq=\(entry.sequence) type=\(entry.event) pid=\(entry.processIdentifier ?? 0) app=\(app) idSource=\(source) spaceEpoch=\(entry.spaceEpoch) observerGeneration=\(entry.observerGeneration)\(detail)"
        }
        let observerHealth = observerHealthByPID.keys.sorted().map { pid in
            let health = observerHealthByPID[pid]!
            return "AX observer pid=\(pid) attached=\(observersByPID[pid] != nil) callbacks=\(health.callbacks) focusWindows=\(health.focusWindows) focusAbsences=\(health.focusAbsences) incompleteFocus=\(health.incompleteFocusReads) registrationRequests=\(health.registrationRequests) completed=\(health.completedRegistrations) failedNotifications=\(health.registrationFailures) lastError=\(health.lastRegistrationError.map(String.init) ?? "none") lastCallback=\(health.lastCallbackAt?.formatted(.iso8601) ?? "never")"
        }
        return [
            "Last reconciliation: \(lastReconciliationAt?.formatted(.iso8601) ?? "never")",
            "Last AX event: \(lastAXEventName ?? "none") at \(lastAXEventAt?.formatted(.iso8601) ?? "never")",
            "Outline AX focus sources: \(registry.outlineFocusComparison)",
            "Outline AX latest read: \(registry.outlineFocusLastRead)",
            "Outline AX latest enrichment: \(registry.outlineFocusEnrichment)",
            "Tracker windows: \(windows.count) total / \(currentSpaceWindows.count) current Space / \(lastRetainedWindowCount) retained / \(windows.filter(\.isProvisional).count) provisional",
            "Tracking epochs: Space=\(currentSpaceEpoch) observer=\(observerGeneration) focusEvents=\(focusSequencer.sequence)",
            "Reconciliations: total=\(reconciliationCount) eventRequests=\(eventRefreshRequestCount) performed=\(eventRefreshPerformedCount) coalesced=\(eventRefreshCoalescedCount) lastMs=\(Int(lastReconciliationDuration * 1_000)) maxMs=\(Int(maximumReconciliationDuration * 1_000))",
            "Incremental AX updates: applied=\(incrementalEventCount) fallbackScans=\(incrementalFallbackCount)",
            "Session recovery: inactive=\(isSessionInactive) graceUntil=\(recoveryGraceUntil?.formatted(.iso8601) ?? "none")",
            "AX metadata timeout: 0.2 seconds; focus boundary timeout: 0.05 seconds; inventory deadline: 0.8 seconds",
            "AX observers: \(observersByPID.count) apps / \(observedWindowElementsByPID.values.reduce(0) { $0 + $1.count }) windows",
            "Last scan: apps=\(scan.enumeratedApplicationCount)/\(scan.regularApplicationCount) AX=\(scan.enumeratedAXWindowCount) eligible=\(scan.eligibleAXWindowCount) current=\(scan.currentSpaceWindowCount) minimized=\(scan.minimizedWindowCount) historyRetained=\(scan.historyRetainedWindowCount) unresolvedSpace=\(scan.unresolvedSpaceWindowCount)",
            "Native on-screen windows: \(scan.onScreenNativeWindowCount); AX rejections: \(scan.rejectionSummary.isEmpty ? "none" : scan.rejectionSummary)",
            "Last all-rejected scan: \(registry.lastAllRejectedScan.map { "\($0.date.formatted(.iso8601)) native=\($0.onScreenNativeWindowCount) AX=\($0.enumeratedAXWindowCount) reasons=\($0.rejectionSummary)" } ?? "none")",
            "Window ID resolution: direct=\(scan.directIDCount) heuristic=\(scan.heuristicIDCount) sessionOnly=\(scan.sessionOnlyIDCount)",
            "AX enumeration failures: \(failedApplications.isEmpty ? "none" : failedApplications)",
            "Managed windows by bundle: \(bundleSummary.isEmpty ? "none" : bundleSummary)",
            "Recent tracking events:"
        ] + observerHealth + (recentEvents.isEmpty ? ["none"] : recentEvents)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        installWorkspaceObservers()
        installApplicationObservers(for: [])
        rescan(reason: "startup")
        startReconciliationTimer()
    }

    private func startReconciliationTimer() {
        guard isRunning, !isSessionInactive, reconciliationTimer == nil else { return }
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: eventRefreshPolicy.recoveryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSessionInactive else { return }
                self.reconcile()
            }
        }
        reconciliationTimer?.tolerance = 1
    }

    func setSessionInactive(_ inactive: Bool) {
        guard isSessionInactive != inactive else { return }
        isSessionInactive = inactive
        pendingSessionResume?.cancel()
        pendingSessionResume = nil
        if inactive {
            reconciliationTimer?.invalidate()
            reconciliationTimer = nil
            onSessionActivityChanged?(false)
        } else {
            recoveryGraceUntil = Date().addingTimeInterval(15)
            // Wake, display wake and session activation often describe the same transition.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning, !self.isSessionInactive else { return }
                self.pendingSessionResume = nil
                self.rebuildApplicationObservers()
                self.rescan(reason: "session-resume")
                self.startReconciliationTimer()
                self.onSessionActivityChanged?(true)
            }
            pendingSessionResume = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observerGeneration &+= 1
        focusNotificationGeneration = UUID()
        outlineFocusReadGeneration = nil
        outlineExcludedElement = nil
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0)
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        pendingSessionResume?.cancel()
        pendingSessionResume = nil
        pendingEventRefresh?.cancel()
        pendingEventRefresh = nil
        focusRecoveryWork?.cancel()
        focusRecoveryWork = nil
        focusRecoveryGeneration = nil
        rescanGeneration = nil
        pendingDisplayChangeGeneration = nil
        onWindowObserverReady = nil
        reconciliationGeneration = nil
        pendingReconciliationCompletions.removeAll()
        needsFollowUpReconciliation = false
        pendingReconciliationReset = false
        pendingRescanCompletions.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        for observer in applicationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        applicationObservers.removeAll()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        for observer in observersByPID.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observersByPID.removeAll()
        observedWindowElementsByPID.removeAll()
        windowsByID.removeAll()
        retainedWindowIDs.removeAll()
        completeAbsenceCountByWindowID.removeAll()
    }

    @discardableResult
    func rescan(
        resetSpaceMembership: Bool = false,
        reason: String = "manual",
        completion: ((Int) -> Void)? = nil
    ) -> Int {
        guard isRunning else {
            completion?(0)
            return 0
        }
        if let completion {
            pendingRescanCompletions.append(completion)
        }

        let generation = UUID()
        rescanGeneration = generation
        journal.append(
            event: "refresh.started",
            spaceEpoch: currentSpaceEpoch,
            observerGeneration: observerGeneration,
            detail: reason
        )
        reconcile(resetSpaceMembership: resetSpaceMembership)
        let initialCount = windows.count
        Self.logger.info("Window rescan started initialCount=\(initialCount)")

        for (index, delay) in rescanPolicy.followUpDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isRunning,
                      self.rescanGeneration == generation else { return }
                self.reconcile { [weak self] in
                guard let self, self.rescanGeneration == generation else { return }
                if index == self.rescanPolicy.followUpDelays.count - 1 {
                    self.rescanGeneration = nil
                    let finalCount = self.windows.count
                    self.journal.append(
                        event: "refresh.completed",
                        spaceEpoch: self.currentSpaceEpoch,
                        observerGeneration: self.observerGeneration,
                        detail: "reason=\(reason),windows=\(finalCount)"
                    )
                    Self.logger.info("Window rescan finished finalCount=\(finalCount)")
                    self.finishRescan(finalCount: finalCount)
                }
                }
            }
        }

        if rescanPolicy.followUpDelays.isEmpty {
            reconcile { [weak self] in
                guard let self, self.rescanGeneration == generation else { return }
                self.rescanGeneration = nil
                self.finishRescan(finalCount: self.windows.count)
            }
        }
        return initialCount
    }

    private func finishRescan(finalCount: Int) {
        let completions = pendingRescanCompletions
        pendingRescanCompletions.removeAll()
        for completion in completions {
            completion(finalCount)
        }
    }

    private var applicationLifecycleRevision: UInt64 = 0

    func reconcile(resetSpaceMembership: Bool = false, completion: (() -> Void)? = nil) {
        if reconciliationGeneration != nil {
            needsFollowUpReconciliation = true
            pendingReconciliationReset = pendingReconciliationReset || resetSpaceMembership
            if let completion { pendingReconciliationCompletions.append(completion) }
            return
        }
        let generation = UUID()
        reconciliationGeneration = generation
        let reconciliationStartedAt = ProcessInfo.processInfo.systemUptime
        if resetSpaceMembership {
            currentSpaceEpoch &+= 1
            journal.append(event: "space.changed", spaceEpoch: currentSpaceEpoch,
                           observerGeneration: observerGeneration)
        }
        let focusSequence = focusSequencer.sequence
        let focusGeneration = focusNotificationGeneration
        let lifecycleRevision = applicationLifecycleRevision
        let scanEpoch = currentSpaceEpoch
        let known = windows.filter { $0.spaceEpoch == scanEpoch }
        registry.manageableWindows(knownCurrentSpaceWindows: known) { [weak self] scanned, scannedFocus in
            guard let self, self.reconciliationGeneration == generation else { return }
            if self.applicationLifecycleRevision == lifecycleRevision {
                self.applyInventory(scanned, focusedElement: scannedFocus,
                                    focusSequence: focusSequence, focusGeneration: focusGeneration, scanEpoch: scanEpoch)
            } else {
                // Termination is authoritative even if an older AX scan finishes later.
                self.needsFollowUpReconciliation = true
            }
            let duration = ProcessInfo.processInfo.systemUptime - reconciliationStartedAt
            self.reconciliationCount &+= 1
            self.lastReconciliationDuration = duration
            self.maximumReconciliationDuration = max(self.maximumReconciliationDuration, duration)
            self.lastReconciliationUptime = ProcessInfo.processInfo.systemUptime
            self.reconciliationGeneration = nil
            if self.needsFollowUpReconciliation {
                let reset = self.pendingReconciliationReset
                let completions = (completion.map { [$0] } ?? []) + self.pendingReconciliationCompletions
                self.needsFollowUpReconciliation = false
                self.pendingReconciliationReset = false
                self.pendingReconciliationCompletions.removeAll()
                self.reconcile(resetSpaceMembership: reset) { completions.forEach { $0() } }
            } else { completion?() }
        }
    }

    private func applyInventory(_ scanned: [ManagedWindow], focusedElement: AXUIElement?,
                                focusSequence: UInt64, focusGeneration: UUID, scanEpoch: UInt64) {
        let previousFocusedWindowID = focusedWindowID
        let previousWindows = windows
        let previousProvisionalIDs = Set(previousWindows.filter(\.isProvisional).map(\.id))
        let previousCurrentSpaceIDs = Set(currentSpaceWindows.map(\.id))
        let previouslyRetainedWindowIDs = retainedWindowIDs
        let previousIDs = Set(windowsByID.keys)
        var nextWindowsByID: [LiveWindowID: ManagedWindow] = [:]
        for rawWindow in scanned {
            let previous = previousWindows.first {
                registry.elementsMatch($0, rawWindow)
            }
            var window = mergedInventoryWindow(rawWindow, preservingLiveIdentityFrom: previous)
            window.spaceEpoch = spaceEpochPolicy.resolvedEpoch(
                isOnCurrentSpace: window.isOnCurrentSpace,
                isMinimized: window.isMinimized,
                previousEpoch: previous?.spaceEpoch,
                currentEpoch: currentSpaceEpoch
            )
            window.isProvisional = false
            nextWindowsByID[window.id] = window
            completeAbsenceCountByWindowID[window.id] = 0
        }
        var retainedWindowCount = 0
        var nextRetainedWindowIDs = Set<LiveWindowID>()
        let runningPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))
        let failedBundles = Set(registry.lastScanDiagnostics.failedApplicationBundleIdentifiers)
        let isInRecoveryGrace = recoveryGraceUntil.map { $0 > Date() } == true
        for previous in previousWindows where nextWindowsByID[previous.id] == nil {
            guard let pid = previous.identity.processIdentifier,
                  runningPIDs.contains(pid) else {
                journalRemoval(previous, reason: "application-not-running")
                completeAbsenceCountByWindowID.removeValue(forKey: previous.id)
                continue
            }
            let scanWasCompleteForOwner = !failedBundles.contains(
                previous.identity.bundleIdentifier
            )
            if scanWasCompleteForOwner && !isSessionInactive && !isInRecoveryGrace {
                completeAbsenceCountByWindowID[previous.id, default: 0] += 1
            }
            let absenceCount = completeAbsenceCountByWindowID[previous.id] ?? 0
            if !scanWasCompleteForOwner
                || isSessionInactive
                || isInRecoveryGrace
                || !absencePolicy.shouldRemove(consecutiveCompleteAbsences: absenceCount) {
                nextWindowsByID[previous.id] = previous
                nextRetainedWindowIDs.insert(previous.id)
                retainedWindowCount += 1
                journal.append(
                    event: "window.retained",
                    processIdentifier: pid,
                    bundleIdentifier: previous.identity.bundleIdentifier,
                    windowID: previous.id,
                    idResolutionSource: previous.idResolutionSource,
                    spaceEpoch: currentSpaceEpoch,
                    observerGeneration: observerGeneration,
                    detail: scanWasCompleteForOwner
                        ? "completeAbsences=\(absenceCount)"
                        : "owner-scan-incomplete"
                )
            } else {
                journalRemoval(previous, reason: "complete-absence-\(absenceCount)")
                completeAbsenceCountByWindowID.removeValue(forKey: previous.id)
            }
        }
        retainedWindowIDs = nextRetainedWindowIDs
        windowsByID = nextWindowsByID

        // An AX focus notification received during the scan owns the newer focus.
        if focusSequencer.sequence == focusSequence, focusNotificationGeneration == focusGeneration, currentSpaceEpoch == scanEpoch,
           case .none = registry.lastScanFocusRead {
            clearConfirmedFocus(origin: "inventory-no-focus")
        }
        if focusSequencer.sequence == focusSequence, focusNotificationGeneration == focusGeneration, currentSpaceEpoch == scanEpoch,
           let focusedElement,
           var canonical = windows.first(where: { CFEqual($0.element, focusedElement) }) {
            canonical.isOnCurrentSpace = true
            canonical.spaceEpoch = currentSpaceEpoch
            focusedWindowID = canonical.id
            hasConfirmedFocusAbsence = false
            windowsByID[canonical.id] = canonical
        }
        installApplicationObservers(for: windows)
        lastReconciliationAt = Date()
        lastRetainedWindowCount = retainedWindowCount
        let scan = registry.lastScanDiagnostics
        if retainedWindowCount > 0
            || scan.unresolvedSpaceWindowCount > 0
            || !scan.failedApplicationBundleIdentifiers.isEmpty {
            Self.logger.info(
                "Reconciliation incomplete retained=\(retainedWindowCount) unresolvedSpace=\(scan.unresolvedSpaceWindowCount) failedApps=\(scan.failedApplicationBundleIdentifiers.count)"
            )
        }
        let currentIDs = Set(windowsByID.keys)
        let currentSpaceIDs = Set(currentSpaceWindows.map(\.id))
        let currentProvisionalIDs = Set(windows.filter(\.isProvisional).map(\.id))
        let presentationChanged = previousWindows.contains { previous in
            guard let current = windowsByID[previous.id] else { return false }
            return previous.isMinimized != current.isMinimized
                || previous.isFullScreen != current.isFullScreen || previous.title != current.title
        }
        if previousIDs != currentIDs
            || previousCurrentSpaceIDs != currentSpaceIDs
            || previousProvisionalIDs != currentProvisionalIDs || presentationChanged {
            onWindowsChanged?(windows)
        }
        let recoveredWindowIDs = previouslyRetainedWindowIDs
            .subtracting(nextRetainedWindowIDs)
        for window in windows
        where !previousIDs.contains(window.id) || recoveredWindowIDs.contains(window.id) {
            onWindowDiscovered?(window)
        }
        if let focusedWindow {
            if focusedWindowID != previousFocusedWindowID {
                recordFocus(focusedWindow, origin: "refresh-recovery")
            } else if previousProvisionalIDs.contains(focusedWindow.id),
                      !focusedWindow.isProvisional {
                recordFocus(focusedWindow, origin: "provisional-resolved")
            }
        }
    }

    func refreshCurrentSpace(reason: String) {
        guard isRunning else { return }
        eventRefreshRequestCount &+= 1
        if pendingEventRefresh != nil {
            eventRefreshCoalescedCount &+= 1
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = eventRefreshPolicy.delay(
            lastRefreshAt: lastReconciliationUptime,
            now: now
        )
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingEventRefresh = nil
            self.eventRefreshPerformedCount &+= 1
            self.journal.append(
                event: "refresh.started",
                spaceEpoch: self.currentSpaceEpoch,
                observerGeneration: self.observerGeneration,
                detail: "event-coalesced-\(reason)"
            )
            self.reconcile { [weak self] in
                guard let self else { return }
                self.journal.append(
                    event: "refresh.completed", spaceEpoch: self.currentSpaceEpoch,
                    observerGeneration: self.observerGeneration,
                    detail: "reason=event-coalesced-\(reason),windows=\(self.windows.count)"
                )
            }
        }
        pendingEventRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func isConfirmedOnCurrentSpace(_ window: ManagedWindow) -> Bool {
        spaceEpochPolicy.isIncluded(
            windowEpoch: window.spaceEpoch,
            isOnCurrentSpace: window.isOnCurrentSpace,
            isMinimized: window.isMinimized,
            currentEpoch: currentSpaceEpoch
        )
    }

    private func mergedInventoryWindow(
        _ scanned: ManagedWindow,
        preservingLiveIdentityFrom previous: ManagedWindow?
    ) -> ManagedWindow {
        guard let previous, previous.id != scanned.id else { return scanned }
        var merged = scanned
        merged.id = previous.id
        merged.identity.processIdentifier = previous.identity.processIdentifier
        merged.identity.cgWindowID = previous.identity.cgWindowID
        merged.identity.sessionID = previous.identity.sessionID
        merged.idResolutionSource = previous.idResolutionSource
        return merged
    }

    private func recordFocus(_ window: ManagedWindow, origin: String) {
        registry.noteFocusedWindow(window)
        focusRecoveryWork?.cancel()
        focusRecoveryWork = nil
        focusRecoveryGeneration = nil
        let record = focusSequencer.record(window.id)
        journal.append(
            event: "focus.observed",
            processIdentifier: window.identity.processIdentifier,
            bundleIdentifier: window.identity.bundleIdentifier,
            windowID: window.id,
            idResolutionSource: window.idResolutionSource,
            spaceEpoch: currentSpaceEpoch,
            observerGeneration: observerGeneration,
            detail: "focusSequence=\(record.sequence),origin=\(origin)"
        )
        onFocusChanged?(window)
    }

    private func journalRemoval(_ window: ManagedWindow, reason: String) {
        journal.append(
            event: "window.removed",
            processIdentifier: window.identity.processIdentifier,
            bundleIdentifier: window.identity.bundleIdentifier,
            windowID: window.id,
            idResolutionSource: window.idResolutionSource,
            spaceEpoch: currentSpaceEpoch,
            observerGeneration: observerGeneration,
            detail: reason
        )
    }

    func window(cgWindowID: UInt32) -> ManagedWindow? {
        windowsByID.values.first { $0.identity.cgWindowID == cgWindowID }
            ?? registry.window(cgWindowID: cgWindowID)
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.rescan(reason: "workspace-\(name.rawValue)")
                }
            })
        }
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // This callback is explicitly delivered on the main queue. Read
                // AX focus before enqueueing any refresh work so a subsequent
                // activation cannot replace the event we are trying to record.
                let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.acceptsAXFocus(processIdentifier: activatedPID) else { return }
                    let generation = UUID()
                    self.focusNotificationGeneration = generation
                    let focusRead = activatedPID.map { pid in
                        let app = AXUIElementCreateApplication(pid)
                        AXUIElementSetMessagingTimeout(app, Self.focusBoundaryTimeout)
                        return AXFocusRead.read(application: app)
                    } ?? .incomplete
                    guard self.acceptsAXFocus(processIdentifier: activatedPID, generation: generation) else { return }
                    if case .none = focusRead { self.clearConfirmedFocus(origin: "workspace-activation-no-focus") }
                    let captured = focusRead.element
                    if let captured, let cached = self.registry.focusedWindow(element: captured) {
                        self.observeFocusedWindow(cached, origin: "workspace-activation",
                                                  recordEvenIfUnchanged: true, expectedProcessIdentifier: activatedPID)
                    } else if let captured {
                        self.registry.window(element: captured, replacePending: false) { [weak self] window in
                            guard let self, self.acceptsAXFocus(processIdentifier: activatedPID, generation: generation) else { return }
                            self.observeFocusedWindow(window, origin: "workspace-activation",
                                                      recordEvenIfUnchanged: true, expectedProcessIdentifier: activatedPID)
                        }
                    }
                    self.refreshCurrentSpace(reason: "workspace-activation")
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication)?.processIdentifier
                Task { @MainActor in
                    if let pid {
                        self?.handleApplicationTerminated(processIdentifier: pid)
                    }
                    self?.reconcile()
                }
            }
        )
        workspaceObservers.append(
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.rescan(resetSpaceMembership: true, reason: "active-space-change")
                    self?.onActiveSpaceChanged?()
                }
            }
        )
        applicationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recoveryGraceUntil = Date().addingTimeInterval(15)
                    let generation = UUID()
                    self.pendingDisplayChangeGeneration = generation
                    self.rescan(reason: "display-change") { [weak self] _ in
                        guard let self, self.pendingDisplayChangeGeneration == generation else { return }
                        self.pendingDisplayChangeGeneration = nil
                        self.onDisplayInventorySettled?()
                    }
                }
            }
        )
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                _ = self?.captureFocusedWindow(origin: "mouse-up")
            }
        }
    }

    private func installApplicationObservers(for windows: [ManagedWindow]) {
        guard !registry.usesInjectedInventory else { return }
        // Observe every regular application, including apps that currently have
        // no discoverable window. Otherwise a window created after the launch
        // notification (or an initially ambiguous window) is only found by the
        // recovery timer or after the user activates the app.
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard app.activationPolicy == .regular,
                  app.processIdentifier > 0,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else {
                return nil
            }
            return app.processIdentifier
        })
        for stalePID in observersByPID.keys where !pids.contains(stalePID) {
            if let observer = observersByPID.removeValue(forKey: stalePID) {
                CFRunLoopRemoveSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .commonModes
                )
            }
            observedWindowElementsByPID.removeValue(forKey: stalePID)
        }

        for pid in pids where observersByPID[pid] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(pid, { sourceObserver, element, notification, refcon in
                guard let refcon else { return }
                let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
                let name = notification as String
                if name == (kAXFocusedWindowChangedNotification as String) {
                    AXUIElementSetMessagingTimeout(element, WindowTracker.focusBoundaryTimeout)
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)
                    // Some apps send the focused window itself rather than their AX application.
                    let read = error == .attributeUnsupported ? AXFocusRead.window(element)
                        : AXFocusRead.classify(error: error, element: value as! AXUIElement?)
                    MainActor.assumeIsolated {
                        tracker.receiveAXNotification(name: name, element: element, focusRead: read, sourceObserver: sourceObserver)
                    }
                } else {
                    MainActor.assumeIsolated { tracker.receiveAXNotification(name: name, element: element, sourceObserver: sourceObserver) }
                }
            }, &observer)
            guard result == .success, let observer else {
                observerHealthByPID[pid, default: AXObserverHealth()].lastRegistrationError = result.rawValue
                Self.logger.error("Failed to create AX observer for a process")
                journal.append(
                    event: "observer.create-failed",
                    processIdentifier: pid,
                    bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                    spaceEpoch: currentSpaceEpoch,
                    observerGeneration: observerGeneration,
                    detail: "axError=\(result.rawValue)"
                )
                continue
            }
            observersByPID[pid] = observer
            observedWindowElementsByPID[pid] = []
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
            registerNotifications(observer: observer, element: AXUIElementCreateApplication(pid), pid: pid,
                                  notifications: [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification],
                                  isApplication: true)

        }

        for window in windows {
            guard let pid = window.identity.processIdentifier,
                  let observer = observersByPID[pid],
                  observedWindowElementsByPID[pid]?.contains(where: {
                      CFEqual($0, window.element)
                  }) != true else { continue }
            observedWindowElementsByPID[pid, default: []].append(window.element)
            registerNotifications(observer: observer, element: window.element, pid: pid,
                                  notifications: [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification,
                                                  kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification],
                                  isApplication: false)

        }
        for pid in Array(observedWindowElementsByPID.keys) {
            let currentElements = windows
                .filter { $0.identity.processIdentifier == pid }
                .map(\.element)
            observedWindowElementsByPID[pid]?.removeAll { observed in
                !currentElements.contains(where: { CFEqual(observed, $0) })
            }
        }
    }

    private func registerNotifications(observer: AXObserver, element: AXUIElement, pid: pid_t,
                                       notifications: [String], isApplication: Bool) {
        let queue = observerRegistrationQueues[pid] ?? DispatchQueue(
            label: "com.sebmarste.zonal.observer-registration.\(pid)", qos: .userInitiated
        )
        observerRegistrationQueues[pid] = queue
        observerHealthByPID[pid, default: AXObserverHealth()].registrationRequests &+= 1
        let generation = observerGeneration
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        Self.registerNotificationsOffMain(queue: queue, observer: observer, element: element,
                                          notifications: notifications, refcon: refcon) { [weak self] registered, failures in
            guard let self, self.observerGeneration == generation,
                  self.observersByPID[pid].map({ CFEqual($0, observer) }) == true else { return }
            self.handleNotificationRegistrationResult(element: element, pid: pid, isApplication: isApplication,
                                                      registered: registered, failures: failures)
        }
    }

    func handleNotificationRegistrationResult(element: AXUIElement, pid: pid_t, isApplication: Bool,
                                              registered: Bool, failures: [(String, AXError)]) {
        self.observerHealthByPID[pid, default: AXObserverHealth()].completedRegistrations &+= 1
        self.observerHealthByPID[pid, default: AXObserverHealth()].registrationFailures &+= UInt64(failures.count)
        if let error = failures.last?.1 {
            self.observerHealthByPID[pid, default: AXObserverHealth()].lastRegistrationError = error.rawValue
        }
        for (name, result) in failures {
            self.journal.append(event: "observer.registration-failed", processIdentifier: pid,
                                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                spaceEpoch: self.currentSpaceEpoch, observerGeneration: self.observerGeneration,
                                detail: "notification=\(name),axError=\(result.rawValue)")
        }
        if !isApplication, registered, !failures.contains(where: { $0.1 == .invalidUIElement }),
           let window = self.windows.first(where: { CFEqual($0.element, element) }) {
            self.onWindowObserverReady?(window)
        }
        // A wake-time registration error is not a destroy event. Retry from fresh inventory; never tombstone it.
        if failures.contains(where: { $0.1 == .cannotComplete || $0.1 == .invalidUIElement }) {
            if isApplication {
                if let observer = self.observersByPID.removeValue(forKey: pid) {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                self.observedWindowElementsByPID.removeValue(forKey: pid)
            } else {
                self.observedWindowElementsByPID[pid]?.removeAll { CFEqual($0, element) }
            }
        }
    }

    nonisolated private static func registerNotificationsOffMain(
        queue: DispatchQueue, observer: AXObserver, element: AXUIElement, notifications: [String],
        refcon: UnsafeMutableRawPointer, attempt: Int = 0, previouslyRegistered: Bool = false,
        previousFailures: [(String, AXError)] = [],
        completion: @escaping @MainActor @Sendable (Bool, [(String, AXError)]) -> Void
    ) {
        queue.async(execute: DispatchWorkItem {
            AXUIElementSetMessagingTimeout(element, 0.2)
            var registered = previouslyRegistered
            var failures: [(String, AXError)] = []
            for name in notifications {
                let result = AXObserverAddNotification(observer, element, name as CFString, refcon)
                if result == .success || result == .notificationAlreadyRegistered { registered = true }
                else { failures.append((name, result)) }
            }
            let policy = AXNotificationRegistrationPolicy()
            let retry = failures.filter { policy.retryDelay(error: $0.1, attempt: attempt) != nil }
            if !retry.isEmpty, let delay = policy.retryDelay(error: .cannotComplete, attempt: attempt) {
                let permanent = previousFailures + failures.filter { policy.retryDelay(error: $0.1, attempt: attempt) == nil }
                queue.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem {
                    registerNotificationsOffMain(queue: queue, observer: observer, element: element,
                                                 notifications: retry.map(\.0), refcon: refcon,
                                                 attempt: attempt + 1, previouslyRegistered: registered,
                                                 previousFailures: permanent, completion: completion)
                })
            } else {
                let allFailures = previousFailures + failures
                DispatchQueue.main.async { completion(registered, allFailures) }
            }
        })
    }

    // Called at the observer boundary, including authoritative nil and failed focus reads.
    func receiveAXNotification(name: String, element: AXUIElement, focusRead: AXFocusRead? = nil,
                               sourceObserver: AXObserver? = nil) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // Destroyed AX elements can no longer answer their PID; the retained source
        // remains authoritative for attribution and lifecycle validation.
        if let sourceObserver,
           let sourcePID = observersByPID.first(where: { CFEqual($0.value, sourceObserver) })?.key {
            pid = sourcePID
        }
        lastAXEventAt = Date()
        lastAXEventName = name
        observerHealthByPID[pid, default: AXObserverHealth()].callbacks &+= 1
        observerHealthByPID[pid, default: AXObserverHealth()].lastCallbackAt = lastAXEventAt
        if let sourceObserver {
            guard isRunning, observersByPID[pid].map({ CFEqual($0, sourceObserver) }) == true else { return }
        }
        if let focusRead {
            switch focusRead {
            case .window(let captured):
                observerHealthByPID[pid, default: AXObserverHealth()].focusWindows &+= 1
                handleAXEvent(name: name, element: captured)
            case .none:
                observerHealthByPID[pid, default: AXObserverHealth()].focusAbsences &+= 1
                observeFocusRead(focusRead, origin: "ax-notification-no-focus", processIdentifier: pid)
            case .incomplete:
                observerHealthByPID[pid, default: AXObserverHealth()].incompleteFocusReads &+= 1
            }
        } else {
            handleAXEvent(name: name, element: element)
        }
    }

    func acceptsAXFocus(processIdentifier: pid_t?, generation: UUID? = nil) -> Bool {
        guard let processIdentifier, processIdentifier == frontmostProcessIdentifier() else { return false }
        return generation == nil || generation == focusNotificationGeneration
    }

    // Reject background notifications before invalidating a pending foreground request.
    func beginAXFocus(processIdentifier: pid_t?) -> UUID? {
        guard acceptsAXFocus(processIdentifier: processIdentifier) else { return nil }
        let generation = UUID()
        focusNotificationGeneration = generation
        outlineExcludedElement = nil
        return generation
    }

    private func handleAXEvent(name: String, element: AXUIElement) {
        let eventObserverGeneration = observerGeneration
        if name == (kAXFocusedWindowChangedNotification as String) {
            var capturedPID: pid_t = 0
            AXUIElementGetPid(element, &capturedPID)
            guard let generation = beginAXFocus(processIdentifier: capturedPID) else { return }
            if let provisional = registry.focusedWindow(element: element)
                ?? registry.provisionalFocusedWindow(element: element) {
                let previousIDs = Set(windowsByID.keys)
                var canonical = windows.first {
                    registry.elementsMatch($0, provisional)
                } ?? provisional
                canonical.isOnCurrentSpace = true
                canonical.spaceEpoch = currentSpaceEpoch
                windowsByID[canonical.id] = canonical
                focusedWindowID = canonical.id
                hasConfirmedFocusAbsence = false
                installApplicationObservers(for: windows)
                if previousIDs != Set(windowsByID.keys) {
                    onWindowsChanged?(windows)
                }
                recordFocus(canonical, origin: "ax-notification")
                incrementalEventCount &+= 1
            } else {
                incrementalFallbackCount &+= 1
                registry.window(element: element, replacePending: false) { [weak self] window in
                    guard let self, self.isRunning, self.observerGeneration == eventObserverGeneration,
                          self.acceptsAXFocus(processIdentifier: capturedPID, generation: generation) else { return }
                    if let window, window.identity.processIdentifier == capturedPID {
                        self.upsertIncrementalWindow(window, event: name, confirmsCurrentSpace: true)
                        self.observeFocusedWindow(window, origin: "ax-notification",
                                                  recordEvenIfUnchanged: true, expectedProcessIdentifier: capturedPID)
                    }
                    self.refreshCurrentSpace(reason: "unknown-focus-element")
                }
            }
        } else if name == (kAXMovedNotification as String)
            || name == (kAXResizedNotification as String) {
            if let window = windows.first(where: { CFEqual($0.element, element) }) {
                onWindowFrameChanged?(window)
            }
        } else if name == (kAXUIElementDestroyedNotification as String) {
            handleWindowDestroyed(element: element)
            incrementalEventCount &+= 1
        } else if name == (kAXWindowCreatedNotification as String) {
            registry.window(element: element) { [weak self] window in
                guard let self, self.isRunning, self.observerGeneration == eventObserverGeneration else { return }
                if let window, self.registry.isOnScreen(window) {
                    self.upsertIncrementalWindow(window, event: name, confirmsCurrentSpace: true)
                } else {
                    self.incrementalFallbackCount &+= 1
                    self.refreshCurrentSpace(reason: "ax-\(name)")
                }
            }
        } else if name == (kAXWindowMiniaturizedNotification as String)
            || name == (kAXWindowDeminiaturizedNotification as String)
            || name == (kAXTitleChangedNotification as String) {
            // The worker snapshot is authoritative for rapid minimize/title sequences.
            registry.window(element: element) { [weak self] window in
                guard let self, self.isRunning, self.observerGeneration == eventObserverGeneration else { return }
                if var updated = window,
                   let existing = self.windows.first(where: { CFEqual($0.element, element) }) {
                    updated.isOnCurrentSpace = existing.isOnCurrentSpace
                    updated.spaceEpoch = existing.spaceEpoch
                    self.upsertIncrementalWindow(updated, event: name)
                } else {
                    self.incrementalFallbackCount &+= 1
                    self.refreshCurrentSpace(reason: "ax-\(name)")
                }
            }
        }
    }

    private func upsertIncrementalWindow(_ rawWindow: ManagedWindow, event: String, confirmsCurrentSpace: Bool = false) {
        let previousIDs = Set(windowsByID.keys)
        let previous = windows.first { registry.elementsMatch($0, rawWindow) }
        var window = mergedInventoryWindow(rawWindow, preservingLiveIdentityFrom: previous)
        if confirmsCurrentSpace {
            window.isOnCurrentSpace = true
            window.spaceEpoch = currentSpaceEpoch
        }
        window.isProvisional = false
        windowsByID[window.id] = window
        completeAbsenceCountByWindowID[window.id] = 0
        installApplicationObservers(for: windows)
        incrementalEventCount &+= 1
        journal.append(
            event: "window.incremental",
            processIdentifier: window.identity.processIdentifier,
            bundleIdentifier: window.identity.bundleIdentifier,
            windowID: window.id,
            idResolutionSource: window.idResolutionSource,
            spaceEpoch: currentSpaceEpoch,
            observerGeneration: observerGeneration,
            detail: event
        )
        if !previousIDs.contains(window.id) {
            onWindowDiscovered?(window)
        }
        onWindowsChanged?(windows)
    }

    /// Bounded recovery for missed AX focus notifications, even within one app.
    func refreshOutlineFocus(completion: @escaping (ManagedWindow?) -> Void = { _ in }) {
        guard isRunning, outlineFocusReadGeneration == nil else { return }
        let request = UUID()
        outlineFocusReadGeneration = request
        let notificationGeneration = focusNotificationGeneration
        let sequence = focusSequencer.sequence
        let requestedPID = frontmostProcessIdentifier()
        let observer = observerGeneration
        func accepts(_ tracker: WindowTracker) -> Bool {
            tracker.isRunning && tracker.observerGeneration == observer
                && tracker.outlineFocusReadGeneration == request
                && tracker.focusNotificationGeneration == notificationGeneration
                && tracker.focusSequencer.sequence == sequence
                && tracker.frontmostProcessIdentifier() == requestedPID
        }
        registry.focusedElementRead(processIdentifier: requestedPID) { [weak self] read in
            guard let self else { return }
            guard accepts(self) else {
                if self.outlineFocusReadGeneration == request { self.outlineFocusReadGeneration = nil }
                return
            }
            switch read {
            case .none:
                self.outlineFocusReadGeneration = nil
                self.outlineExcludedElement = nil
                self.clearConfirmedFocus(origin: "outline-recovery")
                completion(nil)
            case .incomplete:
                self.outlineFocusReadGeneration = nil
            case .window(let element):
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                guard pid == requestedPID else { self.outlineFocusReadGeneration = nil; return }
                if let window = self.registry.focusedWindow(element: element) {
                    self.outlineFocusReadGeneration = nil
                    self.outlineExcludedElement = nil
                    if let projected = self.observeFocusedWindow(window, origin: "outline-recovery", recordEvenIfUnchanged: false,
                                                                  expectedProcessIdentifier: requestedPID) { completion(projected) }
                } else if self.outlineExcludedElement.map({ CFEqual($0, element) }) == true {
                    self.outlineFocusReadGeneration = nil
                    self.clearConfirmedFocus(origin: "outline-recovery")
                    completion(nil)
                } else {
                    self.registry.focusedWindowRead(element: element) { [weak self] window, enriched in
                        guard let self else { return }
                        let accepted = accepts(self)
                        if self.outlineFocusReadGeneration == request { self.outlineFocusReadGeneration = nil }
                        guard accepted else { return }
                        if case .none = enriched {
                            self.outlineExcludedElement = element
                            self.clearConfirmedFocus(origin: "outline-recovery")
                            completion(nil)
                        } else if let window {
                            let previouslyKnown = self.windowsByID[window.id] != nil
                            self.outlineExcludedElement = nil
                            guard let projected = self.observeFocusedWindow(window, origin: "outline-recovery", recordEvenIfUnchanged: false,
                                                                            expectedProcessIdentifier: requestedPID) else { return }
                            self.installApplicationObservers(for: self.windows)
                            if !previouslyKnown { self.onWindowsChanged?(self.windows) }
                            completion(projected)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    func captureFocusedWindow(
        origin: String,
        recordEvenIfUnchanged: Bool = false,
        expectedProcessIdentifier: pid_t? = nil
    ) -> ManagedWindow? {
        if !usesInjectedFocusProvider {
            let sequence = focusSequencer.sequence
            let generation = focusNotificationGeneration
            let requestedPID = frontmostProcessIdentifier()
            registry.focusedWindowRead { [weak self] observed, read in
                guard let self, self.focusSequencer.sequence == sequence,
                      self.focusNotificationGeneration == generation,
                      self.frontmostProcessIdentifier() == requestedPID else { return }
                if case .none = read { self.clearConfirmedFocus(origin: origin) }
                self.observeFocusedWindow(observed, origin: origin,
                                          recordEvenIfUnchanged: recordEvenIfUnchanged,
                                          expectedProcessIdentifier: expectedProcessIdentifier)
            }
            return focusedWindow
        }
        return observeFocusedWindow(
            focusedWindowProvider(),
            origin: origin,
            recordEvenIfUnchanged: recordEvenIfUnchanged,
            expectedProcessIdentifier: expectedProcessIdentifier
        )
    }

    func observeFocusRead(_ read: AXFocusRead, origin: String, processIdentifier: pid_t? = nil) {
        switch read {
        case .none:
            if let processIdentifier,
               focusedWindow?.identity.processIdentifier != processIdentifier,
               frontmostProcessIdentifier() != processIdentifier { return }
            clearConfirmedFocus(origin: origin)
        case .window(let element):
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard acceptsAXFocus(processIdentifier: pid) else { return }
            if let window = registry.focusedWindow(element: element) {
                observeFocusedWindow(window, origin: origin, recordEvenIfUnchanged: true,
                                     expectedProcessIdentifier: nil)
            }
        case .incomplete:
            break
        }
    }

    private func clearConfirmedFocus(origin: String) {
        focusRecoveryWork?.cancel()
        focusRecoveryWork = nil
        focusRecoveryGeneration = nil
        // A watchdog's repeated authoritative absence must not continuously
        // invalidate unrelated inventory or a pending enrichment request.
        guard focusedWindowID != nil || !hasConfirmedFocusAbsence else { return }
        focusedWindowID = nil
        hasConfirmedFocusAbsence = true
        registry.clearFocusedWindow()
        focusNotificationGeneration = UUID()
        journal.append(event: "focus.cleared", spaceEpoch: currentSpaceEpoch,
                       observerGeneration: observerGeneration, detail: origin)
        onFocusChanged?(nil)
    }

    @discardableResult
    private func observeFocusedWindow(
        _ observed: ManagedWindow?,
        origin: String,
        recordEvenIfUnchanged: Bool,
        expectedProcessIdentifier: pid_t?
    ) -> ManagedWindow? {
        guard let observed else { return nil }
        let policy = FocusObservationPolicy()
        guard policy.accepts(
            observedProcessIdentifier: observed.identity.processIdentifier,
            expectedProcessIdentifier: expectedProcessIdentifier
        ) else {
            return nil
        }
        let previousFocusedWindowID = focusedWindowID
        var canonical = windows.first {
            registry.elementsMatch($0, observed)
        } ?? observed
        canonical.isOnCurrentSpace = true
        canonical.spaceEpoch = currentSpaceEpoch
        windowsByID[canonical.id] = canonical
        focusedWindowID = canonical.id
        hasConfirmedFocusAbsence = false
        if policy.shouldRecord(
            previousWindowID: previousFocusedWindowID,
            observedWindowID: canonical.id,
            recordEvenIfUnchanged: recordEvenIfUnchanged
        ) {
            recordFocus(canonical, origin: origin)
        }
        return canonical
    }

    private func removeWindow(element: AXUIElement) {
        registry.forgetWindow(element: element)
        focusNotificationGeneration = UUID()
        let removedIDs = windowsByID.values
            .filter { CFEqual($0.element, element) }
            .map(\.id)
        for id in removedIDs {
            if let window = windowsByID[id] {
                journalRemoval(window, reason: "ax-destroyed")
            }
            windowsByID.removeValue(forKey: id)
            retainedWindowIDs.remove(id)
            completeAbsenceCountByWindowID.removeValue(forKey: id)
        }
        for pid in Array(observedWindowElementsByPID.keys) {
            observedWindowElementsByPID[pid]?.removeAll { CFEqual($0, element) }
        }
        if let focusedWindowID, removedIDs.contains(focusedWindowID) {
            self.focusedWindowID = nil
        }
    }

    func handleWindowDestroyed(element: AXUIElement) {
        let lostFocus = focusedWindowID.flatMap { windowsByID[$0] }
            .map { CFEqual($0.element, element) } ?? false
        removeWindow(element: element)
        if lostFocus {
            focusRecoveryWork?.cancel()
            let generation = UUID()
            focusRecoveryGeneration = generation
            onFocusChanged?(nil)
            recoverFocusAfterClose(excluding: element, generation: generation, attempt: 0)
        }
        onWindowsChanged?(windows)
    }

    private func recoverFocusAfterClose(excluding closed: AXUIElement, generation: UUID, attempt: Int) {
        // Some apps deliver destroy before publishing their replacement AX focus.
        let delays: [TimeInterval] = [0, 0.05, 0.1, 0.2]
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.focusRecoveryGeneration == generation else { return }
            let handle: (ManagedWindow?) -> Void = { [weak self] observed in
                guard let self, self.focusRecoveryGeneration == generation else { return }
                if let observed, !CFEqual(observed.element, closed) {
                    self.observeFocusedWindow(observed, origin: "window-close", recordEvenIfUnchanged: false,
                                              expectedProcessIdentifier: nil)
                } else if attempt + 1 < delays.count {
                    self.recoverFocusAfterClose(excluding: closed, generation: generation, attempt: attempt + 1)
                } else {
                    self.focusRecoveryGeneration = nil
                    self.focusRecoveryWork = nil
                }
            }
            if self.usesInjectedFocusProvider { handle(self.focusedWindowProvider()) }
            else { self.registry.focusedWindow(completion: handle) }

        }
        focusRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt], execute: work)
    }

    func handleApplicationTerminated(processIdentifier: pid_t) {
        applicationLifecycleRevision &+= 1
        focusNotificationGeneration = UUID()
        let lostFocus = focusedWindow?.identity.processIdentifier == processIdentifier

        let removedIDs = windowsByID.values
            .filter { $0.identity.processIdentifier == processIdentifier }
            .map(\.id)
        for id in removedIDs {
            if let window = windowsByID[id] {
                registry.forgetWindow(element: window.element)
                journalRemoval(window, reason: "application-terminated")
            }
            windowsByID.removeValue(forKey: id)
            retainedWindowIDs.remove(id)
            completeAbsenceCountByWindowID.removeValue(forKey: id)
        }
        observedWindowElementsByPID.removeValue(forKey: processIdentifier)
        if let observer = observersByPID.removeValue(forKey: processIdentifier) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        if lostFocus { clearConfirmedFocus(origin: "application-terminated") }
        // Publish before the next scan: that scan already starts with the removed
        // inventory and cannot rediscover this delta for workspace/tab consumers.
        if !removedIDs.isEmpty { onWindowsChanged?(windows) }

    }

    private func rebuildApplicationObservers() {
        observerGeneration &+= 1
        journal.append(
            event: "observers.rebuilt",
            spaceEpoch: currentSpaceEpoch,
            observerGeneration: observerGeneration
        )
        for observer in observersByPID.values {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observersByPID.removeAll()
        observedWindowElementsByPID.removeAll()
    }
}
