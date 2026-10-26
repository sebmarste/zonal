import AppKit
import Darwin
import OSLog

// Optional, read-only SkyLight query, also used by JankyBorders on macOS 26.
// Keep every private symbol optional; outlines must still work on older systems.
final class WindowCornerRadiusReader: @unchecked Sendable {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Query = @convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Iterator = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias Advance = @convention(c) (CFTypeRef) -> Bool
    private typealias Radii = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private let handle: UnsafeMutableRawPointer?

    init(loadPrivateSymbols: Bool = true) {
        if #available(macOS 26, *), loadPrivateSymbols {
            handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        } else { handle = nil }
    }

    deinit { if let handle { dlclose(handle) } }

    func radius(for windowNumber: UInt32) -> CGFloat? {
        guard let handle,
              let connection = dlsym(handle, "SLSMainConnectionID"),
              let query = dlsym(handle, "SLSWindowQueryWindows"),
              let iterator = dlsym(handle, "SLSWindowQueryResultCopyWindows"),
              let advance = dlsym(handle, "SLSWindowIteratorAdvance"),
              let radii = dlsym(handle, "SLSWindowIteratorGetCornerRadii") else { return nil }
        let connectionID = unsafeBitCast(connection, to: Connection.self)()
        guard let queryResult = unsafeBitCast(query, to: Query.self)(
            connectionID, [NSNumber(value: windowNumber)] as CFArray, 0
        )?.takeRetainedValue(),
              let windowIterator = unsafeBitCast(iterator, to: Iterator.self)(queryResult)?.takeRetainedValue(),
              unsafeBitCast(advance, to: Advance.self)(windowIterator),
              let values = unsafeBitCast(radii, to: Radii.self)(windowIterator)?.takeRetainedValue() else { return nil }
        return Self.validatedRadius((values as NSArray).firstObject as? NSNumber)
    }

    static func validatedRadius(_ value: NSNumber?) -> CGFloat? {
        guard let radius = value?.doubleValue, radius.isFinite, (0...128).contains(radius) else { return nil }
        return CGFloat(radius)
    }
}

struct WindowOutlineCoordinatePolicy {
    func appKitFrame(for accessibilityFrame: CGRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: accessibilityFrame.minX,
            y: mainScreenFrame.maxY - accessibilityFrame.maxY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }
}

struct OutlineRefreshState {
    private(set) var revision: UInt64 = 0

    mutating func invalidate() { revision &+= 1 }
    func accepts(_ revision: UInt64) -> Bool { self.revision == revision }
}

struct OutlineRefreshRetryPolicy {
    var delays: [TimeInterval] = [0.05, 0.1, 0.2, 0.4, 0.8]

    func delay(afterAttempt attempt: Int) -> TimeInterval? {
        delays.indices.contains(attempt) ? delays[attempt] : nil
    }
}

struct OutlineWindowKey: Hashable, Sendable {
    var pid: Int32
    var number: UInt32
}

struct VerifiedOutlineFrame {
    var frame: CGRect
    var verifiedAt: TimeInterval

    func freshFrame(at now: TimeInterval) -> CGRect? {
        (0...0.2).contains(now - verifiedAt) ? frame : nil
    }
}

struct OutlineVisibilityPolicy {
    func shouldShow(frame: CGRect, displays: [CGRect]) -> Bool {
        guard let display = displays.max(by: {
            area(frame.intersection($0)) < area(frame.intersection($1))
        }), frame.intersects(display) else { return false }
        return !frame.isClose(to: display, tolerance: 2)
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}

@MainActor
final class ActiveWindowOutlineController {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowOutline")
    private let store: PersistenceStore
    private let queue = DispatchQueue(label: "com.sebmarste.zonal.outline", qos: .userInitiated)
    private let prewarmQueue = DispatchQueue(label: "com.sebmarste.zonal.outline-prewarm", qos: .utility)
    private let radiusQuery: @Sendable (UInt32) -> CGFloat?
    private let visibleFramesProvider: @Sendable () -> [OutlineWindowKey: CGRect]
    private(set) var panel: NSPanel?
    private weak var settingsWindow: NSWindow?
    private var settingsHasFocus = false
    private(set) var focusedKey: OutlineWindowKey?
    private var refreshState = OutlineRefreshState()
    private var pendingRefresh: DispatchWorkItem?
    private(set) var isAwaitingPlacement = false
    private var verifiedFrames: [OutlineWindowKey: VerifiedOutlineFrame] = [:]
    private(set) var cornerRadii: [OutlineWindowKey: CGFloat] = [:]
    private var pendingPrewarm: [OutlineWindowKey: UUID] = [:]
    private let windowServer: OutlineWindowServer?
    private let isFrontmost: (OutlineWindowKey) -> Bool
    private let visibilityCheckInterval: TimeInterval?
    var onWindowOrderingChanged: (() -> Void)?
    private let onFocusNeedsRefresh: () -> Void
    private var isMonitoring = false
    private var draggedWindowID: LiveWindowID?
    private var geometryRefresh: DispatchWorkItem?
    private var visibilityCheck: DispatchWorkItem?
    private var orderingNeedsRefresh = true
    private var pendingPulse: (key: OutlineWindowKey, mode: OutlinePulseMode, expiresAt: TimeInterval)?
    private let isSuspended: () -> Bool
    private let reduceMotion: () -> Bool

    init(store: PersistenceStore,
         radiusQuery: (@Sendable (UInt32) -> CGFloat?)? = nil,
         visibleFramesProvider: @escaping @Sendable () -> [OutlineWindowKey: CGRect] = { ActiveWindowOutlineController.visibleFrames() },
         windowServer: OutlineWindowServer? = nil,
         isFrontmost: @escaping (OutlineWindowKey) -> Bool = { _ in true },
         visibilityCheckInterval: TimeInterval? = nil,
         onFocusNeedsRefresh: @escaping () -> Void = {},
         isSuspended: @escaping () -> Bool = { false },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.store = store
        let reader = WindowCornerRadiusReader()
        self.radiusQuery = radiusQuery ?? { reader.radius(for: $0) }
        self.visibleFramesProvider = visibleFramesProvider
        self.windowServer = windowServer
        self.isFrontmost = isFrontmost
        self.visibilityCheckInterval = visibilityCheckInterval
        self.onFocusNeedsRefresh = onFocusNeedsRefresh
        self.reduceMotion = reduceMotion
        self.isSuspended = isSuspended
    }

    func pulseAfterSwitcherFocus(_ window: ManagedWindow) {
        guard let pid = window.identity.processIdentifier, let number = window.identity.cgWindowID else { return }
        guard queuePulse(for: OutlineWindowKey(pid: pid, number: number), mode: .switcherOnly) else { return }
        if panel?.isVisible == true, !isAwaitingPlacement { startPendingPulse() }
    }

    @discardableResult
    private func queuePulse(for key: OutlineWindowKey, mode: OutlinePulseMode) -> Bool {
        let configuration = store.loadConfiguration()
        guard configuration.showActiveWindowOutline, configuration.behavior.outlinePulseMode == mode,
              !reduceMotion(), !isDraggingFocusedWindow, focusedKey == key else { return false }
        pendingPulse = (key, mode, ProcessInfo.processInfo.systemUptime + 0.8)
        return true
    }

    func cancelPulse() {
        pendingPulse = nil
        (panel?.contentView as? ActiveWindowOutlineView)?.stopPulse()
    }

    private func startPendingPulse() {
        guard let request = pendingPulse else { return }
        pendingPulse = nil
        guard request.key == focusedKey, request.expiresAt >= ProcessInfo.processInfo.systemUptime,
              store.loadConfiguration().behavior.outlinePulseMode == request.mode, !reduceMotion() else { return }
        (panel?.contentView as? ActiveWindowOutlineView)?.startPulse()
    }

    func prewarm(windows: [ManagedWindow]) {
        guard !isSuspended() else { return }
        var keys = Set(windows.compactMap { window -> OutlineWindowKey? in
            guard let pid = window.identity.processIdentifier,
                  let number = window.identity.cgWindowID else { return nil }
            return OutlineWindowKey(pid: pid, number: number)
        })
        if let settingsKey { keys.insert(settingsKey) }
        cornerRadii = cornerRadii.filter { keys.contains($0.key) }
        pendingPrewarm = pendingPrewarm.filter { keys.contains($0.key) }
        verifiedFrames = verifiedFrames.filter { keys.contains($0.key) }
        guard store.loadConfiguration().showActiveWindowOutline else {
            pendingPrewarm.removeAll()
            return
        }
        let candidates = keys.filter { cornerRadii[$0] == nil && pendingPrewarm[$0] == nil }
        guard !candidates.isEmpty else { return }
        let token = UUID()
        for key in candidates { pendingPrewarm[key] = token }
        let query = radiusQuery
        let visibleFrames = visibleFramesProvider
        // Speculative queries must not sit ahead of a real focus handoff.
        prewarmQueue.async { [weak self] in
            let visible = visibleFrames()
            let radii = Dictionary(uniqueKeysWithValues: candidates.filter { visible[$0] != nil }.map {
                ($0, query($0.number) ?? 10)
            })
            Task { @MainActor [weak self] in
                guard let self else { return }
                for key in candidates where self.pendingPrewarm[key] == token {
                    self.pendingPrewarm.removeValue(forKey: key)
                    if self.cornerRadii[key] == nil, let radius = radii[key] { self.cornerRadii[key] = radius }
                }
            }
        }
    }

    func update(window: ManagedWindow?) {
        let key = window.flatMap { window -> OutlineWindowKey? in
            guard let pid = window.identity.processIdentifier,
                  let number = window.identity.cgWindowID else { return nil }
            return OutlineWindowKey(pid: pid, number: number)
        }
        // Native focus loss is authoritative over a delayed inventory snapshot.
        if let key, key == settingsKey, !settingsHasFocus { return }
        update(key: key)
    }

    func resynchronize(window: ManagedWindow?) {
        verifiedFrames.removeAll()
        cornerRadii.removeAll()
        pendingPrewarm.removeAll()
        hide()
        update(window: window)
    }

    // Our own Settings window has native callbacks instead of a self-AX observer.
    func update(settingsWindow: NSWindow, geometryChanged: Bool = false, isFocused: Bool? = nil) {
        guard settingsWindow.windowNumber > 0 else { return }
        self.settingsWindow = settingsWindow
        settingsHasFocus = isFocused ?? settingsWindow.isKeyWindow
        let key = settingsKey
        if settingsHasFocus {
            update(key: key)
            if geometryChanged { geometryDidChange() }
        } else if focusedKey == key {
            update(key: nil)
        }
    }

    private var settingsKey: OutlineWindowKey? {
        guard let settingsWindow, settingsWindow.windowNumber > 0 else { return nil }
        return OutlineWindowKey(pid: ProcessInfo.processInfo.processIdentifier,
                                number: UInt32(settingsWindow.windowNumber))
    }

    private func update(key: OutlineWindowKey?) {
        let focusChanged = focusedKey != key
        focusedKey = key
        _ = windowServer?.observe(windowID: key?.number)
        if focusChanged { orderingNeedsRefresh = true; cancelPulse() }
        if focusChanged {
            isAwaitingPlacement = false
            // A ready handoff can reuse the panel without an order-out/order-in flash.
            let rendered = renderVerifiedFrame()
            if !rendered { hide() }
            if let key { queuePulse(for: key, mode: .allFocusedWindows) }
            if rendered { startPendingPulse(); return }
        }
        // Inventory updates must not bring an outline back during a geometry burst.
        if focusChanged || pendingRefresh == nil { refresh() }
    }

    func updateFrame(for window: ManagedWindow) {
        guard let pid = window.identity.processIdentifier,
              let number = window.identity.cgWindowID else { return }
        let key = OutlineWindowKey(pid: pid, number: number)
        cornerRadii.removeValue(forKey: key)
        verifiedFrames.removeValue(forKey: key)
        pendingPrewarm.removeValue(forKey: key)
        guard key == focusedKey else { return }
        geometryDidChange()
    }

    private func geometryDidChange() {
        guard !isAwaitingPlacement, !isDraggingFocusedWindow else { return }
        if let focusedKey { verifiedFrames.removeValue(forKey: focusedKey) }
        // Invalidate older reads immediately, but merge this burst into one fresh snapshot.
        refreshState.invalidate()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard geometryRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometryRefresh = nil
            self.refresh()
        }
        geometryRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    func windowServerEvent(_ event: OutlineWindowServerEvent) {
        // Repair the outline before tab layout and focus queries can delay this event.
        defer {
            switch event {
            case .frontApplicationChanged, .reordered, .shown, .levelChanged:
                onWindowOrderingChanged?()
            default: break
            }
        }
        switch event {
        case .frontApplicationChanged:
            if let key = focusedKey, !isFrontmost(key) { hide() }
            onFocusNeedsRefresh()
        case .closed(let id), .hidden(let id):
            guard focusedKey?.number == id else { return }
            update(key: nil)
            onFocusNeedsRefresh()
        case .reordered(let id), .shown(let id), .levelChanged(let id):
            guard focusedKey?.number == id else { return }
            orderingNeedsRefresh = true
            // Re-clicks can arrive as "shown" even for an already-visible window.
            // Repair its outline before the asynchronous bounds read.
            if let key = focusedKey, key.number == id, isFrontmost(key),
               !isAwaitingPlacement, !isDraggingFocusedWindow, let panel, panel.isVisible {
                order(panel, above: key, parent: key == settingsKey ? settingsWindow : nil)
            }
            if case .reordered = event { onFocusNeedsRefresh() }
            geometryDidChange()
        case .moved(let id), .resized(let id):
            guard focusedKey?.number == id else { return }
            if !isAwaitingPlacement { cancelPulse() }
            orderingNeedsRefresh = true
            geometryDidChange()
        }
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        windowServer?.start { [weak self] event in self?.windowServerEvent(event) }
        _ = windowServer?.observe(windowID: focusedKey?.number)
        scheduleVisibilityCheck()
    }

    private func scheduleVisibilityCheck() {
        guard isMonitoring, let interval = visibilityCheckInterval, interval > 0,
              visibilityCheck == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.visibilityCheck = nil
            guard self.isMonitoring else { return }
            defer { self.scheduleVisibilityCheck() }
            guard self.store.loadConfiguration().showActiveWindowOutline else {
                self.hide()
                return
            }
            // This lightweight read also repairs same-app focus changes and missing outlines.
            self.onFocusNeedsRefresh()
            guard let key = self.focusedKey, self.panel?.isVisible == true else { return }
            if !self.isFrontmost(key) { self.hide() }
            else if self.pendingRefresh == nil, self.geometryRefresh == nil, !self.isAwaitingPlacement {
                self.refresh()
            }
        }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    func detailedDiagnosticLines() -> [String] {
        ["Outline target: pid=\(focusedKey?.pid ?? 0) window=\(focusedKey?.number ?? 0) visible=\(panel?.isVisible == true) fallbackInterval=\(visibilityCheckInterval ?? 0)"]
            + (windowServer?.detailedDiagnosticLines() ?? ["Outline WindowServer: disabled"])
    }

    func stop() {
        isMonitoring = false
        hide()
        focusedKey = nil
        draggedWindowID = nil
        windowServer?.stop()
    }

    func windowDragChanged(_ windowID: LiveWindowID?) {
        draggedWindowID = windowID
        if let focusedKey { verifiedFrames.removeValue(forKey: focusedKey) }
        if isDraggingFocusedWindow { hide() }
        else { refresh() }
    }

    private var isDraggingFocusedWindow: Bool {
        draggedWindowID.map { isFocused($0) } ?? false
    }

    func placementStarted(for windowID: LiveWindowID) {
        if case .quartz(let pid, let number) = windowID {
            verifiedFrames.removeValue(forKey: OutlineWindowKey(pid: pid, number: number))
        }
        if isFocused(windowID) {
            isAwaitingPlacement = true
            let pulse = pendingPulse
            hide()
            pendingPulse = pulse
        }
    }

    func placementSettled(for windowID: LiveWindowID) {
        if isFocused(windowID), isAwaitingPlacement {
            isAwaitingPlacement = false
            if !renderVerifiedFrame() { refresh() }
        }
    }

    func placementVerified(for windowID: LiveWindowID, frame: CGRect) {
        guard case .quartz(let pid, let number) = windowID else { return }
        if verifiedFrames.count >= 64 { verifiedFrames.removeAll() }
        verifiedFrames[OutlineWindowKey(pid: pid, number: number)] = VerifiedOutlineFrame(
            frame: frame, verifiedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private func renderVerifiedFrame() -> Bool {
        guard store.loadConfiguration().showActiveWindowOutline,
              !isAwaitingPlacement, !isDraggingFocusedWindow,
              let key = focusedKey, let radius = cornerRadii[key],
              let frame = verifiedFrames[key]?.freshFrame(at: ProcessInfo.processInfo.systemUptime),
              let main = NSScreen.screens.first?.frame else { return false }
        let converted = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: main)
        guard OutlineVisibilityPolicy().shouldShow(frame: converted, displays: NSScreen.screens.map(\.frame)) else { return false }
        refreshState.invalidate()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        render(frame: converted, radius: radius)
        return true
    }

    private func isFocused(_ windowID: LiveWindowID) -> Bool {
        guard case .quartz(let pid, let number) = windowID else { return false }
        return focusedKey == OutlineWindowKey(pid: pid, number: number)
    }

    func refresh(after delay: TimeInterval = 0, attempt: Int = 0) {
        guard !isSuspended(), store.loadConfiguration().showActiveWindowOutline,
              let key = focusedKey, isFrontmost(key) else { hide(); return }
        guard !isAwaitingPlacement else { return }
        guard !isDraggingFocusedWindow else { hide(); return }
        pendingRefresh?.cancel()
        refreshState.invalidate()
        let revision = refreshState.revision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.refreshState.accepts(revision) else { return }
            let displays = NSScreen.screens.map(\.frame)
            guard let primaryFrame = displays.first else { self.hide(); return }
            let focused = self.focusedKey
            let query = self.radiusQuery
            let visibleFrames = self.visibleFramesProvider
            let cachedRadius = focused.flatMap { self.cornerRadii[$0] }
            self.queue.async { [weak self] in
                let quartzFrames = visibleFrames()
                let capturedAt = ProcessInfo.processInfo.systemUptime
                let frames = quartzFrames.mapValues {
                    WindowOutlineCoordinatePolicy().appKitFrame(for: $0, mainScreenFrame: primaryFrame)
                }
                let frame = focused.flatMap { frames[$0] }.flatMap {
                    OutlineVisibilityPolicy().shouldShow(frame: $0, displays: displays) ? $0 : nil
                }
                let radius = cachedRadius ?? (frame == nil ? 10 : focused.flatMap { query($0.number) } ?? 10)
                Task { @MainActor [weak self] in
                    guard let self, self.refreshState.accepts(revision) else { return }
                    self.pendingRefresh = nil
                    guard let key = self.focusedKey, self.isFrontmost(key) else {
                        self.hide()
                        self.onFocusNeedsRefresh()
                        return
                    }
                    if let frame {
                        self.cornerRadii = self.cornerRadii.filter { frames[$0.key] != nil }
                        if let focused { self.cornerRadii[focused] = radius }
                        // The watchdog already reads all visible frames. Reuse these exact,
                        // short-lived snapshots for a focus handoff without ordering out.
                        self.verifiedFrames = self.verifiedFrames.filter { quartzFrames[$0.key] != nil }
                        for (key, bounds) in quartzFrames where self.cornerRadii[key] != nil {
                            self.verifiedFrames[key] = VerifiedOutlineFrame(frame: bounds, verifiedAt: capturedAt)
                        }
                        self.render(frame: frame, radius: radius)
                    }
                    else {
                        self.hide()
                        self.onFocusNeedsRefresh()
                        if let focused, self.focusedKey == focused,
                           let retryDelay = OutlineRefreshRetryPolicy().delay(afterAttempt: attempt) {
                            self.refresh(after: retryDelay, attempt: attempt + 1)
                        }
                    }
                }
            }
        }
        pendingRefresh = work
        if delay == 0 { work.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    func hide() {
        cancelPulse()
        geometryRefresh?.cancel()
        geometryRefresh = nil
        visibilityCheck?.cancel()
        visibilityCheck = nil
        refreshState.invalidate()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        panel?.orderOut(nil)
        if let panel { panel.parent?.removeChildWindow(panel) }
        scheduleVisibilityCheck()
    }

    private nonisolated static func visibleFrames() -> [OutlineWindowKey: CGRect] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return visibleFrames(from: rows)
    }

    nonisolated static func visibleFrames(from rows: [[String: Any]]) -> [OutlineWindowKey: CGRect] {
        var result: [OutlineWindowKey: CGRect] = [:]
        for row in rows {
            // Match the exact tracked window even when an app uses a floating window level.
            guard let number = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            result[OutlineWindowKey(pid: pid, number: number)] = frame
        }
        return result
    }

    private func render(frame: CGRect, radius: CGFloat) {
        guard !isSuspended() else { hide(); return }
        guard let key = focusedKey, isFrontmost(key), !isDraggingFocusedWindow else { hide(); return }
        let parent = focusedKey == settingsKey ? settingsWindow : nil
        if let parent, !settingsHasFocus || !parent.isKeyWindow || !NSApp.isActive {
            hide()
            return
        }
        let configuration = store.loadConfiguration()
        let width = WindowOutlineStyle(configuration: configuration).width
        let panel = self.panel ?? makePanel()
        (panel as? ActiveWindowOutlinePanel)?.targetWindowKey = key
        let view = panel.contentView as? ActiveWindowOutlineView ?? ActiveWindowOutlineView()
        let appearanceChanged = view.strokeWidth != width || view.cornerRadius != radius
            || view.strokeColor != configuration.activeWindowOutlineColor.nsColor
        if configuration.behavior.outlinePulseMode == .off || reduceMotion() { cancelPulse() }
        view.strokeWidth = width
        view.cornerRadius = radius
        view.strokeColor = configuration.activeWindowOutlineColor.nsColor
        let outset = OutlineStrokeGeometry.effectOutset(for: width)
        let panelFrame = frame.insetBy(dx: -outset, dy: -outset)
        let frameChanged = panel.frame != panelFrame
        view.frame = CGRect(origin: .zero, size: panelFrame.size)
        if appearanceChanged || frameChanged { view.needsDisplay = true }
        if panel.contentView !== view { panel.contentView = view }
        if frameChanged { view.stopPulse(); panel.setFrame(panelFrame, display: true, animate: false) }
        let needsOrdering = orderingNeedsRefresh || frameChanged || !panel.isVisible
        if needsOrdering {
            order(panel, above: key, parent: parent)
        }
        self.panel = panel
        startPendingPulse()
        scheduleVisibilityCheck()
        if needsOrdering, let focusedKey {
            Self.logger.info("handoff.stage=outlinePresented pid=\(focusedKey.pid) window=\(focusedKey.number) uptime=\(ProcessInfo.processInfo.systemUptime)")
        }
    }

    private func order(_ panel: NSPanel, above key: OutlineWindowKey, parent: NSWindow?) {
        configureOrdering(of: panel, parent: parent)
        if let parent { panel.order(.above, relativeTo: parent.windowNumber) }
        else if windowServer?.order(panel: panel, relativeTo: key.number) != true {
            panel.order(.above, relativeTo: Int(key.number))
        }
        orderingNeedsRefresh = false
    }

    func configureOrdering(of panel: NSPanel, parent: NSWindow?) {
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel) }
        panel.level = parent?.level ?? .normal
        panel.collectionBehavior = parent == nil
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            : [.fullScreenAuxiliary, .transient, .ignoresCycle]
        if let parent, panel.parent !== parent {
            parent.addChildWindow(panel, ordered: .above)
        }
    }

    func makePanel() -> NSPanel {
        let panel = ActiveWindowOutlinePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }
}

// The stroke margin may cross the menu-bar boundary; never shift it off its target.
final class ActiveWindowOutlinePanel: NSPanel {
    var targetWindowKey: OutlineWindowKey?
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ActiveWindowOutlineView: NSView {
    var strokeColor: NSColor = .controlAccentColor
    var strokeWidth: CGFloat = 3
    var cornerRadius: CGFloat = 10

    private var pulseTimer: Timer?
    private var pulseStartedAt: TimeInterval?
    private(set) var pulseCount = 0
    private(set) var pulseStrength: CGFloat = 0

    func startPulse() {
        stopPulse()
        pulseCount += 1
        pulseStartedAt = ProcessInfo.processInfo.systemUptime
        pulseStrength = 0
        needsDisplay = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard let self, let start = self.pulseStartedAt else { return }
                let progress = (ProcessInfo.processInfo.systemUptime - start) / OutlineConfirmationPulse.duration
                if progress >= 1 { self.stopPulse() }
                else { self.pulseStrength = OutlineConfirmationPulse.strength(at: progress * OutlineConfirmationPulse.duration); self.needsDisplay = true }
            }
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseStartedAt = nil
        pulseStrength = 0
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        strokeColor.setStroke()
        let geometry = OutlineStrokeGeometry(bounds: bounds, width: strokeWidth, radius: cornerRadius)
        let path = NSBezierPath(
            roundedRect: geometry.rect,
            xRadius: geometry.radius,
            yRadius: geometry.radius
        )
        path.lineWidth = geometry.width + pulseStrength * 1.5
        path.stroke()
    }
}

struct OutlineConfirmationPulse {
    static let duration: TimeInterval = 0.16

    static func strength(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > 0, elapsed < duration else { return 0 }
        return CGFloat(pow(sin(.pi * elapsed / duration), 2))
    }
}

struct OutlineStrokeGeometry {
    var rect: CGRect
    var radius: CGFloat
    var width: CGFloat

    // Whole-point outsets avoid AppKit rounding the panel origin; retain antialiasing room.
    static func effectOutset(for width: CGFloat) -> CGFloat { ceil(max(0, width) / 2) + 1 }

    init(bounds: CGRect, width: CGFloat, radius: CGFloat) {
        self.width = min(max(0, width), max(0, min(bounds.width, bounds.height)))
        let inset = Self.effectOutset(for: self.width)
        rect = bounds.insetBy(dx: inset, dy: inset)
        self.radius = max(0, min(radius, min(rect.width, rect.height) / 2))
    }
}
