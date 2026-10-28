import AppKit
import SwiftUI

struct ZoneTabGroupPolicy {
    // Equal frames only; intersecting rectangles do not imply a shared stack.
    static func owner(for zone: Zone, profile: DisplayProfile,
                      sameArea: (Zone, Zone) -> Bool = {
                          $0.frame == $1.frame && ($0.displayRoleID ?? .workspace) == ($1.displayRoleID ?? .workspace)
                      }) -> Zone? {
        let candidates = profile.zones.filter {
            $0.windowPresentation == .tabs && sameArea(zone, $0)
        }
        return candidates.first { $0.id == profile.mainZoneID } ?? candidates.first
            ?? (zone.windowPresentation == .tabs ? zone : nil)
    }
}

// Quartz coordinates: top is minY. Every fitted member shares the same content frame.
struct ZoneTabLayout: Equatable {
    var stripFrame: CGRect
    var windowFrame: CGRect
    var style: ZoneTabStyle
    var zoneFrame: CGRect

    var borderWidth: CGFloat
    var tabPadding: CGFloat

    init(zoneFrame: CGRect, edge: ZoneTabEdge, style: ZoneTabStyle = .frame,
         borderWidth: CGFloat = ZoneTabMetrics.defaultBorderWidth) {
        self.style = style
        self.zoneFrame = zoneFrame
        self.borderWidth = ZoneTabMetrics.clampedBorderWidth(borderWidth)
        switch style {
        case .shelf:
            let geometry = ZoneTabShelfGeometry(zoneFrame: zoneFrame, edge: edge)
            windowFrame = geometry.windowFrame
            stripFrame = geometry.stripFrame
            tabPadding = ZoneTabMetrics.minimumPadding
        case .frame:
            let geometry = ZoneTabFrameGeometry(zoneFrame: zoneFrame, edge: edge, borderWidth: self.borderWidth)
            windowFrame = geometry.windowFrame
            stripFrame = geometry.stripFrame
            tabPadding = geometry.tabPadding
        }
    }

    func panelFrame(edge: ZoneTabEdge) -> CGRect {
        switch style {
        case .shelf: ZoneTabShelfGeometry(zoneFrame: zoneFrame, edge: edge).panelFrame
        case .frame: ZoneTabFrameGeometry(zoneFrame: zoneFrame, edge: edge, borderWidth: borderWidth).panelFrame
        }
    }

}

struct ZoneTabSnapshot: Equatable {
    var zoneID: ZoneID
    var edge: ZoneTabEdge
    var layout: ZoneTabLayout
    var items: [SwitcherItem]
    var showsNames = true
    var outlineStyle = WindowOutlineStyle()
    var hasFittedWindows = true
    var otherZoneItems: [SwitcherItem] = []
    var stackItems: [SwitcherItem] = []
    var fittedWindowIDs: Set<LiveWindowID> = []
    var moveDestinations: [Zone] = []
    var sizeActions: [UUID: ZoneTabAction] = [:]

    var orderingItems: [SwitcherItem] { stackItems.isEmpty ? items : stackItems }

    func panelFrame() -> CGRect {
        hasFittedWindows ? layout.panelFrame(edge: edge)
            : layout.stripFrame.insetBy(dx: -ZoneTabShelfGeometry.effectOutset, dy: -ZoneTabShelfGeometry.effectOutset)
    }

}

struct ZoneTabVisibleWindow {
    var key: OutlineWindowKey
    var frame: CGRect
    var level: Int = 0
}

// Keep backings beneath native windows and their shadows.
struct ZoneTabVisibilityPolicy {
    func members(for snapshot: ZoneTabSnapshot, visible: [ZoneTabVisibleWindow]) -> [ZoneTabVisibleWindow] {
        let keys = Set(snapshot.orderingItems.compactMap { item -> OutlineWindowKey? in
            guard let pid = item.identity.processIdentifier, let id = item.identity.cgWindowID else { return nil }
            return OutlineWindowKey(pid: pid, number: id)
        })
        return visible.filter { keys.contains($0.key) && $0.frame.intersects(snapshot.layout.stripFrame.union(snapshot.layout.windowFrame)) }
    }

    func foremostFittedWindow(for snapshot: ZoneTabSnapshot, visible: [ZoneTabVisibleWindow],
                             excluding key: OutlineWindowKey? = nil) -> ZoneTabVisibleWindow? {
        guard snapshot.hasFittedWindows else { return nil }
        return members(for: snapshot, visible: visible).first { member in
            guard member.key != key else { return false }
            if snapshot.fittedWindowIDs.isEmpty {
                return member.frame.matchesPlacement(to: snapshot.layout.windowFrame)
            }
            return snapshot.fittedWindowIDs.contains(.quartz(processIdentifier: member.key.pid, windowNumber: member.key.number))
        }
    }

    func target(for snapshot: ZoneTabSnapshot, visible: [ZoneTabVisibleWindow],
                draggedWindowID: LiveWindowID? = nil) -> OutlineWindowKey? {
        let members = members(for: snapshot, visible: visible)
        if let key = members.first?.key { return key }
        // Keep the source bar alive when its last member is dragged beyond the zone.
        guard let draggedWindowID,
              let item = snapshot.orderingItems.first(where: { item in
                  guard let pid = item.identity.processIdentifier, let number = item.identity.cgWindowID else { return false }
                  return .quartz(processIdentifier: pid, windowNumber: number) == draggedWindowID
              }), let pid = item.identity.processIdentifier, let number = item.identity.cgWindowID else { return nil }
        let key = OutlineWindowKey(pid: pid, number: number)
        return visible.contains { $0.key == key } ? key : nil
    }

    private func backingMembers(for snapshot: ZoneTabSnapshot, visible: [ZoneTabVisibleWindow]) -> Set<OutlineWindowKey> {
        Set(members(for: snapshot, visible: visible).filter { member in
            snapshot.layout.style != .frame || (snapshot.fittedWindowIDs.isEmpty
                ? member.frame.matchesPlacement(to: snapshot.layout.windowFrame)
                : snapshot.fittedWindowIDs.contains(.quartz(processIdentifier: member.key.pid,
                                                            windowNumber: member.key.number)))
        }.map(\.key))
    }

    func backingIsCorrect(for snapshot: ZoneTabSnapshot, panelID: UInt32,
                          anchor: OutlineWindowKey, visible: [ZoneTabVisibleWindow],
                          ignoredWindowIDs: Set<UInt32>) -> Bool {
        guard let anchorIndex = visible.firstIndex(where: { $0.key == anchor }),
              let panelIndex = visible.firstIndex(where: { $0.key.number == panelID }),
              panelIndex > anchorIndex,
              visible[panelIndex].level == visible[anchorIndex].level else { return false }
        let members = backingMembers(for: snapshot, visible: visible)
        // Raising another fitted member leaves the backing safely below both windows.
        // Keep it there instead of weaving it through their native shadows. An unrelated
        // overlapping window still requires repair so it cannot obscure the active tabs.
        return visible[(anchorIndex + 1)..<panelIndex].allSatisfy {
            ignoredWindowIDs.contains($0.key.number) || members.contains($0.key)
                || !$0.frame.intersects(snapshot.panelFrame())
        }
    }

    func backingTarget(for snapshot: ZoneTabSnapshot, visible: [ZoneTabVisibleWindow],
                       target: OutlineWindowKey, dragged: OutlineWindowKey?,
                       ignoredWindowIDs: Set<UInt32> = []) -> OutlineWindowKey {
        // An opaque tray must never rise above the stationary fitted window, even
        // when a custom-position member or an unrelated dragged window is foremost.
        var anchor = snapshot.layout.style == .frame
            ? foremostFittedWindow(for: snapshot, visible: visible, excluding: dragged)?.key ?? target
            : target
        if let index = visible.firstIndex(where: { $0.key == anchor }) {
            let members = backingMembers(for: snapshot, visible: visible)
            for row in visible.dropFirst(index + 1) {
                if ignoredWindowIDs.contains(row.key.number) || !row.frame.intersects(snapshot.panelFrame()) { continue }
                guard members.contains(row.key), row.level == visible[index].level else { break }
                anchor = row.key
            }
        }
        guard let dragged,
              let anchorIndex = visible.firstIndex(where: { $0.key == anchor }),
              let draggedIndex = visible.firstIndex(where: { $0.key == dragged }) else { return anchor }
        return anchorIndex > draggedIndex ? anchor : dragged
    }
}

struct ZoneTabContinuityPolicy {
    // Bridge a missed native sample, without keeping stale backings indefinitely.
    var graceInterval: TimeInterval = 0.5

    func canRetain(previous: ZoneTabSnapshot, current: ZoneTabSnapshot, target: OutlineWindowKey,
                   visible: [ZoneTabVisibleWindow], lastConfirmedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard now >= lastConfirmedAt, now - lastConfirmedAt <= graceInterval,
              previous.zoneID == current.zoneID, previous.edge == current.edge,
              previous.layout == current.layout, previous.hasFittedWindows == current.hasFittedWindows,
              previous.fittedWindowIDs == current.fittedWindowIDs,
              Set(previous.orderingItems.map(\.assignmentID)) == Set(current.orderingItems.map(\.assignmentID)),
              previous.orderingItems.allSatisfy({ item in
                  current.orderingItems.contains { $0.assignmentID == item.assignmentID
                      && $0.identity.processIdentifier == item.identity.processIdentifier
                      && $0.identity.cgWindowID == item.identity.cgWindowID }
              }) else { return false }
        let footprint = current.hasFittedWindows ? current.panelFrame() : current.layout.stripFrame
        // Fresh movement or an intersecting native surface makes the old backing unsafe.
        return !visible.contains { $0.key == target || $0.frame.intersects(footprint) }
    }
}

@MainActor
final class ZoneTabController: NSObject {
    private struct Presentation {
        var panel: NSPanel
        var host: ZoneTabHostingView
        var snapshot: ZoneTabSnapshot
        var target: OutlineWindowKey
        var cornerRadius: CGFloat
        var lastConfirmedAt: TimeInterval
    }
    private let snapshots: () -> [ZoneTabSnapshot]
    private let focus: (UUID) -> Void
    private let performAction: (UUID, ZoneTabAction) -> Void
    private let prepareDrag: (UUID) -> ZoneTabDragPlan?
    private let radiusQuery: (UInt32) -> CGFloat?
    private let isSuspended: () -> Bool
    private let visibleWindowQuery: () -> [ZoneTabVisibleWindow]?
    private let uptime: () -> TimeInterval
    private let displaySnapshotQuery: () -> DisplaySnapshot
    private var displaySnapshot: DisplaySnapshot?
    private var spaceObserver: NSObjectProtocol?
    private var cornerRadii: [OutlineWindowKey: CGFloat] = [:]
    // Read target levels without subscribing to another global notification stream.
    private let windowServer = OutlineWindowServer()
    private var presentations: [ZoneID: Presentation] = [:]
    private(set) var refreshCount: UInt64 = 0
    private(set) var contentUpdateCount: UInt64 = 0
    private(set) var layoutCount: UInt64 = 0
    private var radiusReadAt: [OutlineWindowKey: TimeInterval] = [:]
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var draggedWindowID: LiveWindowID?

    init(snapshots: @escaping () -> [ZoneTabSnapshot], focus: @escaping (UUID) -> Void,
         performAction: @escaping (UUID, ZoneTabAction) -> Void = { _, _ in },
         prepareDrag: @escaping (UUID) -> ZoneTabDragPlan? = { _ in nil },
         radiusQuery: ((UInt32) -> CGFloat?)? = nil,
         isSuspended: @escaping () -> Bool = { false },
         visibleWindowQuery: @escaping () -> [ZoneTabVisibleWindow]? = {
             guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
             return ZoneTabController.visibleWindows(rows)
         }, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         displaySnapshotQuery: @escaping () -> DisplaySnapshot = { MacDisplaySnapshotProvider().currentSnapshot() }) {
        self.snapshots = snapshots
        self.focus = focus
        self.performAction = performAction
        self.prepareDrag = prepareDrag
        self.isSuspended = isSuspended
        self.visibleWindowQuery = visibleWindowQuery
        self.uptime = uptime
        self.displaySnapshotQuery = displaySnapshotQuery
        let reader = WindowCornerRadiusReader()
        self.radiusQuery = radiusQuery ?? { reader.radius(for: $0) }
        super.init()
    }

    private let dragOverlay = HotZoneOverlayController()
    private var pendingDragPreview: DispatchWorkItem?
    lazy var interaction = ZoneTabInteractionController(focus: focus, performAction: performAction,
        prepareDrag: prepareDrag, preview: { [weak self] plan, point in self?.updateDragPreview(plan, point: point) })

    private func updateDragPreview(_ plan: ZoneTabDragPlan?, point: CGPoint?) {
        pendingDragPreview?.cancel()
        pendingDragPreview = nil
        guard let plan, let point else { dragOverlay.hide(); return }
        // Coalesce rendering outside the mouse event tap so SwiftUI cannot stall input delivery.
        let update = DispatchWorkItem { [weak self] in
            guard let self, self.interaction.isActive, let main = NSScreen.screens.first,
                  let first = plan.displays.displays.first else { return }
            let bounds = plan.displays.displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
            self.dragOverlay.show(targets: plan.overlayTargets(at: point), coordinateDisplayFrame: bounds,
                windowFrame: WindowOutlineCoordinatePolicy().appKitFrame(for: bounds, mainScreenFrame: main.frame))
        }
        pendingDragPreview = update
        DispatchQueue.main.async(execute: update)
    }

    private func beginPress(_ id: UUID, event: NSEvent, sizeAction: ZoneTabAction?) {
        guard !isSuspended(), let main = NSScreen.screens.first else { return }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        interaction.press(id: id, point: CGPoint(x: point.x, y: main.frame.maxY - point.y),
                          timestamp: event.timestamp, clickCount: event.clickCount, sizeAction: sizeAction)
    }

    var panels: [NSPanel] { presentations.values.map(\.panel) }

    func start() {
        guard timer == nil else { return }
        configureDisplayLink()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 0.2
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        displaySnapshot = nil
        hide()
        cornerRadii.removeAll()
        radiusReadAt.removeAll()
    }

    func windowDragChanged(_ id: LiveWindowID?) { draggedWindowID = id; refresh() }

    // Coalesce geometry notifications; focus and mouse-down still refresh immediately.
    func requestRefresh() {
        guard let displayLink else { refresh(); return }
        displayLink.isPaused = false
    }

    private func configureDisplayLink() {
        displayLink?.invalidate()
        displayLink = NSScreen.main?.displayLink(target: self, selector: #selector(displayFrame(_:)))
        displayLink?.isPaused = true
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func displayFrame(_ sender: CADisplayLink) {
        displayLink?.isPaused = true
        refresh()
    }

    func hide() {
        interaction.cancel()
        displayLink?.isPaused = true
        for presentation in presentations.values { presentation.panel.orderOut(nil) }
        presentations.removeAll()
    }

    func detailedDiagnosticLines() -> [String] {
        ["Tab work: refreshes=\(refreshCount) contentUpdates=\(contentUpdateCount) layouts=\(layoutCount) panels=\(presentations.count) hostLayouts=\(presentations.values.reduce(0) { $0 + $1.host.layoutPassCount }) fallbackInterval=1"]
    }

    func refresh() {
        refreshCount &+= 1
        defer {
            // Follow native stacking at display cadence while a window is dragged.
            if !isSuspended(), !presentations.isEmpty,
               draggedWindowID != nil {
                displayLink?.isPaused = false
            }
        }
        if isSuspended() {
            interaction.cancel()
            // Keep the host and its geometry, but never show tabs over the lock screen.
            for presentation in presentations.values { presentation.panel.orderOut(nil) }
            return
        }
        guard let mainScreen = NSScreen.screens.first else { hide(); return }
        let topology = displaySnapshotQuery()
        if let displaySnapshot, displaySnapshot != topology {
            hide()
            if timer != nil { configureDisplayLink() }
        }
        displaySnapshot = topology
        let models = snapshots()
        guard !models.isEmpty else { hide(); return }
        let visible = visibleWindowQuery() ?? []
        let now = uptime()
        let dragged = visible.first {
            LiveWindowID.quartz(processIdentifier: $0.key.pid, windowNumber: $0.key.number) == draggedWindowID
        }
        let visibleKeys = Set(visible.map(\.key) + models.flatMap { $0.orderingItems.compactMap { item in
            guard let pid = item.identity.processIdentifier, let number = item.identity.cgWindowID else { return nil }
            return OutlineWindowKey(pid: pid, number: number)
        } })
        cornerRadii = cornerRadii.filter { visibleKeys.contains($0.key) }
        radiusReadAt = radiusReadAt.filter { visibleKeys.contains($0.key) }
        let ignored = Set(NSApp.windows.filter { $0 is ZoneTabPanel || $0 is ActiveWindowOutlinePanel }
            .compactMap { UInt32(exactly: $0.windowNumber) })
        var retained = Set<ZoneID>()
        for model in models {
            guard model.layout.stripFrame.width >= 8, model.layout.stripFrame.height >= 8 else { continue }
            let previous = presentations[model.zoneID]
            guard let target = ZoneTabVisibilityPolicy().target(for: model, visible: visible, draggedWindowID: draggedWindowID) else {
                if let previous, ZoneTabContinuityPolicy().canRetain(previous: previous.snapshot, current: model,
                    target: previous.target, visible: visible.filter { !ignored.contains($0.key.number) }, lastConfirmedAt: previous.lastConfirmedAt, now: now) {
                    retained.insert(model.zoneID)
                }
                continue
            }
            retained.insert(model.zoneID)
            let seam = ZoneTabVisibilityPolicy().foremostFittedWindow(for: model, visible: visible, excluding: dragged?.key)
                ?? visible.first { $0.key == target }
            let seamKey = seam?.key ?? target
            let radius = cornerRadius(for: seamKey, fallback: previous?.cornerRadius ?? 16)
            let footprint = model.panelFrame()
            let frame = WindowOutlineCoordinatePolicy().appKitFrame(for: footprint, mainScreenFrame: mainScreen.frame)
            let panel = previous?.panel ?? Self.makePanel()
            let view = ZoneTabStripView(snapshot: model, focus: focus, cornerRadius: radius, performAction: performAction,
                beginPress: { [weak self] id, event, action in self?.beginPress(id, event: event, sizeAction: action) })
            let host = previous?.host ?? ZoneTabHostingView(rootView: view)
            let contentChanged = previous?.snapshot != model || previous?.cornerRadius != radius
            if previous == nil {
                host.sizingOptions = []
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.clear.cgColor
            } else if contentChanged {
                host.rootView = view
            }
            if contentChanged { contentUpdateCount &+= 1 }
            let frameChanged = panel.frame != frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if panel.contentView !== host { panel.contentView = host }
            if frameChanged { panel.setFrame(frame, display: true, animate: false) }
            if frameChanged || contentChanged {
                host.layoutSubtreeIfNeeded()
                layoutCount &+= 1
            }
            let anchor = ZoneTabVisibilityPolicy().backingTarget(for: model, visible: visible,
                target: target, dragged: dragged?.key, ignoredWindowIDs: ignored)
            // Same-level ordering lets native windows and shadows cover the entire backing.
            if !panel.isVisible || !ZoneTabVisibilityPolicy().backingIsCorrect(for: model,
                panelID: UInt32(panel.windowNumber), anchor: anchor, visible: visible,
                ignoredWindowIDs: ignored) {
                if !windowServer.order(panel: panel, relativeTo: anchor.number, ordering: .below) {
                    panel.level = windowServer.level(for: anchor.number) ?? .normal
                    panel.order(.below, relativeTo: Int(anchor.number))
                }
            }
            CATransaction.commit()
            presentations[model.zoneID] = Presentation(panel: panel, host: host, snapshot: model, target: target, cornerRadius: radius, lastConfirmedAt: now)
        }
        for id in Array(presentations.keys) where !retained.contains(id) {
            presentations.removeValue(forKey: id)?.panel.orderOut(nil)
        }
    }

    func cornerRadius(for key: OutlineWindowKey, fallback: CGFloat = 16) -> CGFloat {
        let now = uptime()
        if let readAt = radiusReadAt[key], (0..<1).contains(now - readAt), let radius = cornerRadii[key] {
            return radius
        }
        radiusReadAt[key] = now
        // Zero is transient while Window Server rebuilds a rounded window's shape.
        if let radius = radiusQuery(key.number), radius.isFinite, radius > 0, radius <= 128 {
            cornerRadii[key] = radius
        }
        return cornerRadii[key] ?? fallback
    }

    static func visibleWindows(_ rows: [[String: Any]]) -> [ZoneTabVisibleWindow] {
        rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ZoneTabVisibleWindow(key: OutlineWindowKey(pid: pid, number: id), frame: frame, level: row[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    static func makePanel() -> NSPanel {
        let panel = ZoneTabPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }
}

final class ZoneTabHostingView: NSHostingView<ZoneTabStripView> {
    private(set) var layoutPassCount = 0
    override func layout() {
        layoutPassCount += 1
        super.layout()
    }
}

final class ZoneTabPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The visible surface is already inside its zone; allow its transparent shadow margin across screen edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { NSApp.preventWindowOrdering() }
        super.sendEvent(event)
    }
}

struct ZoneTabStripView: View {
    var snapshot: ZoneTabSnapshot
    var focus: (UUID) -> Void
    var cornerRadius: CGFloat = 16
    var performAction: (UUID, ZoneTabAction) -> Void = { _, _ in }
    var beginPress: ((UUID, NSEvent, ZoneTabAction?) -> Void)?
    var body: some View {
        let panel = snapshot.panelFrame()
        let strip = snapshot.layout.stripFrame.offsetBy(dx: -panel.minX, dy: -panel.minY)
        ZStack(alignment: .topLeading) {
            if snapshot.layout.style == .shelf || !snapshot.hasFittedWindows {
                ZoneTabSurface(surfaceFrame: strip, cornerRadius: 10, borderOpacity: 0.7)
            } else {
                let geometry = ZoneTabFrameGeometry(zoneFrame: snapshot.layout.zoneFrame, edge: snapshot.edge,
                                                    borderWidth: snapshot.layout.borderWidth)
                ZoneTabSurface(surfaceFrame: geometry.localSurfaceFrame,
                    cornerRadius: cornerRadius + snapshot.layout.borderWidth, borderOpacity: 0.65)
            }
            tabContent
                .clipped()
                .offset(x: strip.minX, y: strip.minY)
        }
        .frame(width: panel.width, height: panel.height, alignment: .topLeading)
    }

    private var tabContent: some View {
        Group {
            if snapshot.otherZoneItems.isEmpty {
                ownSection
            } else if snapshot.edge.isVertical {
                VStack(spacing: 4) {
                    if !snapshot.items.isEmpty {
                        ownSection
                        Divider().frame(height: 1)
                    }
                    otherTabs.frame(height: otherExtent)
                }
            } else {
                HStack(spacing: 4) {
                    if !snapshot.items.isEmpty {
                        ownSection
                        Divider().frame(width: 1, height: 16)
                    }
                    otherTabs.frame(width: otherExtent)
                }
            }
        }
        .padding(snapshot.layout.tabPadding)
        .frame(width: snapshot.layout.stripFrame.width, height: snapshot.layout.stripFrame.height,
               alignment: snapshot.edge.isVertical ? .bottom : .trailing)
    }

    private var otherExtent: CGFloat {
        let available = max(0, (snapshot.edge.isVertical ? snapshot.layout.stripFrame.height : snapshot.layout.stripFrame.width) - 2 * snapshot.layout.tabPadding)
        let tabExtent: CGFloat = snapshot.edge.isVertical ? 24 : (snapshot.showsNames ? 156 : 48)
        let ownReserve = snapshot.items.isEmpty ? 0 : min(tabExtent, max(0, (available - 9) / 2)) + 9
        return min(CGFloat(snapshot.otherZoneItems.count) * (tabExtent + 4) - 4, max(0, available - ownReserve))
    }

    private var ownSection: some View {
        Group {
            if snapshot.edge.isVertical {
                VStack(spacing: 4) {
                    if let item = snapshot.items.first { zoneIcon(item).frame(height: 24) }
                    ownTabs
                }
            } else {
                HStack(spacing: 4) {
                    if let item = snapshot.items.first { zoneIcon(item).frame(width: 24) }
                    ownTabs
                }
            }
        }
    }

    private func zoneIcon(_ item: SwitcherItem) -> some View {
        ZoneIconView(frame: item.zoneFrame ?? .full)
            .frame(width: 20, height: 14)
            .help(item.zoneName)
            .accessibilityHidden(false)
            .accessibilityLabel("\(item.zoneName) zone")
    }

    private var ownTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(snapshot.edge.isVertical ? .vertical : .horizontal) {
                if snapshot.edge.isVertical {
                    VStack(spacing: 4) { tabs(snapshot.items, showZoneName: false) }
                } else {
                    HStack(spacing: 4) { tabs(snapshot.items, showZoneName: false) }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: snapshot.items.first?.assignmentID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .topLeading) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var otherTabs: some View {
        ScrollView(snapshot.edge.isVertical ? .vertical : .horizontal) {
            if snapshot.edge.isVertical {
                VStack(spacing: 4) { tabs(snapshot.otherZoneItems, showZoneName: true) }
            } else {
                HStack(spacing: 4) { tabs(snapshot.otherZoneItems, showZoneName: true) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func tabs(_ items: [SwitcherItem], showZoneName: Bool) -> some View {
        ForEach(items, id: \.assignmentID) { item in
            HStack(spacing: 4) {
                if showZoneName { zoneIcon(item) }
                ZoneTabButton(item: item, showZoneName: showZoneName, showsNames: snapshot.showsNames, focus: focus,
                              destinations: snapshot.moveDestinations, sizeAction: snapshot.sizeActions[item.assignmentID],
                              performAction: performAction, beginPress: beginPress)
            }
                .id(item.assignmentID)
                .frame(width: snapshot.edge.isVertical ? nil : (snapshot.showsNames ? 156 : (showZoneName ? 48 : 24)), height: 24)
                .frame(maxWidth: snapshot.edge.isVertical ? .infinity : nil)
                .background(item.isActive ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                // Keep the whole tab in the transparent panel's native input region.
                .background(Color.white.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .help("\(item.zoneName) · \(item.appName) — \(item.title ?? item.appName)")
        }
    }
}

private struct ZoneTabButton: NSViewRepresentable {
    var item: SwitcherItem
    var showZoneName: Bool
    var showsNames: Bool
    var focus: (UUID) -> Void

    var destinations: [Zone]
    var sizeAction: ZoneTabAction?
    var performAction: (UUID, ZoneTabAction) -> Void
    var beginPress: ((UUID, NSEvent, ZoneTabAction?) -> Void)?

    func makeNSView(context: Context) -> ZoneTabNativeButton {
        let button = ZoneTabNativeButton()
        button.cell = ZoneTabButtonCell()
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.wantsLayer = true
        button.layer?.masksToBounds = true
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleNone
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ZoneTabNativeButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 146, height: proposal.height ?? 24)
    }

    func updateNSView(_ button: ZoneTabNativeButton, context: Context) {
        button.assignmentID = item.assignmentID
        button.focus = focus
        button.zoneID = item.zoneID
        button.destinations = destinations
        button.performAction = performAction
        button.sizeAction = sizeAction
        button.beginPress = beginPress
        let title = item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.appName
        let label = showZoneName ? "\(item.zoneName) · \(title)" : title
        let displayedLabel = showsNames ? label : ""
        if button.title != displayedLabel { button.title = displayedLabel }
        button.imagePosition = showsNames ? .imageLeft : .imageOnly
        button.alignment = showsNames ? .left : .center
        if button.sourceIcon !== item.icon || button.image == nil {
            button.sourceIcon = item.icon
            let icon = (item.icon?.copy() as? NSImage) ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            button.image = icon.map { source in
                // Match the switcher's full-height icon crop, cached until the source changes.
                NSImage(size: CGSize(width: 24, height: 24), flipped: false) { bounds in
                    source.draw(in: bounds.insetBy(dx: -bounds.width * 0.09, dy: -bounds.height * 0.09))
                    return true
                }
            }
        }
        button.toolTip = "\(item.zoneName) · \(item.appName) — \(title)"
        button.setAccessibilityLabel("\(item.zoneName), \(item.appName), \(title)")
        button.setAccessibilityValue(item.isActive ? "Selected" : "")
    }
}

// NSButtonCell adds its own image inset; tab icons should touch the item edge.
final class ZoneTabButtonCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let textFrame = CGRect(x: controlView.bounds.minX + 30, y: frame.minY,
                               width: max(0, controlView.bounds.width - 36), height: frame.height)
        return super.drawTitle(title, withFrame: textFrame, in: controlView)
    }


    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        image.draw(in: CGRect(x: controlView.bounds.minX, y: controlView.bounds.midY - 12, width: 24, height: 24),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// Commit the exact target at mouse-down; an MRU redraw during mouse-up cannot select its neighbor.
final class ZoneTabNativeButton: NSButton {
    var sourceIcon: NSImage?
    var assignmentID: UUID?
    var focus: ((UUID) -> Void)?
    var zoneID: ZoneID?
    var destinations: [Zone] = []
    var sizeAction: ZoneTabAction?
    var performAction: ((UUID, ZoneTabAction) -> Void)?
    var beginPress: ((UUID, NSEvent, ZoneTabAction?) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        if let assignmentID {
            if let beginPress { beginPress(assignmentID, event, sizeAction) }
            else if event.clickCount == 2, let sizeAction { performAction?(assignmentID, sizeAction) }
            else { focus?(assignmentID) }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        guard let window, let menu = menu(for: event) else { return }
        // A view-attached context menu raises the entire backing frame over its native windows.
        menu.popUp(positioning: nil, at: window.convertPoint(toScreen: event.locationInWindow), in: nil)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let assignmentID else { return nil }
        let menu = NSMenu()
        for zone in destinations where zone.id != zoneID {
            let performAction = self.performAction
            let item = ZoneTabMenuItem(title: "Move to \(ZoneNameResolver().name(for: zone.id, in: destinations))") {
                performAction?(assignmentID, .move(zone.id))
            }
            let renderer = ImageRenderer(content: ZoneIconView(frame: zone.frame, fill: .primary)
                .frame(width: 20, height: 14))
            renderer.scale = 2
            item.image = renderer.nsImage
            item.image?.isTemplate = true
            menu.addItem(item)
        }
        if let sizeAction {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let performAction = self.performAction
            let fit = sizeAction == .fit
            let item = ZoneTabMenuItem(title: fit ? ZoneTabAction.fit.title : ZoneTabAction.restoreCustom.title) {
                performAction?(assignmentID, sizeAction)
            }
            item.image = NSImage(systemSymbolName: fit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let performAction = self.performAction
        let close = ZoneTabMenuItem(title: ZoneTabAction.close.title) { performAction?(assignmentID, .close) }
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        menu.addItem(close)
        return menu
    }

    override func accessibilityPerformPress() -> Bool {
        guard let assignmentID else { return false }
        focus?(assignmentID)
        return true
    }
}

// Keep the selected window and action alive even if the tab redraws while the menu is open.
final class ZoneTabMenuItem: NSMenuItem {
    private let actionHandler: () -> Void

    init(title: String, actionHandler: @escaping () -> Void) {
        self.actionHandler = actionHandler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func invoke() { actionHandler() }
}

// Preserve the original mouse-down target through MRU redraws and AppKit's second click.
@MainActor
final class ZoneTabInteractionController {
    private struct Press {
        var id: UUID
        var point: CGPoint
        var timestamp: TimeInterval
        var sizeAction: ZoneTabAction?
        var dragged = false
        var plan: ZoneTabDragPlan?
    }
    private let focus: (UUID) -> Void
    private let performAction: (UUID, ZoneTabAction) -> Void
    private let prepareDrag: (UUID) -> ZoneTabDragPlan?
    private let preview: (ZoneTabDragPlan?, CGPoint?) -> Void
    private var pressed: Press?
    private var lastClick: Press?
    var isActive: Bool { pressed != nil }

    init(focus: @escaping (UUID) -> Void, performAction: @escaping (UUID, ZoneTabAction) -> Void,
         prepareDrag: @escaping (UUID) -> ZoneTabDragPlan?,
         preview: @escaping (ZoneTabDragPlan?, CGPoint?) -> Void) {
        self.focus = focus; self.performAction = performAction
        self.prepareDrag = prepareDrag; self.preview = preview
    }

    func press(id: UUID, point: CGPoint, timestamp: TimeInterval, clickCount: Int, sizeAction: ZoneTabAction?) {
        pressed = nil
        preview(nil, nil)
        if clickCount == 2, let original = lastClick,
           timestamp >= original.timestamp, timestamp - original.timestamp <= NSEvent.doubleClickInterval,
           hypot(point.x - original.point.x, point.y - original.point.y) <= 5 {
            lastClick = nil
            if let action = original.sizeAction { performAction(original.id, action) }
            else { focus(original.id) }
            return
        }
        let press = Press(id: id, point: point, timestamp: timestamp, sizeAction: sizeAction)
        pressed = press
        lastClick = press
        focus(id)
    }

    @discardableResult
    func pointer(_ type: CGEventType, at point: CGPoint) -> Bool {
        guard var press = pressed, type == .leftMouseDragged || type == .leftMouseUp else { return false }
        if type == .leftMouseDragged {
            if !press.dragged, hypot(point.x - press.point.x, point.y - press.point.y) >= 5 {
                press.dragged = true
                press.plan = prepareDrag(press.id)
                lastClick = nil
            }
            pressed = press
            if let plan = press.plan { preview(plan, point) }
        } else {
            pressed = nil
            preview(nil, nil)
            // A profile, display, geometry or identity change invalidates the captured preview.
            if let plan = press.plan, prepareDrag(press.id) == plan, let zone = plan.destination(at: point) {
                performAction(press.id, .move(zone))
            }
        }
        return true
    }

    @discardableResult
    func cancel() -> Bool {
        let active = isActive
        pressed = nil; lastClick = nil
        preview(nil, nil)
        return active
    }
}
