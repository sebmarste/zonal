import AppKit
import Foundation
import OSLog

@MainActor
final class WindowMovementObserver {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowMovement")
    private static let performanceLog = OSLog(
        subsystem: "com.sebmarste.zonal",
        category: .pointsOfInterest
    )

    private struct DragOverlayLayout {
        var coordinateDisplayFrame: CGRect
        var windowFrame: CGRect
        var zones: [ZoneFrame]
    }

    private struct PendingDragUpdate {
        var location: CGPoint
        var timestamp: TimeInterval
        var shiftKeyPressed: Bool?
    }

    private let profileManager: ProfileManager
    private let layoutEngine: LayoutEngine
    private let windowRegistry: WindowRegistry
    private let windowController: WindowController
    private let workspaceState: WorkspaceStateService
    private let overlayController: HotZoneOverlayController
    private let store: PersistenceStore
    private let resolver = HotZoneResolver()

    var onPlacementFeedback: ((WindowActionSnapshot, WindowActionNotification) -> Void)?
    var onManualAction: ((ManagedWindow, ManualWindowChange, WindowActionSnapshot, ((WindowPlacementOutcome) -> Void)?) -> Void)?
    var onInteractionDiagnostic: ((WindowInteractionEvent) -> Void)?
    var onTabPointerEvent: ((CGEventType, CGPoint) -> Bool)?
    var isTabInteractionActive: (() -> Bool)?
    var onMouseDown: (() -> Void)?
    var onWindowDragChanged: ((LiveWindowID?) -> Void)?

    nonisolated(unsafe) private var mouseEventTap: CFMachPort?
    nonisolated(unsafe) private var mouseRunLoopSource: CFRunLoopSource?
    private var gesture: WindowDragGesture?
    private var gestureLookupGeneration = UUID()
    private var activeDropIntent: ZoneDropIntent = .preserve
    private var dragProfile: DisplayProfile?
    private var dragSnapshot: DisplaySnapshot?
    private var overlayLayouts: [UInt32: DragOverlayLayout] = [:]
    private var presentedOverlayDisplayID: UInt32?
    private var hasPresentedOverlay = false
    private var dragFeedbackStartedAt: TimeInterval?
    private var pendingDragUpdate: PendingDragUpdate?
    private var scheduledDragUpdate: DispatchWorkItem?
    private var lastDragUpdateAt: TimeInterval?
    private let dragStartThreshold = WindowDragGestureClassifier.defaultDragThreshold
    private let resizeThreshold: CGFloat = 6
    private let gestureClassifier = WindowDragGestureClassifier()
    private let interactionClassifier = WindowInteractionClassifier()
    private let coalescingPolicy = DragEventCoalescingPolicy()
    private var interactionJournal = WindowInteractionJournal()

    init(
        profileManager: ProfileManager,
        layoutEngine: LayoutEngine,
        windowRegistry: WindowRegistry,
        windowController: WindowController,
        workspaceState: WorkspaceStateService,
        overlayController: HotZoneOverlayController,
        store: PersistenceStore
    ) {
        self.profileManager = profileManager
        self.layoutEngine = layoutEngine
        self.windowRegistry = windowRegistry
        self.windowController = windowController
        self.workspaceState = workspaceState
        self.overlayController = overlayController
        self.store = store
    }

    func start() {
        stop()
        workspaceState.onTrackedWindowFrameChanged = { [weak self] window in
            self?.handleTrackedFrameChange(window)
        }
        installMouseEventTap()
    }

    func stop() {
        uninstallMouseEventTap()
        workspaceState.onTrackedWindowFrameChanged = nil
        reset()
    }

    func isMouseCaptureAvailable() -> Bool {
        guard let mouseEventTap else { return false }
        return CGEvent.tapIsEnabled(tap: mouseEventTap)
    }

    func detailedDiagnosticLines() -> [String] {
        ["Recent window interactions:"] + interactionJournal.diagnosticLines
    }

    private func installMouseEventTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let observer = Unmanaged<WindowMovementObserver>.fromOpaque(refcon).takeUnretainedValue()
            return observer.handleFromEventTap(type: type, event: event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        mouseEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        )
        guard let mouseEventTap else {
            Self.logger.error("Mouse event tap is unavailable")
            return
        }
        mouseRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mouseEventTap, 0)
        if let mouseRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), mouseRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: mouseEventTap, enable: true)
        Self.logger.info("gesture.tap.installed")
    }

    nonisolated func handleFromEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let location = event.location
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        let shiftKeyPressed = event.flags.contains(.maskShift)
        // Listening cannot stall another app's input. A native tab press may already
        // have begun by delivery; do not cancel that press's own focus request.
        let tabHandled = MainActor.assumeIsolated {
            if type == .leftMouseDown, isTabInteractionActive?() != true { onMouseDown?() }
            return onTabPointerEvent?(type, location) ?? false
        }
        if tabHandled { return Unmanaged.passUnretained(event) }
        Task { @MainActor in
            self.handleMouseEvent(type: type, location: location, timestamp: timestamp,
                                  shiftKeyPressed: shiftKeyPressed)
        }
        return Unmanaged.passUnretained(event)
    }

    private func uninstallMouseEventTap() {
        if let mouseEventTap {
            CGEvent.tapEnable(tap: mouseEventTap, enable: false)
        }
        if let mouseRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), mouseRunLoopSource, .commonModes)
        }
        mouseEventTap = nil
        mouseRunLoopSource = nil
    }

    private func handleMouseEvent(
        type: CGEventType,
        location: CGPoint,
        timestamp: TimeInterval,
        shiftKeyPressed: Bool
    ) {
        if type == .leftMouseDown, isTabInteractionActive?() == true { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mouseEventTap {
                CGEvent.tapEnable(tap: mouseEventTap, enable: true)
            }
            reset()
            return
        }

        switch type {
        case .leftMouseDown:
            beginGesture(
                at: location,
                timestamp: timestamp,
                shiftKeyPressed: shiftKeyPressed
            )
        case .leftMouseDragged:
            enqueueDragUpdate(
                at: location,
                timestamp: timestamp,
                shiftKeyPressed: shiftKeyPressed
            )
        case .leftMouseUp:
            cancelPendingDragUpdate()
            finishGesture(
                at: location,
                timestamp: timestamp,
                shiftKeyPressed: shiftKeyPressed
            )
        default:
            break
        }
    }

    private func beginGesture(
        at location: CGPoint,
        timestamp: TimeInterval,
        shiftKeyPressed: Bool
    ) {
        reset()
        let generation = gestureLookupGeneration
        windowRegistry.window(at: location) { [weak self] window in
            guard let self, self.gestureLookupGeneration == generation else { return }
            self.beginResolvedGesture(window, at: location, timestamp: timestamp, shiftKeyPressed: shiftKeyPressed)
        }
    }

    private func beginResolvedGesture(_ window: ManagedWindow?, at location: CGPoint, timestamp: TimeInterval, shiftKeyPressed: Bool) {
        guard let window else {
            Self.logger.info("gesture.begin.skip reason=no-window x=\(location.x) y=\(location.y)")
            return
        }
        guard !windowController.isFullScreen(window) else {
            Self.logger.info("gesture.begin.skip reason=full-screen window=\(window.id)")
            return
        }
        guard workspaceState.isManaged(window) else {
            Self.logger.info("gesture.begin.skip reason=window-left-alone window=\(window.id)")
            return
        }
        guard let frame = windowController.frame(of: window) ?? windowRegistry.cgBounds(for: window) else {
            Self.logger.info("gesture.begin.skip reason=no-frame window=\(window.id)")
            return
        }
        guard !windowController.isApplyingPlacement(to: window) else {
            Self.logger.info("gesture.begin.skip reason=placement-active window=\(window.id)")
            return
        }
        let nextGesture = WindowDragGesture(
            window: window,
            initialEventLocation: location,
            lastEventLocation: location,
            initialFrame: frame,
            lastFrame: frame,
            pointerIntent: gestureClassifier.pointerIntent(at: location, windowBounds: frame),
            beganAt: timestamp,
            isZoneDropActive: zoneDropIsActive(shiftKeyPressed: shiftKeyPressed)
        )
        gesture = nextGesture
        recordInteraction(.observing, phase: .began, window: window)
        Self.logger.info(
            "gesture.begin window=\(window.id) intent=\(String(describing: nextGesture.pointerIntent), privacy: .public) mouseX=\(location.x) mouseY=\(location.y) frameX=\(frame.minX) frameY=\(frame.minY) frameW=\(frame.width) frameH=\(frame.height)"
        )
    }

    private func updateGesture(
        at location: CGPoint,
        timestamp: TimeInterval,
        shiftKeyPressed: Bool? = nil
    ) {
        guard var gesture else { return }
        guard !windowController.isApplyingPlacement(to: gesture.window) else {
            reset()
            return
        }
        let previousClassification = gesture.classification
        gesture.lastEventLocation = location
        if let shiftKeyPressed {
            gesture.isZoneDropActive = zoneDropIsActive(shiftKeyPressed: shiftKeyPressed)
        }
        guard let frame = windowController.frame(of: gesture.window) else {
            self.gesture = gesture
            return
        }
        gesture.observe(frame: frame, timestamp: timestamp)
        gesture.classification = gestureClassifier.classify(
            current: gesture.classification,
            pointerIntent: gesture.pointerIntent,
            evidence: gesture.evidence,
            dragThreshold: dragStartThreshold,
            resizeThreshold: resizeThreshold
        )

        if previousClassification == .undecided,
           gesture.classification != .undecided {
            beginConfirmedWindowInteraction(&gesture)
            if gesture.classification == .drag {
                dragFeedbackStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }

        self.gesture = gesture
        if gesture.classification != previousClassification {
            Self.logger.info(
                "gesture.classify window=\(gesture.window.id) from=\(String(describing: previousClassification), privacy: .public) to=\(String(describing: gesture.classification), privacy: .public) position=\(gesture.evidence.maximumPositionDistance) size=\(gesture.evidence.maximumSizeDistance)"
            )
            if let kind = interactionClassifier.action(
                for: gesture.classification,
                zoneDropIsActive: gesture.isZoneDropActive,
                dropIntent: .preserve
            ) {
                recordInteraction(kind, phase: .classified, window: gesture.window)
            }
        }
        switch gesture.classification {
        case .drag:
            if gesture.isZoneDropActive {
                showOverlay(at: location)
            } else {
                activeDropIntent = .preserve
                hideDragOverlay()
            }
        case .resize:
            hideDragOverlay()
        case .undecided:
            break
        }
    }

    private func handleTrackedFrameChange(_ window: ManagedWindow) {
        guard let gesture,
              gesture.window.id == window.id else {
            return
        }
        enqueueDragUpdate(
            at: gesture.lastEventLocation,
            timestamp: ProcessInfo.processInfo.systemUptime,
            shiftKeyPressed: nil
        )
    }

    private func enqueueDragUpdate(
        at location: CGPoint,
        timestamp: TimeInterval,
        shiftKeyPressed: Bool?
    ) {
        pendingDragUpdate = PendingDragUpdate(
            location: location,
            timestamp: timestamp,
            shiftKeyPressed: shiftKeyPressed
        )
        let now = ProcessInfo.processInfo.systemUptime
        let delay = coalescingPolicy.delay(since: lastDragUpdateAt, now: now)
        guard delay > 0 else {
            processPendingDragUpdate()
            return
        }
        guard scheduledDragUpdate == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.processPendingDragUpdate()
        }
        scheduledDragUpdate = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func processPendingDragUpdate() {
        scheduledDragUpdate = nil
        guard let update = pendingDragUpdate else { return }
        pendingDragUpdate = nil
        lastDragUpdateAt = ProcessInfo.processInfo.systemUptime
        updateGesture(
            at: update.location,
            timestamp: update.timestamp,
            shiftKeyPressed: update.shiftKeyPressed
        )
    }

    private func cancelPendingDragUpdate() {
        scheduledDragUpdate?.cancel()
        scheduledDragUpdate = nil
        pendingDragUpdate = nil
    }

    private func finishGesture(
        at location: CGPoint,
        timestamp: TimeInterval,
        shiftKeyPressed: Bool
    ) {
        gestureLookupGeneration = UUID()
        guard var gesture else {
            Self.logger.info("gesture.finish.skip reason=no-gesture x=\(location.x) y=\(location.y)")
            reset()
            return
        }
        // Check before classification: claiming a gesture clears placement suppression.
        guard !windowController.isApplyingPlacement(to: gesture.window) else {
            reset()
            return
        }
        gesture.lastEventLocation = location
        gesture.isZoneDropActive = zoneDropIsActive(shiftKeyPressed: shiftKeyPressed)
        if let frame = windowController.frame(of: gesture.window) {
            gesture.observe(frame: frame, timestamp: timestamp)
        }
        gesture.classification = gestureClassifier.classify(
            current: gesture.classification,
            pointerIntent: gesture.pointerIntent,
            evidence: gesture.evidence,
            dragThreshold: dragStartThreshold,
            resizeThreshold: resizeThreshold,
            forceDecision: true
        )
        if gesture.classification != .undecided,
           !gesture.didBeginWindowInteraction {
            beginConfirmedWindowInteraction(&gesture)
        }
        self.gesture = gesture

        defer { reset() }
        Self.logger.info(
            "gesture.finish window=\(gesture.window.id) classification=\(String(describing: gesture.classification), privacy: .public) x=\(location.x) y=\(location.y)"
        )
        guard !windowController.isApplyingPlacement(to: gesture.window) else { return }

        let before = workspaceState.actionSnapshot(
            for: gesture.window,
            frame: gesture.initialFrame
        )

        guard let baseAction = interactionClassifier.action(
            for: gesture.classification,
            zoneDropIsActive: false,
            dropIntent: .preserve
        ) else { return }

        if baseAction == .resize {
            performCustomAction(for: gesture, snapshot: before, title: "Resize Saved", isResize: true)
            return
        }

        guard baseAction == .move else { return }
        guard gesture.isZoneDropActive else {
            performCustomAction(for: gesture, snapshot: before)
            return
        }
        let snapshot = profileManager.currentSnapshot()
        guard let profile = profileManager.matchedProfile(for: snapshot),
              let display = snapshot.display(containingOrNearest: location) else {
            performCustomAction(for: gesture, snapshot: before)
            return
        }
        let zones = zoneFrames(for: profile, snapshot: snapshot, display: display)
        let dropIntent = resolver.dropIntent(for: location, zones: zones)
        guard let action = interactionClassifier.action(
            for: gesture.classification,
            zoneDropIsActive: gesture.isZoneDropActive,
            dropIntent: dropIntent
        ) else { return }
        switch action {
        case .snap(let zoneID):
            guard zones.contains(where: { $0.zoneID == zoneID }) else {
                performCustomAction(for: gesture, snapshot: before)
                return
            }
            Self.logger.info(
                "gesture.drop window=\(gesture.window.id) intent=zone-fit zone=\(zoneID.rawValue, privacy: .public)"
            )
            windowController.endUserInteraction(with: gesture.window)
            onManualAction?(gesture.window, .fit(zoneID), before, { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .placed:
                    self.recordInteraction(.snap(zoneID), phase: .completed, window: gesture.window)
                    self.onPlacementFeedback?(
                        before,
                        WindowActionNotification(
                            title: "Fitted to \(ZoneNameResolver().name(for: zoneID, in: profile.zones))",
                            detail: "",
                            symbolName: "rectangle.portrait.and.arrow.forward",
                            tone: .accent,
                            actionTitle: "Undo"
                        )
                    )
                case .constrained:
                    self.recordInteraction(.snap(zoneID), phase: .failed, window: gesture.window)
                    self.onPlacementFeedback?(
                        before,
                        WindowActionNotification(
                            title: "Could Not Fit Window",
                            detail: "The app constrained the requested size or position",
                            symbolName: "exclamationmark.triangle",
                            tone: .warning,
                            actionTitle: "Undo"
                        )
                    )
                case .cancelledByUser, .superseded, .notSaved:
                    self.recordInteraction(.snap(zoneID), phase: .failed, window: gesture.window)
                    break
                }
            })
        case .customPosition(let zoneID):
            Self.logger.info(
                "gesture.drop window=\(gesture.window.id) intent=custom zone=\(zoneID.rawValue, privacy: .public)"
            )
            performCustomAction(for: gesture, snapshot: before, zoneID: zoneID, profile: profile)
        case .move:
            Self.logger.info("gesture.drop window=\(gesture.window.id) intent=preserve")
            performCustomAction(for: gesture, snapshot: before)
        case .observing, .resize:
            break
        }
    }

    private func performCustomAction(
        for gesture: WindowDragGesture, snapshot: WindowActionSnapshot,
        zoneID: ZoneID? = nil, profile: DisplayProfile? = nil,
        title: String = "Custom Position Saved", isResize: Bool = false
    ) {
        let kind: WindowInteractionKind = isResize ? .resize : zoneID.map { .customPosition($0) } ?? .move
        onManualAction?(gesture.window, .custom(zoneID, gesture.lastFrame, isResize: isResize), snapshot,
            { [weak self] outcome in
                guard let self else { return }
                self.recordInteraction(kind, phase: outcome == .placed ? .completed : .failed, window: gesture.window)
                guard outcome == .placed else { return }
                self.showCustomPositionFeedback(for: gesture, snapshot: snapshot, zoneID: zoneID,
                    profile: profile, title: title)
            })
    }

    private func zoneDropIsActive(shiftKeyPressed: Bool) -> Bool {
        store.loadConfiguration().dragZoneActivationMode.isActive(
            shiftKeyPressed: shiftKeyPressed
        )
    }

    private func showCustomPositionFeedback(
        for gesture: WindowDragGesture,
        snapshot: WindowActionSnapshot,
        zoneID: ZoneID? = nil,
        profile: DisplayProfile? = nil,
        title: String = "Custom Position Saved"
    ) {
        let resolvedZoneID = zoneID ?? workspaceState.zone(for: gesture.window)
        let resolvedProfile = profile ?? workspaceState.currentProfileContext().profile
        let zoneName = ZoneNameResolver().name(for: resolvedZoneID, in: resolvedProfile.zones)
        onPlacementFeedback?(
            snapshot,
            WindowActionNotification(
                title: zoneID != nil ? "Added to \(zoneName) · Size kept" : title,
                detail: zoneID != nil ? "" : "Window remains in \(zoneName)",
                symbolName: "rectangle.dashed",
                tone: .accent,
                actionTitle: "Undo"
            )
        )
    }

    private func showOverlay(at location: CGPoint) {
        guard prepareDragLayoutSessionIfNeeded(),
              let profile = dragProfile,
              let snapshot = dragSnapshot else {
            Self.logger.debug("Skipped drag overlay because the current display setup has no exact profile")
            hideDragOverlay()
            return
        }
        guard let display = snapshot.display(containingOrNearest: location),
              let layout = overlayLayout(
                  for: display,
                  profile: profile,
                  snapshot: snapshot
              ) else {
            Self.logger.error("Skipped drag overlay because its display could not be resolved")
            hideDragOverlay()
            return
        }
        guard !layout.zones.isEmpty else {
            Self.logger.error("Skipped drag overlay because the pointer display has no zones")
            hideDragOverlay()
            return
        }
        let nextDropIntent = resolver.dropIntent(for: location, zones: layout.zones)
        if nextDropIntent != activeDropIntent {
            Self.logger.info(
                "gesture.hover x=\(location.x) y=\(location.y) intent=\(String(describing: nextDropIntent), privacy: .public)"
            )
            if let gesture,
               let kind = interactionClassifier.action(
                for: .drag,
                zoneDropIsActive: true,
                dropIntent: nextDropIntent
            ) {
                recordInteraction(kind, phase: .preview, window: gesture.window)
            }
        }
        guard !hasPresentedOverlay
                || presentedOverlayDisplayID != display.id
                || nextDropIntent != activeDropIntent else {
            return
        }
        activeDropIntent = nextDropIntent
        overlayController.show(
            profile: profile,
            zoneFrames: layout.zones,
            coordinateDisplayFrame: layout.coordinateDisplayFrame,
            windowFrame: layout.windowFrame,
            dropIntent: activeDropIntent
        )
        presentedOverlayDisplayID = display.id
        if !hasPresentedOverlay {
            hasPresentedOverlay = true
            if let dragFeedbackStartedAt {
                Self.recordLatency("DragOverlayFirstVisible", since: dragFeedbackStartedAt)
                self.dragFeedbackStartedAt = nil
            }
        }
    }

    private func prepareDragLayoutSessionIfNeeded() -> Bool {
        if dragProfile != nil, dragSnapshot != nil { return true }
        let snapshot = profileManager.currentSnapshot()
        guard let profile = profileManager.matchedProfile(for: snapshot) else { return false }
        dragProfile = profile
        dragSnapshot = snapshot
        return true
    }

    private func hideDragOverlay() {
        overlayController.hide()
        hasPresentedOverlay = false
        presentedOverlayDisplayID = nil
    }

    private func overlayLayout(
        for display: DisplaySnapshot.Display,
        profile: DisplayProfile,
        snapshot: DisplaySnapshot
    ) -> DragOverlayLayout? {
        if let cached = overlayLayouts[display.id] { return cached }
        guard let windowFrame = appKitFrame(for: display.id) else { return nil }
        let layout = DragOverlayLayout(
            coordinateDisplayFrame: display.frame,
            windowFrame: windowFrame,
            zones: zoneFrames(for: profile, snapshot: snapshot, display: display)
        )
        overlayLayouts[display.id] = layout
        return layout
    }

    private func beginConfirmedWindowInteraction(_ gesture: inout WindowDragGesture) {
        guard !gesture.didBeginWindowInteraction else { return }
        gesture.didBeginWindowInteraction = true
        workspaceState.recordUserAdjustmentDuringRecovery(to: gesture.window)
        windowController.beginUserInteraction(with: gesture.window)
        if gesture.classification == .drag { onWindowDragChanged?(gesture.window.id) }
    }

    func placementWillBegin(for windowID: LiveWindowID) {
        // A click may focus a peek window after mouse-down but before mouse-up.
        if gesture?.window.id == windowID { reset() }
    }

    private func recordInteraction(
        _ kind: WindowInteractionKind,
        phase: WindowInteractionPhase,
        window: ManagedWindow
    ) {
        let event = interactionJournal.record(kind: kind, phase: phase, windowID: window.id)
        onInteractionDiagnostic?(event)
    }

    private func zoneFrames(
        for profile: DisplayProfile,
        snapshot: DisplaySnapshot,
        display: DisplaySnapshot.Display
    ) -> [ZoneFrame] {
        var framesByRole: [DisplayRoleID: CGRect] = [:]
        for role in profile.displayRoles {
            if let roleDisplay = profileManager.display(for: role.id, profile: profile, snapshot: snapshot) {
                framesByRole[role.id] = roleDisplay.placementFrame
            }
        }
        return layoutEngine.zoneFrames(
            for: profile,
            displayFramesByRole: framesByRole,
            fallbackDisplayFrame: snapshot.primaryDisplay?.placementFrame
        ).filter { zoneFrame in
            guard let roleID = zoneFrame.displayRoleID else {
                return display.id == snapshot.primaryDisplay?.id
            }
            return profileManager.display(for: roleID, profile: profile, snapshot: snapshot)?.id == display.id
        }
    }

    private func appKitFrame(for displayID: UInt32) -> CGRect? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return UInt32(truncating: number ?? 0) == displayID
        }?.frame
    }

    private func reset() {
        gestureLookupGeneration = UUID()
        if let gesture, gesture.didBeginWindowInteraction {
            let window = gesture.window
            windowController.endUserInteraction(with: window)
            if gesture.classification == .drag { onWindowDragChanged?(nil) }
        }
        activeDropIntent = .preserve
        gesture = nil
        dragProfile = nil
        dragSnapshot = nil
        overlayLayouts.removeAll(keepingCapacity: true)
        presentedOverlayDisplayID = nil
        hasPresentedOverlay = false
        dragFeedbackStartedAt = nil
        cancelPendingDragUpdate()
        lastDragUpdateAt = nil
        overlayController.hide()
    }

    private static func recordLatency(_ name: StaticString, since startedAt: TimeInterval) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        os_signpost(
            .event,
            log: performanceLog,
            name: name,
            "latency_ms=%{public}.2f",
            milliseconds
        )
    }
}

struct DragEventCoalescingPolicy {
    var maximumUpdatesPerSecond: Double = 120

    func delay(since lastUpdate: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let lastUpdate else { return 0 }
        let minimumInterval = 1 / maximumUpdatesPerSecond
        return max(0, minimumInterval - (now - lastUpdate))
    }
}

struct WindowDragGestureClassifier {
    static let defaultDragThreshold: CGFloat = 6

    var resizeEdgeInset: CGFloat = 10
    var edgeDecisionGrace: TimeInterval = 0.08
    var minimumEdgeSamples = 2

    func pointerIntent(at point: CGPoint, windowBounds: CGRect) -> WindowPointerIntent {
        guard windowBounds.contains(point) else { return .regular }
        let isNearLeftEdge = point.x <= windowBounds.minX + resizeEdgeInset
        let isNearRightEdge = point.x >= windowBounds.maxX - resizeEdgeInset
        let isNearTopEdge = point.y <= windowBounds.minY + resizeEdgeInset
        let isNearBottomEdge = point.y >= windowBounds.maxY - resizeEdgeInset
        let isNearSideOrBottomEdge = isNearLeftEdge || isNearRightEdge || isNearBottomEdge
        let isTopCorner = isNearTopEdge && (isNearLeftEdge || isNearRightEdge)
        if isNearSideOrBottomEdge || isTopCorner {
            return .resizeEdge
        }

        return .regular
    }

    func classify(
        current: WindowGestureClassification,
        pointerIntent: WindowPointerIntent,
        evidence: WindowGestureEvidence,
        dragThreshold: CGFloat,
        resizeThreshold: CGFloat,
        forceDecision: Bool = false
    ) -> WindowGestureClassification {
        guard current == .undecided else { return current }

        guard evidence.maximumPointerDistance > min(dragThreshold, resizeThreshold) else { return .undecided }

        let hasResizeEvidence = evidence.maximumSizeDistance > resizeThreshold
        let hasWindowMoveEvidence = evidence.maximumPositionDistance > dragThreshold

        switch pointerIntent {
        case .resizeEdge:
            if hasResizeEvidence {
                return .resize
            }
            let graceElapsed = evidence.elapsed >= edgeDecisionGrace
                && evidence.sampleCount >= minimumEdgeSamples
            if hasWindowMoveEvidence && (graceElapsed || forceDecision) {
                return .resize
            }
        case .regular:
            if hasResizeEvidence && evidence.maximumSizeDistance >= evidence.maximumPositionDistance * 0.6 {
                return .resize
            }
            if hasWindowMoveEvidence {
                return .drag
            }
        }

        return .undecided
    }
}

enum WindowInteractionKind: Equatable {
    case observing
    case move
    case resize
    case snap(ZoneID)
    case customPosition(ZoneID)

    var diagnosticName: String {
        switch self {
        case .observing: "observing"
        case .move: "move"
        case .resize: "resize"
        case .snap(let zoneID): "snap:\(zoneID.rawValue)"
        case .customPosition(let zoneID): "custom:\(zoneID.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .observing: "Observing Window"
        case .move: "Moving Window"
        case .resize: "Resizing Window"
        case .snap(let zoneID): "Fit to \(zoneID.rawValue)"
        case .customPosition(let zoneID): "Custom position in \(zoneID.rawValue)"
        }
    }
}

enum WindowInteractionPhase: String, Equatable {
    case began
    case classified
    case preview
    case completed
    case failed
}

struct WindowInteractionEvent: Equatable {
    var sequence: UInt64
    var kind: WindowInteractionKind
    var phase: WindowInteractionPhase
    var windowID: LiveWindowID
}

struct WindowInteractionClassifier {
    func action(
        for classification: WindowGestureClassification,
        zoneDropIsActive: Bool,
        dropIntent: ZoneDropIntent
    ) -> WindowInteractionKind? {
        switch classification {
        case .undecided:
            return nil
        case .resize:
            return .resize
        case .drag:
            guard zoneDropIsActive else { return .move }
            switch dropIntent {
            case .zoneFit(let zoneID): return .snap(zoneID)
            case .custom(let zoneID): return .customPosition(zoneID)
            case .preserve: return .move
            }
        }
    }
}

struct WindowInteractionJournal {
    var limit = 40
    private(set) var events: [WindowInteractionEvent] = []
    private var sequence: UInt64 = 0

    @discardableResult
    mutating func record(
        kind: WindowInteractionKind,
        phase: WindowInteractionPhase,
        windowID: LiveWindowID
    ) -> WindowInteractionEvent {
        sequence &+= 1
        let event = WindowInteractionEvent(
            sequence: sequence,
            kind: kind,
            phase: phase,
            windowID: windowID
        )
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        return event
    }

    var diagnosticLines: [String] {
        events.isEmpty ? ["none"] : events.map {
            "interaction seq=\($0.sequence) phase=\($0.phase.rawValue) action=\($0.kind.diagnosticName) window=\($0.windowID)"
        }
    }
}

struct WindowDragResizePolicy {
    func shouldCancelDrag(frameChange: FrameChange, isDragging: Bool, resizeThreshold: CGFloat) -> Bool {
        frameChange.isLikelyResize(resizeThreshold: resizeThreshold) && !isDragging
    }
}

struct WindowDragGesture {
    var window: ManagedWindow
    var initialEventLocation: CGPoint
    var lastEventLocation: CGPoint
    var initialFrame: CGRect
    var lastFrame: CGRect
    var pointerIntent: WindowPointerIntent = .regular
    var beganAt: TimeInterval = 0
    var classification: WindowGestureClassification = .undecided
    var evidence = WindowGestureEvidence()
    var didBeginWindowInteraction = false
    var isZoneDropActive = true

    mutating func observe(frame: CGRect, timestamp: TimeInterval) {
        lastFrame = frame
        let pointerDistance = hypot(lastEventLocation.x - initialEventLocation.x,
                                    lastEventLocation.y - initialEventLocation.y)
        evidence.maximumPointerDistance = max(evidence.maximumPointerDistance, pointerDistance)
        let change = frame.change(from: initialFrame)
        evidence.maximumPositionDistance = max(evidence.maximumPositionDistance, change.positionDistance)
        evidence.maximumSizeDistance = max(evidence.maximumSizeDistance, change.sizeDistance)
        evidence.sampleCount += 1
        evidence.elapsed = max(evidence.elapsed, timestamp - beganAt)
    }
}

enum WindowPointerIntent: Equatable {
    case resizeEdge
    case regular
}

enum WindowGestureClassification: Equatable {
    case undecided
    case drag
    case resize
}

struct WindowGestureEvidence {
    var maximumPointerDistance: CGFloat = 0
    var maximumPositionDistance: CGFloat = 0
    var maximumSizeDistance: CGFloat = 0
    var sampleCount = 0
    var elapsed: TimeInterval = 0
}

private extension CGRect {
    func change(from other: CGRect) -> FrameChange {
        FrameChange(
            positionDistance: abs(minX - other.minX) + abs(minY - other.minY),
            sizeDistance: abs(width - other.width) + abs(height - other.height)
        )
    }
}

struct FrameChange {
    var positionDistance: CGFloat
    var sizeDistance: CGFloat

    func isLikelyResize(resizeThreshold: CGFloat) -> Bool {
        sizeDistance > resizeThreshold && sizeDistance >= positionDistance * 0.6
    }
}
