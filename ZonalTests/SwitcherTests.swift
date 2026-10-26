import ApplicationServices
import CoreGraphics
import SwiftUI
import XCTest
@testable import Zonal

final class SwitcherTests: XCTestCase {
    func testHiddenHotkeysReclaimLayoutSpaceInBothSwitchers() {
        for mode: SwitcherMode in [.allWindows, .byZone] {
            var metrics = SwitcherScreenLayoutMetrics(availableSize: CGSize(width: 1920, height: 1080),
                columnZoneCounts: [1], mode: mode, isFiltering: false)
            let visibleHeight = metrics.viewportSize.height
            metrics.showsShortcutGuide = false
            XCTAssertEqual(metrics.viewportSize.height, 1048)
            XCTAssertGreaterThan(metrics.viewportSize.height, visibleHeight)
            metrics.isFiltering = true
            XCTAssertEqual(metrics.viewportSize.height, 992)
        }
    }

    func testInputCapturePassesTypingWithoutWaitingForUIAndReleasesImmediately() throws {
        let binding = HotkeyBinding(command: .openGlobalSwitcher, keyCode: 48,
                                    keyLabel: "Tab", modifiers: .commandOnly)
        var state = HotkeyCaptureSnapshot(bindings: [binding])
        let typing = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let text: [UniChar] = [97]
        typing.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        XCTAssertFalse(state.captures(typing))
        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        tab.flags = .maskCommand
        XCTAssertTrue(state.captures(tab))
        XCTAssertTrue(state.captures(typing), "Typing belongs to the pending switcher until release")
        state.flagsChanged([])
        XCTAssertFalse(state.captures(typing), "Release must unblock other apps even while the UI thread is stalled")
        state.update(HotkeyCaptureSnapshot(bindings: [binding], switcherActive: true))
        XCTAssertFalse(state.captures(typing), "A delayed presentation cannot recapture typing after release")
        XCTAssertTrue(state.captures(tab), "A new explicit switch starts a new capture session")
        state.flagsChanged([])
        state.update(HotkeyCaptureSnapshot(bindings: [binding], useNativeCommandTab: true))
        XCTAssertFalse(state.captures(tab))
        ShortcutRecordingSession.begin()
        defer { ShortcutRecordingSession.end() }
        state.update(HotkeyCaptureSnapshot(bindings: [binding]))
        XCTAssertFalse(state.captures(tab), "Recording shortcuts must preserve the original key event")
    }

    @MainActor
    func testKeyboardRoutingReturnsWhileMainThreadIsBlocked() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let returned = DispatchSemaphore(value: 0)
        let tap = KeyboardInputTap { _, _, _ in
            DispatchQueue.main.async { /* UI delivery deliberately cannot run yet. */ }
        }
        DispatchQueue.global().async {
            if tap.receive(.keyDown, event) != nil { returned.signal() }
        }
        // No real event tap or Accessibility permission is used by this fixture.
        XCTAssertEqual(returned.wait(timeout: .now() + 1), .success)
    }

    @MainActor
    func testSwitcherWarmupStaysDetachedAndReusesItsTree() throws {
        try withSwitcher { switcher in
            switcher.preparePresentation()
            let panel = try XCTUnwrap(switcher.window)
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.contentView)
            switcher.preparePresentation()
            switcher.show(mode: .allWindows)
            let host = try XCTUnwrap(panel.contentView)
            switcher.cancel()
            XCTAssertNil(panel.contentView)
            switcher.preparePresentation()
            switcher.show(mode: .byZone)
            XCTAssertTrue(panel.contentView === host)
        }
    }

    @MainActor
    func testSessionSuspensionClosesFilteredSwitcherWithoutDiscardingWarmTree() throws {
        try withSwitcher { switcher in
            switcher.show(mode: .allWindows)
            let host = try XCTUnwrap(switcher.window?.contentView)
            switcher.appendFilter("test")
            switcher.suspend()
            XCTAssertFalse(switcher.isVisible)
            XCTAssertNil(switcher.window?.contentView)
            switcher.show(mode: .allWindows)
            XCTAssertTrue(switcher.window?.contentView === host)
        }
    }

    @MainActor
    func testSwitcherLatencyProbe() throws {
        guard ProcessInfo.processInfo.environment["ZONAL_SWITCHER_LATENCY_CHECK"] == "1" else {
            throw XCTSkip("Opt-in source-level latency probe; does not measure live keyboard or AX focus.")
        }
        var results: [[String: Any]] = []
        for count in [2, 24] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zonal-latency-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PersistenceStore(supportDirectory: directory)
            store.bootstrap()
            let snapshot = DisplaySnapshot(displays: [.init(id: 99,
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056), scale: 1)])
            let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
            var configuration = store.loadConfiguration()
            configuration.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
            store.saveConfiguration(configuration)
            let zones = configuration.profiles[0].zones
            let windows = (1...count).map { index -> ManagedWindow in
                var window = managedWindow(cgWindowID: UInt32(index), observedOrder: index)
                window.element = AXUIElementCreateApplication(pid_t(100_000 + index))
                return window
            }
            store.saveAssignments(windows.enumerated().map { index, window in
                WindowAssignment(id: UUID(), identity: window.identity,
                    zoneID: zones[index % zones.count].id, updatedAt: Date())
            })
            let registry = WindowRegistry(inventoryProvider: { $0(windows, nil) })
            let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
            defer { tracker.stop() }
            tracker.reconcile()
            let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
                windowRegistry: registry, windowTracker: tracker,
                windowController: WindowController(frameProvider: { _ in nil }), store: store)
            service.reconcile()
            let switcher = SwitcherController(workspaceState: service)
            for iteration in 0..<21 {
                let start = ProcessInfo.processInfo.systemUptime
                switcher.performPresentationBatch { switcher.show(mode: .allWindows) }
                let prepared = ProcessInfo.processInfo.systemUptime
                let panel = try XCTUnwrap(switcher.window)
                let host = try XCTUnwrap(panel.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let drawn = ProcessInfo.processInfo.systemUptime
                let content = try XCTUnwrap((host as? NSHostingView<SwitcherView>)?.rootView.presentation.content)
                XCTAssertEqual(content.model.zones.flatMap(\.items).count, count)
                switcher.dismissPresentation()
                let dismissed = ProcessInfo.processInfo.systemUptime
                XCTAssertFalse(panel.isVisible)
                switcher.cancel()
                results.append(["windows": count,
                    "path": iteration == 0 ? "cold" : "warm",
                    "prepareMs": (prepared - start) * 1_000,
                    "prepareAndForcedDrawMs": (drawn - start) * 1_000,
                    "dismissMs": (dismissed - drawn) * 1_000])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: "/tmp/zonal-switcher-latency-probe.json"))
    }

    @MainActor
    private func withSwitcher(_ body: (SwitcherController) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zonal-switcher-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let registry = WindowRegistry(inventoryProvider: { $0([], nil) })
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: FixedDisplayProvider(
                snapshot: DisplaySnapshot(displays: [])
            )),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry, focusedWindowProvider: { nil }),
            windowController: WindowController(), store: store
        )
        let switcher = SwitcherController(workspaceState: service)
        defer { switcher.cancel() }
        try body(switcher)
    }

    @MainActor
    func testRapidSwitcherKeyDownPreservesPreviousFocusButTypingCancelsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zonal-hotkeys-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        var configuration = store.loadConfiguration()
        configuration.hotkeys = [
            HotkeyBinding(command: .openGlobalSwitcher, keyCode: 48, keyLabel: "Tab", modifiers: .commandOnly),
            HotkeyBinding(command: .openZoneSwitcher, keyCode: 48, keyLabel: "Tab",
                modifiers: HotkeyModifiers(command: false, control: true, option: false, shift: false))
        ]
        store.saveConfiguration(configuration)
        let registry = WindowRegistry(inventoryProvider: { $0([], nil) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: DisplaySnapshot(displays: [])))
        let controller = WindowController()
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: controller, store: store)
        let switcher = SwitcherController(workspaceState: service)
        let restore = RestoreEngine(profileManager: manager, windowRegistry: registry, windowTracker: tracker,
            windowController: controller, workspaceState: service, store: store)
        let hotkeys = HotkeyManager(restoreEngine: restore, windowRegistry: registry, store: store,
            workspaceState: service, switcher: switcher)
        defer { hotkeys.stop(); switcher.cancel() }
        var cancellations = 0
        hotkeys.onUserKeyDown = { cancellations += 1 }
        for flags in [CGEventFlags.maskCommand, .maskControl] {
            let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
            tab.flags = flags
            XCTAssertNil(hotkeys.handleEvent(type: .keyDown, event: tab))
        }
        XCTAssertEqual(cancellations, 0, "A rapid second switch must not erase a confirmed first switch")
        let typing = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertNotNil(hotkeys.handleEvent(type: .keyDown, event: typing))
        XCTAssertEqual(cancellations, 1, "Ordinary typing still cancels a pending focus handoff")
    }

    @MainActor
    func testHiddenSwitcherDetachesAndReusesWarmViewTree() throws {
        try withSwitcher { switcher in
            XCTAssertNil(switcher.window)
            switcher.show(mode: .byZone)
            let panel = try XCTUnwrap(switcher.window)
            weak var oldHost = panel.contentView
            XCTAssertNotNil(oldHost)
            switcher.cancel()
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.contentView)
            XCTAssertNil(oldHost?.window, "AppKit may retain the detached view until its transaction drains")
            switcher.show(mode: .byZone)
            XCTAssertTrue(switcher.window === panel)
            XCTAssertTrue(panel.contentView === oldHost)
            XCTAssertTrue(panel.isVisible)
        }
    }

    @MainActor
    func testAlreadyQueuedReleaseNeverCreatesAnOverlay() throws {
        try withSwitcher { switcher in
            switcher.performPresentationBatch {
                switcher.show(mode: .allWindows)
                switcher.confirm()
            }
            XCTAssertFalse(switcher.isVisible)
            XCTAssertNil(switcher.window)
        }
    }

    @MainActor
    func testAlreadyQueuedCancelNeverCreatesAnOverlay() throws {
        try withSwitcher { switcher in
            switcher.performPresentationBatch {
                switcher.show(mode: .byZone)
                switcher.next()
                switcher.cancel()
            }
            XCTAssertFalse(switcher.isVisible)
            XCTAssertNil(switcher.window)
        }
    }

    @MainActor
    func testReleaseHidesImmediatelyAndFurtherUpdatesCannotReopenPresentation() throws {
        try withSwitcher { switcher in
            switcher.performPresentationBatch { switcher.show(mode: .allWindows) }
            let panel = try XCTUnwrap(switcher.window)
            XCTAssertTrue(panel.isVisible)
            let state = try XCTUnwrap((panel.contentView as? NSHostingView<SwitcherView>)?.rootView.presentation)
            switcher.dismissPresentation()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(state.isActive)
            XCTAssertTrue(switcher.isVisible) // Selection survives until the queued confirmation.
            switcher.next()
            XCTAssertFalse(panel.isVisible)
            switcher.confirm()
            switcher.show(mode: .allWindows)
            XCTAssertTrue(switcher.window === panel)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(state.isActive)
            XCTAssertTrue(try XCTUnwrap((panel.contentView as? NSHostingView<SwitcherView>)?.rootView.presentation).isActive)
        }
    }

    func testCurrentConfigurationPreservesDeletedShortcuts() {
        var configuration = ZonalConfiguration.default
        configuration.profiles = [DisplayProfile(id: "test", name: "Test", mainZoneID: .main,
            zones: [Zone(id: .main, name: "Main", frame: .full)])]
        configuration.activeProfileID = "test"
        configuration.hotkeys = [HotkeyBinding(command: .focusZone(.main), keyCode: 0,
            keyLabel: "A", modifiers: .controlOption)] + HotkeyBinding.defaults.filter {
                if case .openZoneSwitcher = $0.command { return true }
                if case .moveFocusedWindowRelative = $0.command { return true }
                return false
            }
        configuration.hotkeys.removeAll {
            if case .openZoneSwitcher = $0.command { return true }
            if case .moveFocusedWindowRelative = $0.command { return true }
            return false
        }
        let expected = configuration.hotkeys
        XCTAssertEqual(ConfigurationEditor().sanitized(configuration).hotkeys, expected)

    }

    func testThreePopulatedZoneIslandsShareLaptopHeightBudget() {
        let metrics = SwitcherScreenLayoutMetrics(
            availableSize: CGSize(width: 1280, height: 720),
            columnZoneCounts: [3], mode: .byZone, isFiltering: false
        )
        let columnHeight = 3 * (metrics.maximumListHeight(column: 0) + 33)
            + 2 * metrics.zoneSpacing + 2 * metrics.effectOutset
        XCTAssertLessThanOrEqual(columnHeight, metrics.viewportSize.height)
        XCTAssertGreaterThanOrEqual(metrics.maximumListHeight(column: 0), 82)
        XCTAssertLessThanOrEqual(metrics.viewportSize.height, 720 - 148)
    }

    func testSwitcherFitsWidthAndKeepsOverflowScrollable() {
        let metrics = SwitcherScreenLayoutMetrics(
            availableSize: CGSize(width: 900, height: 700),
            columnZoneCounts: [2, 3, 2], mode: .byZone, isFiltering: true
        )
        let footprintWidth = metrics.islandWidth * 3 + metrics.columnSpacing * 2 + metrics.effectOutset * 2
        XCTAssertLessThanOrEqual(footprintWidth, metrics.viewportSize.width)
        XCTAssertLessThan(metrics.viewportSize.height, 700 - 180)
        let crowded = SwitcherScreenLayoutMetrics(
            availableSize: CGSize(width: 600, height: 500),
            columnZoneCounts: [8, 8, 8], mode: .byZone, isFiltering: false
        )
        XCTAssertEqual(crowded.islandWidth, 220)
        XCTAssertEqual(crowded.maximumListHeight(column: 0), 82)
        XCTAssertLessThanOrEqual(crowded.viewportSize.width, 600)
        XCTAssertLessThanOrEqual(crowded.viewportSize.height, 500)
    }

    @MainActor
    func testShortcutRecordingCommitsOnceAndReleasesCaptureOnCancellation() throws {
        let modifiers = HotkeyModifiers(command: false, control: false, option: true, shift: false)
        let key = try XCTUnwrap(HotkeyKey.common.first { $0.keyCode == 48 })
        var commits: [(HotkeyModifiers, HotkeyKey)] = []
        let coordinator = ShortcutRecorderView.Coordinator(modifiers: modifiers, key: key) {
            commits.append(($0, $1))
        }
        let button = ShortcutRecorderButton()
        button.coordinator = coordinator
        button.beginRecording()
        button.beginRecording()
        XCTAssertTrue(ShortcutRecordingSession.isActive)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        XCTAssertTrue(button.performKeyEquivalent(with: event))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].0, modifiers)
        XCTAssertEqual(commits[0].1, key)
        XCTAssertFalse(ShortcutRecordingSession.isActive)
        button.beginRecording()
        button.cancelRecording()
        button.cancelRecording()
        XCTAssertFalse(ShortcutRecordingSession.isActive)
        XCTAssertEqual(commits.count, 1)
    }

    @MainActor
    func testPopulatedLaptopSwitcherRendersWithinCanvas() async throws {
        let ids: [ZoneID] = [.left, .main, .right]
        let zones = ids.enumerated().map { index, zoneID in
            SwitcherZone(id: zoneID, name: ["Notes", "Main", "Reference"][index], frame: .full,
                items: (0..<12).map { row in
                    var item = switcherItem(assignmentID: UUID(), windowID: UInt32(index * 100 + row + 1), zoneID: zoneID)
                    item.appName = ["Notes", "Editor", "Browser"][index]
                    item.title = "Window \(row + 1)"
                    return item
                })
        }
        let model = WorkspaceSnapshotModel(mode: .byZone, zones: zones, zoneColumns: [ids],
            selectedZoneID: .main, selectedWindowID: zones[1].items[0].identity)
        let presentation = SwitcherPresentationState(content: SwitcherPresentationContent(
            model: model, filterQuery: "", unfilteredItemCounts: [:], animateEntrance: false,
            presentationToken: 1, renderToken: 1, hoverResetToken: 1, pointerLocationAtHoverReset: .zero
        ))
        let scene = ZStack {
            Color(red: 0.16, green: 0.52, blue: 0.56)
            SwitcherView(presentation: presentation)
        }
        .frame(width: 1280, height: 720)
        .environment(\.colorScheme, .light)
        // SwiftUI ImageRenderer cannot draw the AppKit-backed ScrollViews in this view.
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        let hostingView = NSHostingView(rootView: scene)
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: bounds))
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        for y in [120, 280, 440] {
            let surface = try XCTUnwrap(bitmap.colorAt(
                x: 780 * bitmap.pixelsWide / 1280, y: y * bitmap.pixelsHigh / 720
            )?.usingColorSpace(.deviceRGB))
            let difference = abs(surface.redComponent - background.redComponent)
                + abs(surface.greenComponent - background.greenComponent)
                + abs(surface.blueComponent - background.blueComponent)
            XCTAssertGreaterThan(difference, 0.25, "Zone surface missing at y=\(y)")
            XCTAssertLessThan(abs(surface.redComponent - surface.greenComponent), 0.3,
                "Expected neutral material, not an unsupported-view warning")
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/zonal-switcher-laptop.png"))
    }

    func testSwitcherHostingViewIsReusedAfterItsFirstPresentation() {
        let policy = SwitcherHostingReusePolicy()

        XCTAssertTrue(policy.shouldCreateHostingView(
            hasHostingView: false,
            hasPresentationState: false
        ))
        XCTAssertTrue(policy.shouldCreateHostingView(
            hasHostingView: true,
            hasPresentationState: false
        ))
        XCTAssertFalse(policy.shouldCreateHostingView(
            hasHostingView: true,
            hasPresentationState: true
        ))
    }

    func testFocusEventSequencerPreservesEveryObservedEvent() {
        var sequencer = FocusEventSequencer()
        let first = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 10)
        let second = LiveWindowID.quartz(processIdentifier: 2, windowNumber: 20)
        let records = (0..<100).map { index in
            sequencer.record(index.isMultiple(of: 2) ? first : second)
        }

        XCTAssertEqual(records.map(\.sequence), Array(1...100).map(UInt64.init))
        XCTAssertEqual(records.first?.windowID, first)
        XCTAssertEqual(records.last?.windowID, second)
        XCTAssertEqual(sequencer.sequence, 100)
    }

    func testFocusObservationRejectsStaleActivationAndRecordsExplicitActivation() {
        let policy = FocusObservationPolicy()
        let windowID = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 100)

        XCTAssertFalse(policy.accepts(
            observedProcessIdentifier: 41,
            expectedProcessIdentifier: 42
        ))
        XCTAssertTrue(policy.accepts(
            observedProcessIdentifier: 42,
            expectedProcessIdentifier: 42
        ))
        XCTAssertFalse(policy.shouldRecord(
            previousWindowID: windowID,
            observedWindowID: windowID,
            recordEvenIfUnchanged: false
        ))
        XCTAssertTrue(policy.shouldRecord(
            previousWindowID: windowID,
            observedWindowID: windowID,
            recordEvenIfUnchanged: true
        ))
    }

    func testDelayedFocusResolutionCannotReorderMRU() {
        let firstWindow = LiveWindowID.session(processIdentifier: 1, id: UUID())
        let secondWindow = LiveWindowID.session(processIdentifier: 1, id: UUID())
        let firstAssignment = UUID()
        let secondAssignment = UUID()
        let events = [
            DeferredFocusEvent(sequence: 1, target: .liveWindow(firstWindow)),
            DeferredFocusEvent(sequence: 2, target: .liveWindow(secondWindow))
        ]
        let projector = FocusHistoryProjector()

        let partiallyResolved = projector.replay(
            baseline: .empty,
            events: events,
            assignmentByWindowID: [
                secondWindow: AssignmentFocusTarget(
                    assignmentID: secondAssignment,
                    zoneID: .right
                )
            ]
        )
        XCTAssertEqual(partiallyResolved.globalRecency, [secondAssignment])

        let fullyResolved = projector.replay(
            baseline: .empty,
            events: events,
            assignmentByWindowID: [
                firstWindow: AssignmentFocusTarget(
                    assignmentID: firstAssignment,
                    zoneID: .left
                ),
                secondWindow: AssignmentFocusTarget(
                    assignmentID: secondAssignment,
                    zoneID: .right
                )
            ]
        )
        XCTAssertEqual(fullyResolved.globalRecency, [secondAssignment, firstAssignment])
        XCTAssertEqual(fullyResolved.assignmentRecencyByZone[.left], [firstAssignment])
        XCTAssertEqual(fullyResolved.assignmentRecencyByZone[.right], [secondAssignment])
    }

    func testFocusProjectionCompactsResolvedPrefixWithoutReorderingDeferredEvents() {
        let firstWindow = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 10)
        let delayedWindow = LiveWindowID.quartz(processIdentifier: 2, windowNumber: 20)
        let thirdAssignment = AssignmentFocusTarget(
            assignmentID: UUID(),
            zoneID: .right
        )
        let firstAssignment = AssignmentFocusTarget(
            assignmentID: UUID(),
            zoneID: .left
        )
        let events = [
            DeferredFocusEvent(sequence: 1, target: .liveWindow(firstWindow)),
            DeferredFocusEvent(sequence: 2, target: .liveWindow(delayedWindow)),
            DeferredFocusEvent(sequence: 3, target: .assignment(thirdAssignment))
        ]

        let projection = FocusHistoryProjector().project(
            baseline: .empty,
            events: events,
            assignmentByWindowID: [firstWindow: firstAssignment]
        )

        XCTAssertEqual(projection.compactedBaseline.globalRecency, [firstAssignment.assignmentID])
        XCTAssertEqual(projection.remainingEvents.map(\.sequence), [2, 3])
        XCTAssertEqual(
            projection.state.globalRecency,
            [thirdAssignment.assignmentID, firstAssignment.assignmentID]
        )

        let resolvedProjection = FocusHistoryProjector().project(
            baseline: projection.compactedBaseline,
            events: projection.remainingEvents,
            assignmentByWindowID: [delayedWindow: AssignmentFocusTarget(
                assignmentID: UUID(),
                zoneID: .center
            )]
        )
        XCTAssertTrue(resolvedProjection.remainingEvents.isEmpty)
        XCTAssertEqual(resolvedProjection.state.globalRecency.first, thirdAssignment.assignmentID)
    }

    func testRapidAlternatingFocusEventsKeepExactFinalMRUOrder() {
        let firstWindow = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 10)
        let secondWindow = LiveWindowID.quartz(processIdentifier: 2, windowNumber: 20)
        let firstAssignment = UUID()
        let secondAssignment = UUID()
        let events = (1...100).map { sequence in
            DeferredFocusEvent(
                sequence: UInt64(sequence),
                target: .liveWindow(sequence.isMultiple(of: 2) ? firstWindow : secondWindow)
            )
        }

        let projected = FocusHistoryProjector().replay(
            baseline: .empty,
            events: events,
            assignmentByWindowID: [
                firstWindow: AssignmentFocusTarget(
                    assignmentID: firstAssignment,
                    zoneID: .left
                ),
                secondWindow: AssignmentFocusTarget(
                    assignmentID: secondAssignment,
                    zoneID: .right
                )
            ]
        )

        XCTAssertEqual(projected.globalRecency, [firstAssignment, secondAssignment])
        XCTAssertEqual(projected.assignmentRecencyByZone[.left], [firstAssignment])
        XCTAssertEqual(projected.assignmentRecencyByZone[.right], [secondAssignment])
    }

    func testSwitcherModifierReleaseConfirmsBeforeOverlayHasRendered() {
        let policy = SwitcherModifierReleasePolicy()

        XCTAssertTrue(
            policy.shouldConfirm(
                hasPendingReleaseModifier: true,
                modifierIsStillPressed: false
            )
        )
        XCTAssertFalse(
            policy.shouldConfirm(
                hasPendingReleaseModifier: true,
                modifierIsStillPressed: true
            )
        )
        XCTAssertFalse(
            policy.shouldConfirm(
                hasPendingReleaseModifier: false,
                modifierIsStillPressed: false
            )
        )
    }

    func testZoneSwitcherArrowsFollowEveryVisualDirection() {
        let policy = SwitcherArrowCommandPolicy()

        XCTAssertEqual(
            policy.action(for: .up, shift: false, mode: .byZone),
            .selectVerticalWindow(-1)
        )
        XCTAssertEqual(
            policy.action(for: .down, shift: true, mode: .byZone),
            .assignZone(.down)
        )
        XCTAssertEqual(
            policy.action(for: .left, shift: false, mode: .byZone),
            .selectZone(.left)
        )
        XCTAssertEqual(
            policy.action(for: .right, shift: true, mode: .byZone),
            .assignZone(.right)
        )
    }

    func testGlobalSwitcherArrowsNeverEnterZoneNavigation() {
        let policy = SwitcherArrowCommandPolicy()

        XCTAssertEqual(
            policy.action(for: .left, shift: true, mode: .allWindows),
            .selectWindow(-1)
        )
        XCTAssertEqual(
            policy.action(for: .down, shift: false, mode: .allWindows),
            .selectWindow(1)
        )
    }

    func testSwitcherMRUForcesCurrentFirstThenUsesHistory() {
        let current = UUID()
        let previous = UUID()
        let older = UUID()
        let newWindow = UUID()

        let ordered = SwitcherMRUOrder().orderedAssignmentIDs(
            available: [older, current, newWindow, previous],
            current: current,
            history: [previous, older, current]
        )

        XCTAssertEqual(ordered, [current, previous, older, newWindow])
    }

    func testSwitcherMRUDropsUnavailableAndDuplicateHistoryEntries() {
        let current = UUID()
        let previous = UUID()
        let unavailable = UUID()

        let ordered = SwitcherMRUOrder().orderedAssignmentIDs(
            available: [current, previous],
            current: current,
            history: [unavailable, previous, current, previous]
        )

        XCTAssertEqual(ordered, [current, previous])
    }

    func testSwitcherInitiallySelectsPreviousWindow() {
        let current = UUID()
        let previous = UUID()
        let older = UUID()
        let policy = SwitcherSelectionPolicy()

        XCTAssertEqual(
            policy.initialAssignmentID(in: [current, previous, older]),
            previous
        )
        XCTAssertEqual(policy.initialAssignmentID(in: [current]), current)
        XCTAssertNil(policy.initialAssignmentID(in: []))
    }

    func testSwitcherFilterMatchesAppAndTitleAcrossBothZones() {
        var arcSpace = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .left)
        arcSpace.appName = "Arc"
        arcSpace.title = "Zonal review"
        var editor = switcherItem(assignmentID: UUID(), windowID: 20, zoneID: .right)
        editor.appName = "Xcode"
        editor.title = "Arc notes"
        let model = WorkspaceSnapshotModel(
            mode: .allWindows,
            zones: [
                SwitcherZone(id: .left, name: "Left", frame: .full, items: [arcSpace]),
                SwitcherZone(id: .right, name: "Right", frame: .full, items: [editor])
            ],
            zoneColumns: [[.left], [.right]],
            selectedZoneID: .left,
            selectedWindowID: arcSpace.identity
        )

        let filtered = SwitcherFilterPolicy().filtered(model, query: "arc notes")

        XCTAssertTrue(filtered.zones[0].items.isEmpty)
        XCTAssertEqual(filtered.zones[1].items, [editor])
        XCTAssertEqual(filtered.selectedWindowID, editor.identity)
        XCTAssertEqual(filtered.selectedZoneID, .right)
    }

    func testSwitcherFilterIsCaseAndDiacriticInsensitiveAndHandlesNoMatches() {
        var item = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .main)
        item.appName = "Résumé"
        let model = WorkspaceSnapshotModel(
            mode: .byZone,
            zones: [SwitcherZone(id: .main, name: "Main", frame: .full, items: [item])],
            zoneColumns: [[.main]],
            selectedZoneID: .main,
            selectedWindowID: item.identity
        )

        XCTAssertEqual(
            SwitcherFilterPolicy().filtered(model, query: "RESUME").zones[0].items,
            [item]
        )
        XCTAssertNil(SwitcherFilterPolicy().filtered(model, query: "missing").selectedWindowID)
    }

    func testSwitcherTextInputAcceptsPrintableTextOnly() {
        let policy = SwitcherTextInputPolicy()

        XCTAssertEqual(policy.acceptedText("a"), "a")
        XCTAssertEqual(policy.acceptedText("7"), "7")
        XCTAssertNil(policy.acceptedText("\t"))
        XCTAssertNil(policy.acceptedText(nil))
    }

    func testGlobalSwitcherMarksOneActiveWindowPerZone() {
        let previousMain = UUID()
        let focusedMain = UUID()
        let activeLeft = UUID()
        let state = ZoneStackState(
            activeAssignmentByZone: [
                .main: previousMain,
                .left: activeLeft
            ]
        )

        let active = SwitcherActivityPolicy().activeAssignmentIDs(
            state: state,
            focusedAssignmentID: focusedMain,
            focusedZoneID: .main
        )

        XCTAssertEqual(active, Set([focusedMain, activeLeft]))
        XCTAssertFalse(active.contains(previousMain))
    }

    func testFocusRecoveryAddsPreviouslyUnseenWindowToBothHistories() {
        let existing = UUID()
        let recovered = UUID()
        var reducer = WindowHistoryReducer(
            state: ZoneStackState(globalRecency: [existing])
        )

        reducer.recordFocus(assignmentID: recovered, zoneID: .main)

        XCTAssertEqual(reducer.state.globalRecency, [recovered, existing])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.main], [recovered])
        XCTAssertEqual(reducer.state.activeAssignmentByZone[.main], recovered)
    }

    func testLiveAssignmentCanonicalizationKeepsMRUAndMergesProfilePlacements() {
        let liveIdentity = WindowIdentity(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1
        )
        let historyWinner = WindowAssignment(
            id: UUID(),
            identity: liveIdentity,
            fingerprint: liveIdentity.fingerprint,
            zoneID: .left,
            placementsByProfileID: [
                "laptop": .zoneFit(zoneID: .left)
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerDuplicate = WindowAssignment(
            id: UUID(),
            identity: liveIdentity,
            fingerprint: liveIdentity.fingerprint,
            zoneID: .left,
            placementsByProfileID: [
                "ultrawide": .zoneFit(zoneID: .left)
            ],
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let result = WindowAssignmentCanonicalizer().canonicalize(
            assignments: [newerDuplicate, historyWinner],
            liveIdentities: [liveIdentity],
            globalRecency: [historyWinner.id, newerDuplicate.id]
        )

        XCTAssertEqual(result.assignments.count, 1)
        XCTAssertEqual(result.assignments[0].id, historyWinner.id)
        XCTAssertEqual(result.assignments[0].zoneID, .left)
        XCTAssertNotNil(result.assignments[0].placementsByProfileID["laptop"])
        XCTAssertNotNil(result.assignments[0].placementsByProfileID["ultrawide"])
        XCTAssertEqual(result.replacements[newerDuplicate.id], historyWinner.id)

        var reducer = WindowHistoryReducer(
            state: ZoneStackState(
                schemaVersion: 2,
                globalRecency: [newerDuplicate.id, historyWinner.id],
                activeAssignmentByZone: [.right: newerDuplicate.id],
                assignmentRecencyByZone: [
                    .right: [newerDuplicate.id, historyWinner.id]
                ]
            )
        )
        reducer.replaceAssignmentIDs(
            result.replacements,
            assignmentZoneIDs: Dictionary(
                uniqueKeysWithValues: result.assignments.map {
                    ($0.id, $0.zoneID)
                }
            )
        )
        XCTAssertEqual(reducer.state.globalRecency, [historyWinner.id])
        XCTAssertNil(reducer.state.activeAssignmentByZone[.right])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.right], [])
    }

    func testSwitcherListHeightGrowsUntilSevenAndAHalfRows() {
        let metrics = SwitcherListMetrics(rowHeight: 54, rowSpacing: 8, maximumVisibleRows: 7.5)

        XCTAssertEqual(metrics.height(forItemCount: 0), 68)
        XCTAssertEqual(metrics.height(forItemCount: 1), 82)
        XCTAssertEqual(metrics.height(forItemCount: 3), 206)
        XCTAssertEqual(metrics.height(forItemCount: 20), 485)
        XCTAssertEqual(metrics.islandHeight(forItemCount: 3, includesZoneHeader: false), 206)
        XCTAssertEqual(metrics.islandHeight(forItemCount: 3, includesZoneHeader: true), 239)
    }

    func testSwitcherCardSelectionMetricsScaleVisualsWhileCompensatingTextRhythm() {
        for width: CGFloat in [492, 372, 252] {
            let metrics = SwitcherCardSelectionMetrics(
                size: CGSize(width: width, height: 54),
                progress: 1
            )
            let expectedScale: CGFloat = 1.025
            let expectedHorizontalOutset = width * (expectedScale - 1) / 2

            XCTAssertEqual(metrics.scale, expectedScale, accuracy: 0.000_001)
            XCTAssertEqual(
                metrics.horizontalOutset,
                expectedHorizontalOutset,
                accuracy: 0.000_001
            )
            XCTAssertEqual(metrics.verticalOutset, 0.675, accuracy: 0.000_001)
            XCTAssertEqual(
                metrics.leadingPadding,
                65 * expectedScale - expectedHorizontalOutset,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                metrics.trailingPadding,
                10 * expectedScale - expectedHorizontalOutset,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                metrics.compensatedTitleSpacing,
                1.7,
                accuracy: 0.000_001
            )
            XCTAssertEqual(
                metrics.compensatedBadgeVerticalPadding,
                2.875,
                accuracy: 0.000_001
            )
        }

        let midpoint = SwitcherCardSelectionMetrics(
            size: CGSize(width: 492, height: 54),
            progress: 0.5
        )
        XCTAssertEqual(midpoint.scale, 1.0125, accuracy: 0.000_001)
        XCTAssertEqual(midpoint.compensatedTitleSpacing, 1.85, accuracy: 0.000_001)
        XCTAssertEqual(midpoint.compensatedBadgeVerticalPadding, 2.9375, accuracy: 0.000_001)
    }

    func testZoneSwitcherProjectionRetainsEmptySiblingZones() {
        let zones = [
            Zone(id: .left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.27, height: 1)),
            Zone(id: .center, name: "Main", frame: NormalizedFrame(x: 0.27, y: 0, width: 0.46, height: 1)),
            Zone(id: .right, name: "Right", frame: NormalizedFrame(x: 0.73, y: 0, width: 0.27, height: 1))
        ]
        let item = SwitcherItem(
            assignmentID: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: 10,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            appName: "Example",
            title: "Document",
            icon: nil,
            zoneID: .center,
            zoneName: "Main",
            zoneFrame: zones[1].frame,
            isActive: true
        )

        let projected = ZoneSwitcherProjection().zones(
            profileZones: zones,
            orderedZoneIDs: [.left, .center, .right],
            itemsByZoneID: [.center: [item]]
        )

        XCTAssertEqual(projected.map(\.id), [.left, .center, .right])
        XCTAssertTrue(projected[0].items.isEmpty)
        XCTAssertEqual(projected[1].items, [item])
        XCTAssertTrue(projected[2].items.isEmpty)
    }

    func testZoneSwitcherCyclesOnlyTheSelectedZone() {
        let leftItem = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .left)
        let rightItem = switcherItem(assignmentID: UUID(), windowID: 20, zoneID: .right)
        let zones = [
            SwitcherZone(id: .left, name: "Left", frame: .full, items: [leftItem]),
            SwitcherZone(id: .center, name: "Main", frame: .full, items: []),
            SwitcherZone(id: .right, name: "Right", frame: .full, items: [rightItem])
        ]
        let scope = SwitcherCycleScope()

        XCTAssertEqual(
            scope.items(mode: .byZone, zones: zones, selectedZoneID: .right),
            [rightItem]
        )
        XCTAssertTrue(
            scope.items(mode: .byZone, zones: zones, selectedZoneID: .center).isEmpty
        )
        XCTAssertEqual(
            scope.items(mode: .allWindows, zones: zones, selectedZoneID: .center),
            [leftItem, rightItem]
        )
    }

    func testVerticalArrowScopeFinishesCurrentZoneThenContinuesDownTheColumn() {
        let mainFirst = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .main)
        let mainSecond = switcherItem(assignmentID: UUID(), windowID: 20, zoneID: .main)
        let overlayID = ZoneID(rawValue: "zone-4")
        let overlayFirst = switcherItem(assignmentID: UUID(), windowID: 30, zoneID: overlayID)
        let leftItem = switcherItem(assignmentID: UUID(), windowID: 40, zoneID: .left)
        let zones = [
            SwitcherZone(id: .left, name: "Left", frame: .full, items: [leftItem]),
            SwitcherZone(id: .main, name: "Main", frame: .full, items: [mainFirst, mainSecond]),
            SwitcherZone(id: overlayID, name: "Zone 4", frame: .full, items: [overlayFirst])
        ]
        let columns = [[ZoneID.left], [.main, overlayID]]
        let scope = SwitcherColumnCycleScope()

        XCTAssertEqual(
            scope.items(zones: zones, columns: columns, selectedZoneID: .main),
            [mainFirst, mainSecond, overlayFirst]
        )
        XCTAssertEqual(
            scope.items(zones: zones, columns: columns, selectedZoneID: overlayID),
            [mainFirst, mainSecond, overlayFirst]
        )
        XCTAssertFalse(
            scope.items(zones: zones, columns: columns, selectedZoneID: .main)
                .contains(leftItem)
        )
    }

    func testVerticalArrowScopeSkipsEmptyZones() {
        let mainItem = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .main)
        let overlayID = ZoneID(rawValue: "zone-4")
        let zones = [
            SwitcherZone(id: .main, name: "Main", frame: .full, items: [mainItem]),
            SwitcherZone(id: overlayID, name: "Zone 4", frame: .full, items: [])
        ]

        XCTAssertEqual(
            SwitcherColumnCycleScope().items(
                zones: zones,
                columns: [[.main, overlayID]],
                selectedZoneID: .main
            ),
            [mainItem]
        )
    }

    func testUndoRestoresSessionAssignmentWithoutRewindingLaterFocus() throws {
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1
        )
        let before = WindowAssignment(
            id: UUID(),
            identity: identity,
            zoneID: .left,
            placementsByProfileID: ["main": .unplaced(zoneID: .left)],
            retention: .session,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var after = before
        after.zoneID = .right
        after.placementsByProfileID["main"] = .zoneFit(zoneID: .right)
        after.retention = .durable
        let other = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.Other",
                processIdentifier: 43,
                cgWindowID: 101,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        var historyReducer = WindowHistoryReducer(state: .empty)
        historyReducer.recordFocus(assignmentID: after.id, zoneID: .right)
        historyReducer.recordFocus(assignmentID: other.id, zoneID: .center)

        let restored = WindowActionStateRestorer().restore(
            snapshotAssignment: before,
            liveIdentity: identity,
            liveFingerprint: identity.fingerprint,
            assignments: [after, other],
            history: historyReducer.state,
            now: Date(timeIntervalSince1970: 30)
        )

        let restoredAssignment = try XCTUnwrap(
            restored.assignments.first { $0.id == before.id }
        )
        XCTAssertEqual(restoredAssignment.zoneID, .left)
        XCTAssertEqual(restoredAssignment.retention, .session)
        XCTAssertEqual(
            restoredAssignment.placementsByProfileID["main"],
            .unplaced(zoneID: .left)
        )
        XCTAssertEqual(restored.history.globalRecency, [other.id, before.id])
        XCTAssertEqual(restored.history.assignmentRecencyByZone[.left], [before.id])
        XCTAssertNil(restored.history.assignmentRecencyByZone[.right])
    }

    func testGlobalAndZoneHistoryTrackOneHundredFocusTransitions() {
        let leftIDs = (0..<4).map { _ in UUID() }
        let rightIDs = (0..<3).map { _ in UUID() }
        var reducer = WindowHistoryReducer(state: .empty)

        for index in 0..<100 {
            if index.isMultiple(of: 2) {
                reducer.recordFocus(
                    assignmentID: leftIDs[(index / 2) % leftIDs.count],
                    zoneID: .left
                )
            } else {
                reducer.recordFocus(
                    assignmentID: rightIDs[(index / 2) % rightIDs.count],
                    zoneID: .right
                )
            }
        }

        XCTAssertEqual(reducer.state.globalRecency.first, rightIDs[(99 / 2) % rightIDs.count])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.left]?.first, leftIDs[(98 / 2) % leftIDs.count])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.right]?.first, rightIDs[(99 / 2) % rightIDs.count])
        XCTAssertEqual(Set(reducer.state.globalRecency), Set(leftIDs + rightIDs))
    }

    func testMovingAssignmentUpdatesZoneHistoryWithoutChangingGlobalRecency() {
        let moving = UUID()
        let remaining = UUID()
        var reducer = WindowHistoryReducer(state: ZoneStackState(
            globalRecency: [remaining, moving],
            activeAssignmentByZone: [.left: moving],
            assignmentRecencyByZone: [.left: [moving, remaining], .right: []]
        ))

        reducer.moveAssignment(moving, from: .left, to: .right)

        XCTAssertEqual(reducer.state.globalRecency, [remaining, moving])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.left], [remaining])
        XCTAssertNil(reducer.state.activeAssignmentByZone[.left])
        XCTAssertEqual(reducer.state.assignmentRecencyByZone[.right], [moving])
        XCTAssertEqual(reducer.state.activeAssignmentByZone[.right], moving)
    }

    func testWindowHistoryReducerMaintainsInvariantsAcrossDeterministicFuzzSequence() {
        let assignmentIDs = (0..<12).map { _ in UUID() }
        let zones: [ZoneID] = [.left, .main, .right]
        var activeIDs = Set(assignmentIDs)
        var zoneByID = Dictionary(uniqueKeysWithValues: assignmentIDs.map { ($0, ZoneID.main) })
        var reducer = WindowHistoryReducer(state: .empty)
        var seed: UInt64 = 0x5A17_2026

        func next(_ upperBound: Int) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(upperBound))
        }

        for assignmentID in assignmentIDs {
            reducer.recordFocus(assignmentID: assignmentID, zoneID: .main)
        }

        for _ in 0..<1_000 {
            let available = assignmentIDs.filter(activeIDs.contains)
            if next(5) == 0, available.count > 1 {
                activeIDs.remove(available[next(available.count)])
                reducer.prune(validAssignmentIDs: activeIDs)
                zoneByID = zoneByID.filter { activeIDs.contains($0.key) }
            } else {
                if activeIDs.isEmpty {
                    let revived = assignmentIDs[next(assignmentIDs.count)]
                    activeIDs.insert(revived)
                    zoneByID[revived] = .main
                }
                let current = assignmentIDs.filter(activeIDs.contains)
                let assignmentID = current[next(current.count)]
                if next(3) == 0 {
                    let source = zoneByID[assignmentID] ?? .main
                    let destination = zones[next(zones.count)]
                    reducer.moveAssignment(assignmentID, from: source, to: destination)
                    zoneByID[assignmentID] = destination
                } else {
                    reducer.recordFocus(
                        assignmentID: assignmentID,
                        zoneID: zoneByID[assignmentID] ?? .main
                    )
                }
            }

            XCTAssertEqual(reducer.state.globalRecency.count, Set(reducer.state.globalRecency).count)
            XCTAssertTrue(Set(reducer.state.globalRecency).isSubset(of: activeIDs))
            for (zoneID, history) in reducer.state.assignmentRecencyByZone {
                XCTAssertEqual(history.count, Set(history).count)
                XCTAssertTrue(Set(history).isSubset(of: activeIDs))
                XCTAssertTrue(history.allSatisfy { zoneByID[$0] == zoneID })
            }
            XCTAssertTrue(
                reducer.state.activeAssignmentByZone.values.allSatisfy(activeIDs.contains)
            )
        }
    }


}
