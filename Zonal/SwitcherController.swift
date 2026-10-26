import AppKit
import Observation
import OSLog
import SwiftUI

struct SwitcherPresentationContent: Equatable {
    var model: WorkspaceSnapshotModel
    var filterQuery: String
    var unfilteredItemCounts: [ZoneID: Int]
    var animateEntrance: Bool
    var presentationToken: Int
    var renderToken: Int
    var hoverResetToken: Int
    var pointerLocationAtHoverReset: CGPoint
}

struct SwitcherLatencySample: Codable, Equatable {
    enum Operation: String, Codable {
        case openPrepared
        case firstDraw
        case cyclePrepared
        case cycleDraw
    }

    enum Path: String, Codable {
        case cold
        case warm
    }

    var operation: Operation
    var path: Path
    var milliseconds: Double
}

@MainActor
@Observable
final class SwitcherPresentationState {
    var content: SwitcherPresentationContent
    var isActive = true

    init(content: SwitcherPresentationContent) {
        self.content = content
    }
}

@MainActor
final class SwitcherController {
    private static let performanceLog = OSLog(
        subsystem: "com.sebmarste.zonal",
        category: .pointsOfInterest
    )

    private let workspaceState: WorkspaceStateService
    private(set) var window: NSWindow?
    private var hostingView: NSHostingView<SwitcherView>?
    private var presentationState: SwitcherPresentationState?
    private var sessionModel: WorkspaceSnapshotModel?
    private(set) var isVisible = false
    private(set) var mode: SwitcherMode = .allWindows
    private(set) var filterQuery = ""
    private var hoverResetToken = 0
    private var presentationToken = 0
    private var renderToken = 0
    private var pendingDrawMeasurements: [Int: PendingDrawMeasurement] = [:]
    private var latencySamples: [SwitcherLatencySample] = []
    private var pointerLocationAtHoverReset = CGPoint.zero
    private var isPresentationDismissed = false
    private var defersPresentation = false
    private var deferredPresentation: (resetSelection: Bool, measurement: PendingDrawMeasurement?)?
    var onHide: (() -> Void)?
    var onShow: (() -> Void)?

    init(workspaceState: WorkspaceStateService) {
        self.workspaceState = workspaceState
        workspaceState.onWindowsChanged = { [weak self] in
            guard let self else { return }
            if self.isVisible {
                self.refreshSessionAndRender(resetSelection: false)
            }
        }
    }

    func show(mode: SwitcherMode, reverse: Bool = false) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let path: SwitcherLatencySample.Path = presentationToken == 0 ? .cold : .warm
        self.mode = mode
        filterQuery = ""
        isVisible = true
        isPresentationDismissed = false
        presentationToken &+= 1
        resetHoverInteraction()
        sessionModel = workspaceState.refreshSwitcherSnapshot(
            mode: mode,
            resetSelection: true
        )
        if reverse {
            selectRelativeSessionWindow(direction: -2)
        }
        renderSession(
            resetSelection: true,
            drawMeasurement: PendingDrawMeasurement(
                operation: .firstDraw,
                path: path,
                startedAt: startedAt
            )
        )
        recordLatency(.openPrepared, path: path, since: startedAt, signpost: "SwitcherOpen")
        onShow?()
    }

    func next() {
        guard isVisible else {
            show(mode: mode)
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        selectRelativeSessionWindow(direction: 1)
        resetHoverInteraction()
        renderSession(
            resetSelection: false,
            drawMeasurement: PendingDrawMeasurement(
                operation: .cycleDraw,
                path: .warm,
                startedAt: startedAt
            )
        )
        recordLatency(.cyclePrepared, path: .warm, since: startedAt, signpost: "SwitcherCycle")
    }

    func previous() {
        guard isVisible else {
            show(mode: mode)
            return
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        selectRelativeSessionWindow(direction: -1)
        resetHoverInteraction()
        renderSession(
            resetSelection: false,
            drawMeasurement: PendingDrawMeasurement(
                operation: .cycleDraw,
                path: .warm,
                startedAt: startedAt
            )
        )
        recordLatency(.cyclePrepared, path: .warm, since: startedAt, signpost: "SwitcherCycle")
    }

    func moveVerticalWindow(direction: Int) {
        guard isVisible else { return }
        if filterQuery.isEmpty {
            guard let sessionModel else { return }
            self.sessionModel = workspaceState.selectVerticalWindow(
                direction: direction,
                model: sessionModel
            )
        } else {
            selectRelativeSessionWindow(direction: direction)
        }
        resetHoverInteraction()
        renderSession(resetSelection: false)
    }

    func moveZone(direction: SwitcherArrowKey) {
        guard isVisible else { return }
        if filterQuery.isEmpty {
            guard let sessionModel else { return }
            self.sessionModel = workspaceState.selectZone(in: direction, model: sessionModel)
        } else {
            selectRelativeSessionWindow(
                direction: direction == .left || direction == .up ? -1 : 1
            )
        }
        resetHoverInteraction()
        renderSession(resetSelection: false)
    }

    func assignZone(direction: SwitcherArrowKey) {
        guard isVisible else { return }
        workspaceState.assignSelectedWindowToZone(in: direction, model: sessionModel)
        resetHoverInteraction()
        refreshSessionAndRender(resetSelection: false)
    }

    func confirm() {
        guard isVisible else { return }
        let model = displayedModel
        guard model.selectedWindowID != nil else {
            hide()
            return
        }
        hide()
        workspaceState.focusSelectedWindow(fromSwitcher: true)
    }

    func suspend() { hide() }

    func cancel() {
        if !filterQuery.isEmpty {
            filterQuery = ""
            resetHoverInteraction()
            renderSession(resetSelection: false)
            return
        }
        hide()
    }

    func appendFilter(_ text: String) {
        guard isVisible else { return }
        filterQuery.append(contentsOf: text)
        resetHoverInteraction()
        renderSession(resetSelection: false)
    }

    func deleteFilterCharacter() {
        guard isVisible else { return }
        if !filterQuery.isEmpty {
            filterQuery.removeLast()
        }
        resetHoverInteraction()
        renderSession(resetSelection: false)
    }

    func dismissPresentation() {
        isPresentationDismissed = true
        presentationState?.isActive = false
        pendingDrawMeasurements.removeAll(keepingCapacity: true)
        window?.orderOut(nil)
        window?.contentView = nil
        os_log(.info, log: Self.performanceLog, "handoff.stage=presentationDismissed uptime=%.9f",
               ProcessInfo.processInfo.systemUptime)
    }

    // Warm once, then keep the immutable tree detached until it is actually shown.
    func preparePresentation() {
        guard hostingView == nil, !isVisible else { return }
        let model = workspaceState.switcherSnapshot(mode: .allWindows)
        let content = SwitcherPresentationContent(model: model, filterQuery: "",
            unfilteredItemCounts: Dictionary(uniqueKeysWithValues: model.zones.map { ($0.id, $0.items.count) }),
            animateEntrance: false, presentationToken: presentationToken, renderToken: renderToken,
            hoverResetToken: hoverResetToken, pointerLocationAtHoverReset: pointerLocationAtHoverReset)
        let panel = window ?? makeWindow()
        updateHostingView(content: content, in: panel)
        hostingView?.layoutSubtreeIfNeeded()
        presentationState?.isActive = false
        panel.contentView = nil
        window = panel
    }

    // Only coalesce commands already delivered; never wait for another input or a timer.
    func performPresentationBatch(_ commands: () -> Void) {
        defersPresentation = true
        commands()
        defersPresentation = false
        let pending = deferredPresentation
        deferredPresentation = nil
        if let pending {
            renderSession(resetSelection: pending.resetSelection, drawMeasurement: pending.measurement)
        }
    }

    private func hide() {
        isVisible = false
        dismissPresentation()
        filterQuery = ""
        sessionModel = nil
        onHide?()
    }

    private func refreshSessionAndRender(resetSelection: Bool) {
        sessionModel = workspaceState.refreshSwitcherSnapshot(
            mode: mode,
            resetSelection: resetSelection
        )
        renderSession(resetSelection: resetSelection)
    }

    private func renderSession(
        resetSelection: Bool,
        drawMeasurement: PendingDrawMeasurement? = nil
    ) {
        guard isVisible else { return }
        guard var sessionModel else { return }
        var model = SwitcherFilterPolicy().filtered(sessionModel, query: filterQuery)
        synchronizeSelection(with: model)
        sessionModel = workspaceState.projectSelection(onto: sessionModel)
        self.sessionModel = sessionModel
        model = SwitcherFilterPolicy().filtered(sessionModel, query: filterQuery)
        guard !isPresentationDismissed else { return }
        if defersPresentation {
            deferredPresentation = (
                resetSelection || deferredPresentation?.resetSelection == true,
                drawMeasurement ?? deferredPresentation?.measurement
            )
            return
        }
        let overlayWindow = window ?? makeWindow()
        overlayWindow.setFrame(Self.overlayFrame(), display: false)
        renderToken &+= 1
        if let drawMeasurement {
            pendingDrawMeasurements[renderToken] = drawMeasurement
        }
        let content = SwitcherPresentationContent(
            model: model,
            filterQuery: filterQuery,
            unfilteredItemCounts: Dictionary(
                uniqueKeysWithValues: sessionModel.zones.map { ($0.id, $0.items.count) }
            ),
            animateEntrance: resetSelection,
            presentationToken: presentationToken,
            renderToken: renderToken,
            hoverResetToken: hoverResetToken,
            pointerLocationAtHoverReset: pointerLocationAtHoverReset
        )
        updateHostingView(content: content, in: overlayWindow)
        overlayWindow.orderFrontRegardless()
        window = overlayWindow
    }

    private func updateHostingView(content: SwitcherPresentationContent, in overlayWindow: NSWindow) {
        if SwitcherHostingReusePolicy().shouldCreateHostingView(
            hasHostingView: hostingView != nil,
            hasPresentationState: presentationState != nil
        ) {
            let presentationState = SwitcherPresentationState(content: content)
            let rootView = makeRootView(presentationState: presentationState)
            let hostingView = NSHostingView(rootView: rootView)
            hostingView.sizingOptions = []
            overlayWindow.contentView = hostingView
            self.presentationState = presentationState
            self.hostingView = hostingView
        } else {
            presentationState?.isActive = true
            presentationState?.content = content
            if overlayWindow.contentView !== hostingView { overlayWindow.contentView = hostingView }
        }
    }

    private func makeRootView(presentationState: SwitcherPresentationState) -> SwitcherView {
        let rootView = SwitcherView(
            presentation: presentationState,
            onSelectZone: { [weak self] zoneID in
                self?.workspaceState.selectZone(zoneID)
            },
            onConfirmWindow: { [weak self] identity, zoneID in
                guard let self else { return }
                if let item = self.displayedModel.zones.flatMap(\.items).first(where: {
                    $0.identity == identity
                }) {
                    self.workspaceState.selectSwitcherItem(
                        assignmentID: item.assignmentID,
                        zoneID: zoneID
                    )
                } else {
                    self.workspaceState.selectWindow(identity, in: zoneID)
                }
                self.confirm()
            },
            onFirstDraw: { [weak self] renderToken in
                self?.recordFirstDraw(renderToken: renderToken)
            }
        )
        return rootView
    }

    private var displayedModel: WorkspaceSnapshotModel {
        guard let sessionModel else {
            return WorkspaceSnapshotModel(
                mode: mode,
                zones: [],
                zoneColumns: [],
                selectedZoneID: .main,
                selectedWindowID: nil
            )
        }
        return SwitcherFilterPolicy().filtered(sessionModel, query: filterQuery)
    }

    private func synchronizeSelection(with model: WorkspaceSnapshotModel) {
        guard !filterQuery.isEmpty,
              let identity = model.selectedWindowID,
              let item = model.zones.flatMap(\.items).first(where: { $0.identity == identity }) else {
            return
        }
        workspaceState.selectSwitcherItem(
            assignmentID: item.assignmentID,
            zoneID: item.zoneID
        )
    }

    private func selectRelativeSessionWindow(direction: Int) {
        guard let sessionModel else { return }
        if filterQuery.isEmpty {
            self.sessionModel = workspaceState.selectRelativeWindow(
                direction: direction,
                model: sessionModel
            )
            return
        }
        let model = displayedModel
        let items = model.zones.flatMap(\.items)
        guard !items.isEmpty else { return }
        let currentIndex = model.selectedWindowID.flatMap { selectedIdentity in
            items.firstIndex { $0.identity == selectedIdentity }
        } ?? 0
        let nextIndex = (currentIndex + direction + items.count) % items.count
        let next = items[nextIndex]
        workspaceState.selectSwitcherItem(
            assignmentID: next.assignmentID,
            zoneID: next.zoneID
        )
        self.sessionModel = workspaceState.projectSelection(onto: sessionModel)
    }

    private func resetHoverInteraction() {
        hoverResetToken &+= 1
        pointerLocationAtHoverReset = NSEvent.mouseLocation
    }

    func performanceSamples() -> [SwitcherLatencySample] {
        latencySamples
    }

    func clearPerformanceSamples() {
        latencySamples.removeAll(keepingCapacity: true)
        pendingDrawMeasurements.removeAll(keepingCapacity: true)
    }

    private struct PendingDrawMeasurement {
        var operation: SwitcherLatencySample.Operation
        var path: SwitcherLatencySample.Path
        var startedAt: TimeInterval
    }

    private func recordFirstDraw(renderToken: Int) {
        guard let measurement = pendingDrawMeasurements.removeValue(forKey: renderToken) else { return }
        recordLatency(
            measurement.operation,
            path: measurement.path,
            since: measurement.startedAt,
            signpost: measurement.operation == .firstDraw
                ? "SwitcherFirstDraw"
                : "SwitcherCycleDraw"
        )
        pendingDrawMeasurements = pendingDrawMeasurements.filter { $0.key > renderToken }
    }

    private func recordLatency(
        _ operation: SwitcherLatencySample.Operation,
        path: SwitcherLatencySample.Path,
        since startedAt: TimeInterval,
        signpost: StaticString
    ) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        latencySamples.append(SwitcherLatencySample(
            operation: operation,
            path: path,
            milliseconds: milliseconds
        ))
        if latencySamples.count > 200 {
            latencySamples.removeFirst(latencySamples.count - 200)
        }
        Self.recordLatency(signpost, milliseconds: milliseconds)
    }

    private static func recordLatency(_ name: StaticString, milliseconds: Double) {
        os_signpost(
            .event,
            log: performanceLog,
            name: name,
            "latency_ms=%{public}.2f",
            milliseconds
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: Self.overlayFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isFloatingPanel = true
        window.animationBehavior = .none
        return window
    }

    private static func overlayFrame() -> CGRect {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return PointerScreenSelectionPolicy().visibleFrame(
            containing: NSEvent.mouseLocation,
            candidates: NSScreen.screens.map {
                ScreenFrameCandidate(frame: $0.frame, visibleFrame: $0.visibleFrame)
            },
            fallback: fallback
        )
    }
}

struct SwitcherView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var presentation: SwitcherPresentationState
    var onSelectZone: (ZoneID) -> Void
    var onConfirmWindow: (WindowIdentity, ZoneID) -> Void
    var onFirstDraw: (Int) -> Void

    @State private var selectedZoneID: ZoneID
    @State private var selectedWindowID: WindowIdentity?
    @State private var hoveredWindowID: WindowIdentity?
    @State private var entranceAnimationReady: Bool

    init(
        presentation: SwitcherPresentationState,
        onSelectZone: @escaping (ZoneID) -> Void = { _ in },
        onConfirmWindow: @escaping (WindowIdentity, ZoneID) -> Void = { _, _ in },
        onFirstDraw: @escaping (Int) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.onSelectZone = onSelectZone
        self.onConfirmWindow = onConfirmWindow
        self.onFirstDraw = onFirstDraw
        let content = presentation.content
        let model = content.model
        _selectedZoneID = State(initialValue: model.selectedZoneID)
        _selectedWindowID = State(initialValue: content.animateEntrance
            ? Self.openingWindowIdentity(in: model)
            : model.selectedWindowID)
        _entranceAnimationReady = State(initialValue: !content.animateEntrance)
    }

    private var content: SwitcherPresentationContent { presentation.content }
    private var model: WorkspaceSnapshotModel { content.model }
    private var filterQuery: String { content.filterQuery }
    private var unfilteredItemCounts: [ZoneID: Int] { content.unfilteredItemCounts }
    private var animateEntrance: Bool { content.animateEntrance }
    private var presentationToken: Int { content.presentationToken }
    private var renderToken: Int { content.renderToken }
    private var hoverResetToken: Int { content.hoverResetToken }
    private var pointerLocationAtHoverReset: CGPoint { content.pointerLocationAtHoverReset }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if filterQuery.isEmpty,
                   model.mode == .allWindows,
                   model.zones.allSatisfy(\.items.isEmpty) {
                    ContentUnavailableView(
                        "No Managed Windows",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text("Open a window or grant Accessibility permission.")
                    )
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    islandLayout(in: geometry.size)
                        .overlay(alignment: .top) {
                            if !filterQuery.isEmpty {
                                filterPanel(width: min(400, max(1, geometry.size.width - 104)))
                                    .offset(y: -56)
                            }
                        }
                    .padding(.top, filterQuery.isEmpty ? 0 : 56)
                    .padding(.bottom, model.showSwitcherShortcutGuide ? (model.mode == .allWindows ? 118 : 148) : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                    if model.showSwitcherShortcutGuide {
                        footer
                            .padding(.bottom, 18)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .modifier(SwitcherEntranceEffect(
                                isEnabled: shouldAnimateEntrance,
                                isVisible: entranceAnimationReady,
                                verticalOffset: 12
                            ))
                    }
                }
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SwitcherFirstDrawProbe(token: renderToken, onFirstDraw: onFirstDraw)
                .allowsHitTesting(false)
        }
        .onChange(of: model.selectedZoneID) { _, newValue in
            selectedZoneID = newValue
        }
        .onChange(of: model.selectedWindowID) { _, newValue in
            withAnimation(selectionAnimation) {
                selectedWindowID = newValue
            }
        }
        .onChange(of: hoverResetToken) { _, _ in
            hoveredWindowID = nil
        }
        .onChange(of: presentationToken) { _, _ in
            beginEntranceAnimation()
        }
        .onChange(of: visibleWindowIDs) { _, identities in
            if let hoveredWindowID, !identities.contains(hoveredWindowID) {
                self.hoveredWindowID = nil
            }
        }
        .onAppear {
            beginEntranceAnimation()
        }
    }

    private func islandLayout(in size: CGSize) -> some View {
        let metrics = SwitcherScreenLayoutMetrics(
            availableSize: size,
            columnZoneCounts: displayColumns.map(\.count),
            mode: model.mode,
            isFiltering: !filterQuery.isEmpty,
            showsShortcutGuide: model.showSwitcherShortcutGuide
        )
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .center, spacing: metrics.columnSpacing) {
                    ForEach(Array(displayColumns.enumerated()), id: \.offset) { index, zoneIDs in
                        VStack(spacing: metrics.zoneSpacing) {
                            ForEach(zones(in: zoneIDs)) { zone in
                                islandView(
                                    for: zone,
                                    width: metrics.islandWidth,
                                    maximumListHeight: metrics.maximumListHeight(column: index)
                                )
                                .id(zone.id)
                            }
                        }
                    }
                }
                // Include the existing surface shadows and card effects in the scroll footprint.
                .padding(metrics.effectOutset)
                .frame(minWidth: metrics.viewportSize.width, minHeight: metrics.viewportSize.height)
            }
            .frame(width: metrics.viewportSize.width, height: metrics.viewportSize.height)
            .onChange(of: selectedZoneID) { _, zoneID in
                proxy.scrollTo(zoneID, anchor: .center)
            }
            .onAppear { proxy.scrollTo(selectedZoneID, anchor: .center) }
        }
    }

    private func zones(in zoneIDs: [ZoneID]) -> [SwitcherZone] {
        zoneIDs.compactMap { zoneID in model.zones.first { $0.id == zoneID } }
    }

    private func islandView(for zone: SwitcherZone, width: CGFloat, maximumListHeight: CGFloat) -> some View {
        SwitcherZoneIsland(
            zone: zone,
            mode: model.mode,
            isFiltering: !filterQuery.isEmpty,
            maximumListHeight: maximumListHeight,
            isSelectedZone: zone.id == selectedZoneID,
            outlineStyle: model.outlineStyle,
            selectedWindowID: selectedWindowID,
            hoveredWindowID: hoveredWindowID,
            onSelectZone: {
                hoveredWindowID = nil
                withAnimation(selectionAnimation) {
                    selectedZoneID = zone.id
                    selectedWindowID = zone.items.first?.identity
                }
                onSelectZone(zone.id)
            },
            onHoverWindow: { identity, isHovering in
                updateHoveredWindow(identity, isHovering: isHovering)
            },
            onConfirmWindow: { identity in
                selectedZoneID = zone.id
                selectedWindowID = identity
                onConfirmWindow(identity, zone.id)
            }
        )
        .frame(width: width)
        .frame(
            height: filterQuery.isEmpty
                ? nil
                : min(maximumListHeight, SwitcherListMetrics().height(
                    forItemCount: unfilteredItemCounts[zone.id] ?? zone.items.count
                )) + (model.mode == .byZone ? 33 : 0),
            alignment: .top
        )
        .modifier(SwitcherEntranceEffect(
            isEnabled: shouldAnimateEntrance
                && model.mode == .byZone
                && zone.id != selectedZoneID,
            isVisible: entranceAnimationReady,
            verticalOffset: 8
        ))
    }

    private var visibleWindowIDs: [WindowIdentity] {
        model.zones.flatMap(\.items).map(\.identity)
    }

    private func updateHoveredWindow(_ identity: WindowIdentity, isHovering: Bool) {
        if isHovering {
            guard SwitcherHoverActivationPolicy().shouldActivate(
                pointerLocation: NSEvent.mouseLocation,
                since: pointerLocationAtHoverReset
            ) else {
                return
            }
            hoveredWindowID = identity
        } else if hoveredWindowID == identity {
            hoveredWindowID = nil
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            shortcutHints
            ScrollView(.horizontal) {
                shortcutHints
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.24), radius: 20, y: 10)
        }
    }

    private var shortcutHints: some View {
        HStack(spacing: 12) {
            SwitcherShortcutHint(
                keys: model.nextWindowShortcutKeys,
                label: "Next window"
            )
            SwitcherShortcutHint(keys: ["Return"], label: "Switch")
            SwitcherShortcutHint(
                keys: ["Esc"],
                label: filterQuery.isEmpty ? "Close" : "Clear filter"
            )
            SwitcherShortcutHint(keys: ["Type"], label: "Search")
            if model.mode == .allWindows {
                SwitcherShortcutHint(keys: ["↑", "↓"], label: "Window")
            } else {
                SwitcherShortcutHint(keys: ["↑", "↓"], label: "Window stack")
                SwitcherShortcutHint(keys: ["←", "→"], label: "Zone")
                SwitcherShortcutHint(keys: ["Shift", "Arrows"], label: "Move")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func filterPanel(width: CGFloat) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(filterQuery)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("\(filteredItemCount)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(width: width, height: 42)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.24), radius: 18, y: 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Window filter")
        .accessibilityValue("\(filterQuery), \(filteredItemCount) matches")
    }

    private var filteredItemCount: Int {
        model.zones.reduce(0) { $0 + $1.items.count }
    }

    private var displayColumns: [[ZoneID]] {
        model.zoneColumns.isEmpty ? [model.zones.map(\.id)] : model.zoneColumns
    }

    private var shouldAnimateEntrance: Bool {
        animateEntrance && !reduceMotion
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.10, extraBounce: 0)
    }

    private func beginEntranceAnimation() {
        guard presentation.isActive else { return }
        selectedZoneID = model.selectedZoneID
        hoveredWindowID = nil
        guard shouldAnimateEntrance else {
            entranceAnimationReady = true
            selectedWindowID = model.selectedWindowID
            return
        }
        entranceAnimationReady = false
        selectedWindowID = Self.openingWindowIdentity(in: model)
        let token = presentationToken
        DispatchQueue.main.async {
            guard presentation.isActive, token == presentationToken else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                entranceAnimationReady = true
            }
            withAnimation(selectionAnimation) {
                selectedWindowID = model.selectedWindowID
            }
        }
    }

    private static func openingWindowIdentity(in model: WorkspaceSnapshotModel) -> WindowIdentity? {
        if model.mode == .byZone {
            let selectedZone = model.zones.first { $0.id == model.selectedZoneID }
            return selectedZone?.items.first(where: \.isActive)?.identity
                ?? selectedZone?.items.first?.identity
                ?? model.selectedWindowID
        }
        return model.zones.first?.items.first?.identity ?? model.selectedWindowID
    }
}

private struct SwitcherFirstDrawProbe: NSViewRepresentable {
    var token: Int
    var onFirstDraw: (Int) -> Void

    func makeNSView(context: Context) -> SwitcherFirstDrawProbeView {
        let view = SwitcherFirstDrawProbeView()
        view.update(token: token, onFirstDraw: onFirstDraw)
        return view
    }

    func updateNSView(_ nsView: SwitcherFirstDrawProbeView, context: Context) {
        nsView.update(token: token, onFirstDraw: onFirstDraw)
    }
}

private final class SwitcherFirstDrawProbeView: NSView {
    private var token = 0
    private var reportedToken = 0
    private var onFirstDraw: ((Int) -> Void)?

    override var isOpaque: Bool { false }

    func update(token: Int, onFirstDraw: @escaping (Int) -> Void) {
        self.token = token
        self.onFirstDraw = onFirstDraw
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.isVisible == true, token != reportedToken else { return }
        reportedToken = token
        onFirstDraw?(token)
    }
}

private struct SwitcherEntranceEffect: ViewModifier {
    var isEnabled: Bool
    var isVisible: Bool
    var verticalOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isEnabled && !isVisible ? 0 : 1)
            .scaleEffect(isEnabled && !isVisible ? 0.97 : 1)
            .offset(y: isEnabled && !isVisible ? verticalOffset : 0)
    }
}

struct SwitcherZoneIsland: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let listMetrics = SwitcherListMetrics()

    @State private var itemFrames: [WindowIdentity: CGRect] = [:]
    var zone: SwitcherZone
    var mode: SwitcherMode
    var isFiltering: Bool
    var maximumListHeight: CGFloat = .greatestFiniteMagnitude
    var isSelectedZone: Bool
    var outlineStyle = WindowOutlineStyle()
    var selectedWindowID: WindowIdentity?
    var hoveredWindowID: WindowIdentity?
    var onSelectZone: () -> Void
    var onHoverWindow: (WindowIdentity, Bool) -> Void
    var onConfirmWindow: (WindowIdentity) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .byZone {
                header
                    .padding(.top, listMetrics.contentInset)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: listMetrics.rowSpacing) {
                        if zone.items.isEmpty {
                            emptyState
                        } else {
                            ForEach(zone.items) { item in
                                SwitcherIslandWindowCard(
                                    item: item,
                                    mode: mode,
                                    isSelected: item.identity == selectedWindowID,
                                    isHovered: item.identity == hoveredWindowID,
                                    onHoverChange: { isHovering in
                                        onHoverWindow(item.identity, isHovering)
                                    },
                                    onConfirm: {
                                        onConfirmWindow(item.identity)
                                    }
                                )
                                .id(item.identity)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: SwitcherItemFramePreferenceKey.self,
                                            value: [
                                                item.identity: geometry.frame(
                                                    in: .named(scrollCoordinateSpaceName)
                                                )
                                            ]
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, listMetrics.contentInset)
                    .padding(.horizontal, SwitcherCardEffectMetrics.outset)
                }
                .coordinateSpace(name: scrollCoordinateSpaceName)
                .scrollIndicators(.hidden)
                .frame(height: listHeight)
                .padding(.horizontal, -SwitcherCardEffectMetrics.outset)
                .onPreferenceChange(SwitcherItemFramePreferenceKey.self) { frames in
                    itemFrames = frames
                }
                .onChange(of: selectedWindowID) { _, newValue in
                    scrollSelectionIntoView(newValue, proxy: proxy)
                }
            }
        }
        .padding(.horizontal, listMetrics.contentInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.30), radius: 24, y: 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isSelectedZone ? Color(outlineStyle.color.nsColor) : Color.clear,
                    lineWidth: outlineStyle.zoneWidth
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onSelectZone()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(zone.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if mode == .byZone {
                ZoneIconView(frame: zone.frame)
                    .frame(width: 30, height: 19)
            }
        }
    }

    private var emptyState: some View {
        Text(
            isFiltering
                ? "No matches"
                : mode == .byZone
                    ? "No windows · Shift-Arrow moves a window here"
                    : "No windows"
        )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var listHeight: CGFloat {
        min(maximumListHeight, listMetrics.height(forItemCount: zone.items.count))
    }

    private var scrollCoordinateSpaceName: String {
        "switcher-list-\(zone.id.rawValue)"
    }

    private func scrollSelectionIntoView(
        _ identity: WindowIdentity?,
        proxy: ScrollViewProxy
    ) {
        guard let identity,
              zone.items.contains(where: { $0.identity == identity }) else {
            return
        }
        guard let frame = itemFrames[identity] else {
            scroll(identity, to: .center, proxy: proxy)
            return
        }
        let visibleTop = listMetrics.contentInset
        let visibleBottom = listHeight - listMetrics.contentInset
        let anchorInset = min(
            0.5,
            listMetrics.contentInset / max(1, listHeight - frame.height)
        )
        if frame.minY < visibleTop {
            scroll(
                identity,
                to: UnitPoint(x: 0.5, y: anchorInset),
                proxy: proxy
            )
        } else if frame.maxY > visibleBottom {
            scroll(
                identity,
                to: UnitPoint(x: 0.5, y: 1 - anchorInset),
                proxy: proxy
            )
        }
    }

    private func scroll(
        _ identity: WindowIdentity,
        to anchor: UnitPoint,
        proxy: ScrollViewProxy
    ) {
        if reduceMotion {
            proxy.scrollTo(identity, anchor: anchor)
        } else {
            withAnimation(.easeOut(duration: 0.09)) {
                proxy.scrollTo(identity, anchor: anchor)
            }
        }
    }
}

struct SwitcherScreenLayoutMetrics {
    var availableSize: CGSize
    var columnZoneCounts: [Int]
    var mode: SwitcherMode
    var isFiltering: Bool
    var showsShortcutGuide = true
    let columnSpacing: CGFloat = 30
    let zoneSpacing: CGFloat = 20
    let effectOutset: CGFloat = 40

    var viewportSize: CGSize {
        CGSize(
            width: max(1, availableSize.width - 24),
            height: max(1, availableSize.height - (showsShortcutGuide ? (mode == .allWindows ? 150 : 180) : 32) - (isFiltering ? 56 : 0))
        )
    }

    var islandWidth: CGFloat {
        let count = CGFloat(max(1, columnZoneCounts.count))
        let preferred: CGFloat = mode == .allWindows ? 520 : count == 1 ? 400 : 280
        let fitted = (viewportSize.width - effectOutset * 2 - columnSpacing * (count - 1)) / count
        return max(1, min(preferred, max(min(220, viewportSize.width - effectOutset * 2), fitted)))
    }

    func maximumListHeight(column: Int) -> CGFloat {
        let count = CGFloat(max(1, columnZoneCounts[column]))
        let header: CGFloat = mode == .byZone ? 33 : 0
        let fitted = (viewportSize.height - effectOutset * 2 - zoneSpacing * (count - 1)) / count - header
        // Many zones use outer scrolling; each list still exposes at least one complete row.
        return max(SwitcherListMetrics().height(forItemCount: 1), fitted)
    }
}

struct SwitcherListMetrics: Equatable {
    var rowHeight: CGFloat = 54
    var rowSpacing: CGFloat = 8
    var maximumVisibleRows: CGFloat = 7.5
    var emptyHeight: CGFloat = 40
    var contentInset: CGFloat = 14
    var zoneHeaderHeight: CGFloat = 19

    func height(forItemCount itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return emptyHeight + contentInset * 2 }
        let count = CGFloat(itemCount)
        let contentHeight = count * rowHeight + max(0, count - 1) * rowSpacing
        let maximumHeight = maximumVisibleRows * rowHeight
            + max(0, maximumVisibleRows - 1) * rowSpacing
        return min(contentHeight, maximumHeight) + contentInset * 2
    }

    func islandHeight(forItemCount itemCount: Int, includesZoneHeader: Bool) -> CGFloat {
        height(forItemCount: itemCount)
            + (includesZoneHeader ? contentInset + zoneHeaderHeight : 0)
    }
}

private enum SwitcherCardEffectMetrics {
    static let outset: CGFloat = 32
    static let selectedScale: CGFloat = 1.025
}

struct SwitcherCardSelectionMetrics: Equatable {
    static let rowHeight: CGFloat = 54
    static let cornerRadius: CGFloat = 14
    static let appTitleSize: CGFloat = 14
    static let windowTitleSize: CGFloat = 10
    static let titleSpacing: CGFloat = 2
    static let badgeVerticalPadding: CGFloat = 3

    var size: CGSize
    var progress: CGFloat

    init(size: CGSize, progress: CGFloat) {
        self.size = size
        self.progress = min(max(progress, 0), 1)
    }

    var scale: CGFloat {
        1 + (SwitcherCardEffectMetrics.selectedScale - 1) * progress
    }

    var horizontalOutset: CGFloat {
        size.width * (scale - 1) / 2
    }

    var verticalOutset: CGFloat {
        size.height * (scale - 1) / 2
    }

    var leadingPadding: CGFloat {
        scaled(Self.rowHeight + 11) - horizontalOutset
    }

    var trailingPadding: CGFloat {
        scaled(10) - horizontalOutset
    }

    var cornerRadius: CGFloat {
        scaled(Self.cornerRadius)
    }

    var compensatedTitleSpacing: CGFloat {
        Self.titleSpacing
            - (scale - 1) * (Self.appTitleSize + Self.windowTitleSize) / 2
    }

    var compensatedBadgeVerticalPadding: CGFloat {
        Self.badgeVerticalPadding
            - (scale - 1) * Self.windowTitleSize / 2
    }

    func scaled(_ value: CGFloat) -> CGFloat {
        value * scale
    }
}

private struct SwitcherOutsideShadow: View {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat

    var body: some View {
        Canvas { context, size in
            let surfaceRect = CGRect(origin: .zero, size: size)
                .insetBy(
                    dx: SwitcherCardEffectMetrics.outset,
                    dy: SwitcherCardEffectMetrics.outset
                )
            let surfacePath = Path(
                roundedRect: surfaceRect,
                cornerRadius: cornerRadius
            )

            context.drawLayer { shadowContext in
                shadowContext.addFilter(
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.40 : 0.18),
                        radius: colorScheme == .dark ? 17 : 12,
                        x: 0,
                        y: colorScheme == .dark ? 10 : 6,
                        options: .shadowOnly
                    )
                )
                shadowContext.fill(surfacePath, with: .color(.black))
            }

            // Retain only the shadow outside the translucent card surface.
            context.blendMode = .clear
            context.fill(surfacePath, with: .color(.white))
        }
        .padding(-SwitcherCardEffectMetrics.outset)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SwitcherItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [WindowIdentity: CGRect] = [:]

    static func reduce(
        value: inout [WindowIdentity: CGRect],
        nextValue: () -> [WindowIdentity: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct SwitcherIslandWindowCard: View, @MainActor Animatable {
    var item: SwitcherItem
    var mode: SwitcherMode
    var isSelected: Bool
    var isHovered: Bool
    var onHoverChange: (Bool) -> Void
    var onConfirm: () -> Void
    private var selectionProgress: CGFloat

    var animatableData: CGFloat {
        get { selectionProgress }
        set { selectionProgress = newValue }
    }

    init(
        item: SwitcherItem,
        mode: SwitcherMode,
        isSelected: Bool,
        isHovered: Bool = false,
        onHoverChange: @escaping (Bool) -> Void = { _ in },
        onConfirm: @escaping () -> Void = {}
    ) {
        self.item = item
        self.mode = mode
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.onHoverChange = onHoverChange
        self.onConfirm = onConfirm
        selectionProgress = isSelected ? 1 : 0
    }

    var body: some View {
        Button(action: onConfirm) {
            GeometryReader { geometry in
                let metrics = SwitcherCardSelectionMetrics(
                    size: geometry.size,
                    progress: selectionProgress
                )

                cardContent(metrics: metrics)
                    .background {
                        cardSurface(metrics: metrics)
                    }
                    .background {
                        SwitcherOutsideShadow(cornerRadius: metrics.cornerRadius)
                            .padding(.horizontal, -metrics.horizontalOutset)
                            .padding(.vertical, -metrics.verticalOutset)
                            .opacity(metrics.progress)
                    }
                    .contentShape(cardShape)
            }
            .frame(height: SwitcherCardSelectionMetrics.rowHeight)
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Opens this window")
    }

    @ViewBuilder
    private func cardContent(metrics: SwitcherCardSelectionMetrics) -> some View {
        HStack(spacing: metrics.scaled(9)) {
            VStack(alignment: .leading, spacing: metrics.compensatedTitleSpacing) {
                Text(item.appName)
                    .font(selectionFont(
                        baseSize: SwitcherCardSelectionMetrics.appTitleSize,
                        weight: .medium,
                        metrics: metrics
                    ))
                    .lineLimit(1)
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(selectionFont(
                            baseSize: SwitcherCardSelectionMetrics.windowTitleSize,
                            weight: .regular,
                            metrics: metrics
                        ))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: metrics.scaled(8))
            if mode == .allWindows {
                if item.isZonalUtility {
                    Text("Settings")
                        .font(selectionFont(
                            baseSize: 10,
                            weight: .medium,
                            metrics: metrics
                        ))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, metrics.scaled(7))
                        .padding(.vertical, metrics.compensatedBadgeVerticalPadding)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                Text(item.zoneName)
                    .font(selectionFont(
                        baseSize: SwitcherCardSelectionMetrics.windowTitleSize,
                        weight: .medium,
                        metrics: metrics
                    ))
                    .foregroundStyle(item.isActive ? Color.primary : Color.secondary)
                    .padding(.horizontal, metrics.scaled(7))
                    .padding(.vertical, metrics.compensatedBadgeVerticalPadding)
                    .background(
                        item.isActive
                            ? Color.accentColor.opacity(0.16)
                            : Color.secondary.opacity(0.08),
                        in: Capsule()
                    )
                ZoneIconView(frame: item.zoneFrame ?? .full)
                    .frame(width: metrics.scaled(24), height: metrics.scaled(15))
            }
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .frame(height: SwitcherCardSelectionMetrics.rowHeight)
    }

    @ViewBuilder
    private func cardSurface(metrics: SwitcherCardSelectionMetrics) -> some View {
        let surfaceShape = RoundedRectangle(
            cornerRadius: metrics.cornerRadius,
            style: .continuous
        )

        ZStack(alignment: .leading) {
            surfaceShape.fill(Color.white.opacity(0.22))
            surfaceShape.fill(
                Color.primary.opacity(isHovered && !isSelected ? 0.07 : 0)
            )
            surfaceShape.fill(
                Color.accentColor.opacity(0.16 * Double(metrics.progress))
            )
            appIcon(metrics: metrics)
            surfaceShape.strokeBorder(
                Color.white.opacity(0.08 * Double(1 - metrics.progress)),
                lineWidth: metrics.scaled(0.75)
            )
        }
        .clipShape(surfaceShape)
        .padding(.horizontal, -metrics.horizontalOutset)
        .padding(.vertical, -metrics.verticalOutset)
        .animation(.easeOut(duration: 0.08), value: isHovered)
    }

    @ViewBuilder
    private func appIcon(metrics: SwitcherCardSelectionMetrics) -> some View {
        let size = metrics.scaled(SwitcherCardSelectionMetrics.rowHeight)

        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: size * 1.18, height: size * 1.18)
                .frame(width: size, height: size)
                .clipped()
        } else {
            cardShape
                .fill(Color.accentColor.gradient)
                .frame(width: size, height: size)
                .overlay {
                    Text(String(item.appName.prefix(1)))
                        .font(.system(
                            size: metrics.scaled(20),
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white)
                }
        }
    }

    private func selectionFont(
        baseSize: CGFloat,
        weight: NSFont.Weight,
        metrics: SwitcherCardSelectionMetrics
    ) -> Font {
        let font = NSFont.systemFont(
            ofSize: metrics.scaled(baseSize),
            weight: weight
        )
        return Font(font)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: SwitcherCardSelectionMetrics.cornerRadius,
            style: .continuous
        )
    }

    private var accessibilityLabel: String {
        var parts = [item.appName]
        if let title = item.title, !title.isEmpty {
            parts.append(title)
        }
        if mode == .allWindows {
            parts.append(item.zoneName)
        }
        if item.isActive {
            parts.append("active window in zone")
        }
        if item.isZonalUtility {
            parts.append("Zonal Settings utility window")
        }
        return parts.joined(separator: ", ")
    }
}

struct SwitcherShortcutHint: View {
    var keys: [String]
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
