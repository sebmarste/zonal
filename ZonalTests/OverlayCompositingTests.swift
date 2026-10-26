import AppKit
import XCTest
import SwiftUI
@testable import Zonal

@MainActor
final class OverlayCompositingTests: XCTestCase {
    func testSettingsNativePreviews() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_SETTINGS_PREVIEWS"] == "1" else {
            throw XCTSkip("Opt-in native Settings preview export")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zonal-settings-preview-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        var config = store.loadConfiguration()
        config.setupVersion = 1
        config.windowDefaultZoneRules = [WindowDefaultZoneRule(bundleIdentifier: "com.apple.finder", zoneID: config.profiles[0].mainZoneID)]
        config.excludedBundleIdentifiers = ["com.apple.Safari"]
        XCTAssertTrue(store.saveConfiguration(config))
        let output = URL(fileURLWithPath: "/tmp/zonal-settings-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for section in SettingsSection.allCases {
            let host = NSHostingView(rootView: SettingsView(store: store, initialSection: section))
            host.frame = CGRect(x: 0, y: 0, width: 1100, height: section == .general ? 1800 : 780)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(section.rawValue).png"))
            window.close()
        }
        let inspector = NSHostingView(rootView: ScrollView {
            WindowInspectorView(appContainer: .shared, zones: config.profiles[0].zones).padding(24)
        }.background(Color(nsColor: .windowBackgroundColor)))
        inspector.frame = CGRect(x: 0, y: 0, width: 900, height: 620)
        let inspectorWindow = NSWindow(contentRect: inspector.frame, styleMask: [.titled], backing: .buffered, defer: false)
        inspectorWindow.isReleasedWhenClosed = false
        inspectorWindow.contentView = inspector
        inspectorWindow.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        inspector.layoutSubtreeIfNeeded()
        let inspectorBitmap = try XCTUnwrap(inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds))
        inspector.cacheDisplay(in: inspector.bounds, to: inspectorBitmap)
        try XCTUnwrap(inspectorBitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("window-inspector.png"))
        inspectorWindow.close()
        let host = NSHostingView(rootView: BugReportView(report: SupportReport.draft(diagnostics: "Preview diagnostics"), detailedDiagnostics: { "Preview details" }))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("bug-report.png"))
    }

    @MainActor
    func testTabOrderingRefreshRunsSynchronouslyOnNativeOrderChanges() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var refreshes = 0
        controller.onWindowOrderingChanged = { refreshes += 1 }
        for event: OutlineWindowServerEvent in [.reordered(42), .frontApplicationChanged, .shown(42), .levelChanged(42)] {
            let before = refreshes
            controller.windowServerEvent(event)
            XCTAssertEqual(refreshes, before + 1)
        }
        controller.windowServerEvent(.moved(42))
        XCTAssertEqual(refreshes, 4)
    }

    func testSameFocusOrderingEventsRepairOutlineBeforeGeometryRefresh() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CGRect(x: screen.visibleFrame.minX + 50, y: screen.visibleFrame.minY + 50,
                           width: 400, height: 300)
        let native = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.orderFrontRegardless()
        defer { native.close() }
        let key = OutlineWindowKey(pid: ProcessInfo.processInfo.processIdentifier, number: UInt32(native.windowNumber))
        let bounds = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame)
        let reads = RadiusQueries()
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let server = OutlineWindowServer(loadPrivateSymbols: false)
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: {
            // Hold the next bounds read so ordering cannot depend on its completion.
            if reads.record(key.number) == 2 { resume.wait() }
            return [key: bounds]
        }, windowServer: server)
        defer { controller.stop() }
        var window = managedWindow(cgWindowID: key.number, observedOrder: 0)
        window.identity.processIdentifier = key.pid
        controller.update(window: window)
        try await waitForOutline(frame: frame, controller: controller)
        let panel = try XCTUnwrap(controller.panel)
        func isAbove(_ first: NSWindow, _ second: NSWindow) throws -> Bool {
            let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
            func index(_ window: NSWindow) throws -> Int {
                try XCTUnwrap(rows.firstIndex { ($0[kCGWindowNumber as String] as? UInt32) == UInt32(window.windowNumber) })
            }
            return try index(first) < index(second)
        }
        var expectedOrderAttempts = server.orderFailures
        controller.onWindowOrderingChanged = {
            // Missing private symbols exercise AppKit fallback and count repair attempts.
            XCTAssertEqual(server.orderFailures, expectedOrderAttempts,
                           "Outline repair must precede tab layout and WindowServer queries")
        }
        for event: OutlineWindowServerEvent in [.reordered(key.number), .shown(key.number), .levelChanged(key.number)] {
            try await Task.sleep(for: .milliseconds(30))
            native.order(.above, relativeTo: panel.windowNumber)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(try isAbove(native, panel))
            expectedOrderAttempts += 1
            controller.windowServerEvent(event)
            XCTAssertTrue(panel.isVisible)
            let deadline = ContinuousClock.now + .seconds(1)
            while try !isAbove(panel, native), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(try isAbove(panel, native), "\(event): outline order must recover while the bounds read is blocked")
        }
        controller.onWindowOrderingChanged = nil
        controller.placementStarted(for: .quartz(processIdentifier: key.pid, windowNumber: key.number))
        controller.windowServerEvent(.reordered(key.number))
        XCTAssertFalse(panel.isVisible, "Reordering must not reveal an outline during placement")
    }

    func testOutlinePanelRetainsStrokeMarginAcrossMenuBarBoundaryAfterOrdering() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outline-boundary-\(UUID())")
        let store = PersistenceStore(supportDirectory: root)
        store.bootstrap()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ActiveWindowOutlineController(store: store)
        let panel = controller.makePanel()
        defer { panel.orderOut(nil) }
        for width: CGFloat in [1, 2, 8] {
            let outset = OutlineStrokeGeometry.effectOutset(for: width)
            let target = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY - 200, width: 400, height: 200)
            let expected = target.insetBy(dx: -outset, dy: -outset)
            panel.setFrame(expected, display: true)
            panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(panel.frame, expected, "Ordering must not move the stroke margin below the menu bar")
            let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionIncludingWindow, UInt32(panel.windowNumber)) as? [[String: Any]])
            let row = try XCTUnwrap(rows.first)
            let bounds = try XCTUnwrap(row[kCGWindowBounds as String] as? [String: Any])
            let actual = try XCTUnwrap(CGRect(dictionaryRepresentation: bounds as CFDictionary))
            XCTAssertEqual(actual, WindowOutlineCoordinatePolicy().appKitFrame(for: expected, mainScreenFrame: screen.frame))
        }
    }

    private func waitForOutline(frame: CGRect, controller: ActiveWindowOutlineController) async throws {
        let outset = OutlineStrokeGeometry.effectOutset(for: 3)
        let frame = frame.insetBy(dx: -outset, dy: -outset)
        let deadline = ContinuousClock.now + .seconds(3)
        while (controller.panel?.frame != frame || controller.panel?.isVisible != true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.panel?.frame, frame)
        XCTAssertEqual(controller.panel?.isVisible, true)
    }

    private final class VisibleFramesState: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [OutlineWindowKey: CGRect] = [:]
        private var queries = 0
        var count: Int { lock.withLock { queries } }
        func replace(_ frames: [OutlineWindowKey: CGRect]) { lock.withLock { self.frames = frames } }
        func read() -> [OutlineWindowKey: CGRect] {
            lock.withLock {
                queries += 1
                return frames
            }
        }
    }

    private func waitForQuery(_ state: VisibleFramesState) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while state.count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(state.count, 0)
    }

    func testFallbackRequestsFocusEvenWithoutAnOutlineAndStopsCleanly() async throws {
        var requests = 0
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), visibilityCheckInterval: 0.02, onFocusNeedsRefresh: { requests += 1 })
        controller.start()
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertGreaterThan(requests, 0)
        XCTAssertNil(controller.focusedKey)
        controller.stop()
        let stopped = requests
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests, stopped)
    }

    func testGeometryBurstKeepsOutlineVisibleAndReadsLatestFrameOnce() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frames = VisibleFramesState()
        let original = CGRect(x: 20, y: 40, width: 400, height: 300)
        frames.replace([key: original])
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.stop() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.update(window: window)
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: original, mainScreenFrame: screen.frame), controller: controller)
        let before = frames.count
        var latest = original
        for offset in 1...20 {
            latest = original.offsetBy(dx: CGFloat(offset), dy: CGFloat(offset))
            frames.replace([key: latest])
            controller.updateFrame(for: window)
        }
        XCTAssertEqual(controller.panel?.isVisible, true)
        XCTAssertEqual(frames.count, before)
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: latest, mainScreenFrame: screen.frame), controller: controller)
        XCTAssertEqual(frames.count, before + 1)
    }

    func testConfirmedDragHidesOutlineUntilReleaseAndReadsFinalFrame() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frames = VisibleFramesState()
        let original = CGRect(x: 20, y: 40, width: 400, height: 300)
        frames.replace([key: original])
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.stop() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.update(window: window)
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: original, mainScreenFrame: screen.frame), controller: controller)
        let before = frames.count
        controller.windowDragChanged(window.id)
        XCTAssertEqual(controller.panel?.isVisible, false)
        let final = original.offsetBy(dx: 150, dy: 70)
        frames.replace([key: final])
        for _ in 0..<20 {
            controller.updateFrame(for: window)
            controller.windowServerEvent(.moved(1))
            controller.update(window: window)
        }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(controller.panel?.isVisible, false)
        XCTAssertEqual(frames.count, before)
        controller.windowDragChanged(nil)
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: final, mainScreenFrame: screen.frame), controller: controller)
        XCTAssertEqual(frames.count, before + 1)
    }

    func testVisibilityFallbackHidesClosedTargetWithoutAXEvent() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let frames = VisibleFramesState()
        frames.replace([key: frame])
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() }, visibilityCheckInterval: 0.02)
        defer { controller.stop() }
        controller.update(window: managedWindow(cgWindowID: 1, observedOrder: 0))
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame), controller: controller)
        controller.start()
        frames.replace([:])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.panel?.isVisible, false)
        XCTAssertEqual(controller.focusedKey, key)
    }

    func testServerEventsRejectOtherWindowsAndHideOldAppImmediately() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        var frontmost = true
        var focusRequests = 0
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { [key: frame] },
        isFrontmost: { _ in frontmost }, onFocusNeedsRefresh: { focusRequests += 1 })
        defer { controller.stop() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.update(window: window)
        try await waitForOutline(frame: WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame), controller: controller)
        controller.windowServerEvent(.closed(99))
        XCTAssertEqual(controller.panel?.isVisible, true)
        frontmost = false
        controller.windowServerEvent(.frontApplicationChanged)
        XCTAssertEqual(controller.panel?.isVisible, false)
        XCTAssertEqual(focusRequests, 1)
        controller.update(window: window)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(controller.panel?.isVisible, false)
    }

    func testCloseEventCancelsQueuedGeometryAndCannotReshowOldTarget() async throws {
        let frames = VisibleFramesState()
        let key = OutlineWindowKey(pid: 42, number: 1)
        frames.replace([key: CGRect(x: 20, y: 40, width: 400, height: 300)])
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.stop() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.update(window: window)
        controller.updateFrame(for: window)
        controller.windowServerEvent(.closed(1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.focusedKey)
        XCTAssertNotEqual(controller.panel?.isVisible, true)
    }

    func testOutlineRetriesTransientMissingFrameWithoutAnotherFocusEvent() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let expected = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame)
        let frames = VisibleFramesState()
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.hide() }
        controller.resynchronize(window: managedWindow(cgWindowID: 1, observedOrder: 0))
        try await waitForQuery(frames)
        frames.replace([key: frame])
        try await waitForOutline(frame: expected, controller: controller)
        XCTAssertGreaterThanOrEqual(frames.count, 2)
    }

    func testTransientFrameRetryCannotShowOutlineDuringPlacement() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let expected = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame)
        let frames = VisibleFramesState()
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.hide() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.resynchronize(window: window)
        try await waitForQuery(frames)
        controller.placementStarted(for: window.id)
        frames.replace([key: frame])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(controller.isAwaitingPlacement)
        XCTAssertNotEqual(controller.panel?.isVisible, true)
        controller.placementSettled(for: window.id)
        try await waitForOutline(frame: expected, controller: controller)
    }

    func testHideCancelsPendingTransientFrameRetry() async throws {
        let frames = VisibleFramesState()
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        controller.resynchronize(window: managedWindow(cgWindowID: 1, observedOrder: 0))
        try await waitForQuery(frames)
        controller.hide()
        frames.replace([OutlineWindowKey(pid: 42, number: 1): CGRect(x: 20, y: 40, width: 400, height: 300)])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotEqual(controller.panel?.isVisible, true)
        XCTAssertEqual(frames.count, 1)
    }

    func testRecentExactQuartzFramesKeepPanelVisibleThroughSameAppFocusHandoff() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let first = managedWindow(cgWindowID: 1, observedOrder: 0)
        let second = managedWindow(cgWindowID: 2, observedOrder: 1)
        let firstFrame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let secondFrame = CGRect(x: 500, y: 40, width: 450, height: 350)
        let frames = VisibleFramesState()
        frames.replace([OutlineWindowKey(pid: 42, number: 1): firstFrame,
                        OutlineWindowKey(pid: 42, number: 2): secondFrame])
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { frames.read() })
        defer { controller.stop() }
        controller.prewarm(windows: [first, second])
        controller.update(window: first)
        let convert = WindowOutlineCoordinatePolicy()
        try await waitForOutline(frame: convert.appKitFrame(for: firstFrame, mainScreenFrame: screen.frame), controller: controller)
        try await Task.sleep(for: .milliseconds(30))
        controller.refresh()
        try await Task.sleep(for: .milliseconds(30))
        let panel = try XCTUnwrap(controller.panel)
        controller.update(window: second)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertTrue(panel.isVisible, "A known same-app focus handoff must not order out the outline")
        let outset = OutlineStrokeGeometry.effectOutset(for: 3)
        XCTAssertEqual(panel.frame, convert.appKitFrame(for: secondFrame, mainScreenFrame: screen.frame).insetBy(dx: -outset, dy: -outset))
        // Movement of a background window invalidates its handoff cache too.
        controller.update(window: first)
        controller.updateFrame(for: second)
        controller.update(window: second)
        XCTAssertFalse(panel.isVisible)
        try await waitForOutline(frame: convert.appKitFrame(for: secondFrame, mainScreenFrame: screen.frame), controller: controller)
        // An expired frame cannot be used to keep a stale outline visible.
        try await Task.sleep(for: .milliseconds(250))
        controller.update(window: first)
        XCTAssertFalse(panel.isVisible)
    }

    func testEnvironmentResyncRepairsSameFocusedOutlineWithoutFocusChange() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let expected = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame)
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { [key: frame] })
        defer { controller.hide() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.resynchronize(window: window)
        try await waitForOutline(frame: expected, controller: controller)
        let shifted = expected.insetBy(dx: 3, dy: 1)
        controller.panel?.setFrame(shifted, display: true)
        controller.placementVerified(for: window.id, frame: frame.insetBy(dx: 3, dy: 1))
        controller.resynchronize(window: window)
        XCTAssertEqual(controller.focusedKey, key)
        XCTAssertNil(controller.cornerRadii[key])
        try await waitForOutline(frame: expected, controller: controller)
    }

    func testEnvironmentResyncDoesNotShowOutlineBeforePlacementSettles() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 20, y: 40, width: 400, height: 300)
        let expected = WindowOutlineCoordinatePolicy().appKitFrame(for: frame, mainScreenFrame: screen.frame)
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { _ in 12 }, visibleFramesProvider: { [key: frame] })
        defer { controller.hide() }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.resynchronize(window: window)
        try await waitForOutline(frame: expected, controller: controller)
        controller.placementStarted(for: window.id)
        controller.resynchronize(window: window)
        XCTAssertTrue(controller.isAwaitingPlacement)
        XCTAssertEqual(controller.panel?.isVisible, false)
        controller.placementSettled(for: window.id)
        try await waitForOutline(frame: expected, controller: controller)
    }

    func testDragOverlayPrototypeReferenceRenders() throws {
        let canvas = CGRect(x: 0, y: 0, width: 1400, height: 850)
        let zones = [CGRect(x: 16, y: 24, width: 290, height: 810),
                     CGRect(x: 318, y: 24, width: 764, height: 810),
                     CGRect(x: 1094, y: 24, width: 290, height: 810)]
        let ids: [ZoneID] = [.left, .main, .right]
        let names = ["Notes", "Main", "Reference"]
        let resolver = HotZoneResolver()
        let triggers = resolver.dropTargets(for: zip(ids, zones).map { ZoneFrame(zoneID: $0.0, frame: $0.1) })
        for state in ["idle", "keep-size", "fit"] {
            let targets = (0..<3).map { index in
                HotZoneTarget(zoneID: ids[index], name: names[index],
                    zoneFrame: NormalizedFrame(x: zones[index].minX / canvas.width, y: 0,
                                               width: zones[index].width / canvas.width, height: 1),
                    previewFrame: zones[index], frame: triggers[index].frame,
                    isMaximizeTargetActive: state == "fit" && index == 1,
                    isMembershipActive: state != "idle" && index == 1)
            }
            let scene = ZStack {
                LinearGradient(colors: [Color(red: 0.82, green: 0.87, blue: 0.86),
                                        Color(red: 0.45, green: 0.56, blue: 0.58)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 640, height: 500)
                    .overlay(Text("Dragged window").foregroundStyle(.secondary))
                    .offset(x: -30, y: 60)
                HotZoneOverlayView(coordinateDisplayFrame: canvas, targets: targets)
            }
            .frame(width: canvas.width, height: canvas.height)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: scene)
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/zonal-drag-ui-\(state).png"))
            XCTAssertEqual(image.width, 1400)
            XCTAssertEqual(image.height, 850)
        }
    }

    func testLiveDragOverlayCompositing() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_OVERLAY_CHECK"] == "1" else {
            throw XCTSkip("Opt-in runtime drag preview; use TEST_RUNNER_ZONAL_LIVE_OVERLAY_CHECK=1.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let background = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.6, alpha: 1)
        background.orderFrontRegardless()
        defer { background.close() }
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let profile = DefaultProfiles.main
        let zones = profile.zones.map { ZoneFrame(zoneID: $0.id, frame: $0.frame.rect(in: bounds)) }
        let zone = try XCTUnwrap(zones.first)
        let overlay = HotZoneOverlayController()
        overlay.show(profile: profile, zoneFrames: zones, coordinateDisplayFrame: bounds,
                     windowFrame: screen.frame, dropIntent: .zoneFit(zone.zoneID))
        defer { overlay.hide() }
        try await Task.sleep(for: .milliseconds(500))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "/tmp/zonal-drag-ui-live.png"]
        try capture.run()
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else {
            throw XCTSkip("Runtime visual inspection blocked: desktop capture is unavailable.")
        }
    }

    private final class RadiusQueries: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt32] = []
        private var mainThreadCalls = 0
        var numbers: [UInt32] { lock.withLock { calls } }
        var ranOnMain: Bool { lock.withLock { mainThreadCalls > 0 } }
        func record(_ number: UInt32) -> Int {
            lock.withLock {
                calls.append(number)
                if Thread.isMainThread { mainThreadCalls += 1 }
                return calls.count
            }
        }
    }

    private func waitForRadius(_ radius: CGFloat, key: OutlineWindowKey,
                               controller: ActiveWindowOutlineController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.cornerRadii[key] != radius, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.cornerRadii[key], radius)
    }

    func testPrewarmQueriesVisibleWindowsOffMainOnlyOnceWithoutActivatingThem() async throws {
        let queries = RadiusQueries()
        let first = OutlineWindowKey(pid: 42, number: 1)
        let second = OutlineWindowKey(pid: 42, number: 2)
        let frames = [first: CGRect(x: 0, y: 30, width: 800, height: 600),
                      second: CGRect(x: 800, y: 30, width: 800, height: 600)]
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { number in
            _ = queries.record(number)
            return number == 1 ? 12 : nil
        }, visibleFramesProvider: { frames })
        let windows = (1...3).map { managedWindow(cgWindowID: UInt32($0), observedOrder: $0) }
        controller.prewarm(windows: windows)
        controller.prewarm(windows: windows)
        try await waitForRadius(12, key: first, controller: controller)
        try await waitForRadius(10, key: second, controller: controller)
        controller.prewarm(windows: [windows[0], windows[1]])
        XCTAssertEqual(queries.numbers.sorted(), [1, 2])
        XCTAssertFalse(queries.ranOnMain)
        XCTAssertNil(controller.focusedKey)
        controller.prewarm(windows: [windows[0]])
        XCTAssertNil(controller.cornerRadii[second])
    }

    func testGeometryInvalidationRejectsInFlightPrewarmAndAllowsFreshQuery() async throws {
        let queries = RadiusQueries()
        let started = expectation(description: "first radius lookup started")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let key = OutlineWindowKey(pid: 42, number: 1)
        let frame = CGRect(x: 0, y: 30, width: 800, height: 600)
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ), radiusQuery: { number in
            if queries.record(number) == 1 {
                started.fulfill()
                _ = resume.wait(timeout: .now() + 3)
                return 12
            }
            return 18
        }, visibleFramesProvider: { [key: frame] })
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        controller.prewarm(windows: [window])
        await fulfillment(of: [started], timeout: 3)
        controller.updateFrame(for: window)
        controller.prewarm(windows: [window])
        resume.signal()
        try await waitForRadius(18, key: key, controller: controller)
        XCTAssertEqual(queries.numbers, [1, 1])
    }

    func testVerifiedOutlineBoundsExpireAndRejectClockReversal() {
        let frame = CGRect(x: 10, y: 30, width: 800, height: 600)
        let verified = VerifiedOutlineFrame(frame: frame, verifiedAt: 100)
        XCTAssertEqual(verified.freshFrame(at: 100), frame)
        XCTAssertEqual(verified.freshFrame(at: 100.1), frame)
        XCTAssertNil(verified.freshFrame(at: 100.3))
        XCTAssertNil(verified.freshFrame(at: 99))
    }
    func testClosedSettingsReleasesContentOnlyAfterSuccessfulSave() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: Text("Draft"))
        host.sizingOptions = []
        window.contentViewController = host
        defer { window.close() }
        SettingsWindowController.discardClosedContent(in: window, hasUnsavedDraft: true)
        XCTAssertTrue(window.contentViewController === host, "A failed save must preserve the draft for Retry")
        window.orderFrontRegardless()
        SettingsWindowController.discardClosedContent(in: window, hasUnsavedDraft: false)
        XCTAssertTrue(window.contentViewController === host, "Reopening before deferred cleanup must preserve the visible tree")
        window.orderOut(nil)
        SettingsWindowController.discardClosedContent(in: window, hasUnsavedDraft: false)
        XCTAssertNil(window.contentViewController)
        XCTAssertNil(window.contentView)
    }

    private final class SettingsWindowStub: NSWindow {
        var reportsKey = true
        override var isKeyWindow: Bool { reportsKey }
        override var windowNumber: Int { 123 }
    }

    func testSettingsOutlineUsesNativeFocusWithoutAccessibility() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ))
        let window = SettingsWindowStub(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        controller.update(settingsWindow: window)
        XCTAssertEqual(controller.focusedKey, OutlineWindowKey(
            pid: ProcessInfo.processInfo.processIdentifier, number: 123
        ))
        controller.update(settingsWindow: window, geometryChanged: true)
        XCTAssertEqual(controller.focusedKey?.number, 123)
        window.reportsKey = false
        controller.update(settingsWindow: window)
        XCTAssertNil(controller.focusedKey)
        controller.hide()
    }

    func testOutlinePanelIsTransparentAndNeverAnimates() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ))
        let panel = controller.makePanel()
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testNativeSettingsFocusLossRejectsStaleTrackerUpdates() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ))
        let window = SettingsWindowStub(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        var staleSettings = managedWindow(cgWindowID: 123, observedOrder: 0)
        staleSettings.identity.processIdentifier = ProcessInfo.processInfo.processIdentifier
        controller.update(settingsWindow: window, isFocused: true)
        XCTAssertEqual(controller.focusedKey?.number, 123)
        // AppKit's loss notification wins even if the key-window property has not caught up.
        controller.update(settingsWindow: window, isFocused: false)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertNil(controller.focusedKey)
        controller.update(window: staleSettings)
        XCTAssertNil(controller.focusedKey)
        let other = managedWindow(cgWindowID: 456, observedOrder: 1)
        controller.update(window: other)
        controller.update(window: staleSettings)
        XCTAssertEqual(controller.focusedKey, OutlineWindowKey(pid: 42, number: 456))
        controller.update(settingsWindow: window, isFocused: true)
        XCTAssertEqual(controller.focusedKey?.number, 123)
        controller.hide()
    }

    func testSettingsOutlineSharesWindowOrderingAndDetachesForOtherApps() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ))
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        let panel = controller.makePanel()
        controller.configureOrdering(of: panel, parent: window)
        XCTAssertTrue(panel.parent === window)
        XCTAssertEqual(panel.level, window.level)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        controller.configureOrdering(of: panel, parent: window)
        XCTAssertEqual(window.childWindows?.count, 1)
        controller.configureOrdering(of: panel, parent: nil)
        XCTAssertNil(panel.parent)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.backgroundColor, .clear)
    }

    func testControlledPlacementKeepsOutlineHiddenUntilTheFocusedWindowSettles() {
        let controller = ActiveWindowOutlineController(store: PersistenceStore(
            supportDirectory: URL(fileURLWithPath: "/tmp/unused-outline-test-\(UUID())")
        ))
        let window = SettingsWindowStub(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: true)
        let focused = LiveWindowID.quartz(processIdentifier: ProcessInfo.processInfo.processIdentifier, windowNumber: 123)
        let other = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 456)
        controller.update(settingsWindow: window)
        controller.placementStarted(for: other)
        XCTAssertFalse(controller.isAwaitingPlacement)
        controller.placementStarted(for: focused)
        controller.placementVerified(for: focused, frame: CGRect(x: 10, y: 30, width: 800, height: 600))
        controller.update(settingsWindow: window)
        controller.refresh()
        XCTAssertTrue(controller.isAwaitingPlacement)
        controller.placementSettled(for: other)
        XCTAssertTrue(controller.isAwaitingPlacement)
        controller.placementSettled(for: focused)
        XCTAssertFalse(controller.isAwaitingPlacement)
        controller.placementStarted(for: focused)
        window.reportsKey = false
        controller.update(settingsWindow: window)
        XCTAssertFalse(controller.isAwaitingPlacement)
        XCTAssertNil(controller.focusedKey)
        controller.placementSettled(for: focused)
        XCTAssertNil(controller.focusedKey)
        controller.hide()
    }

    func testEdgeCenteredOutlineRendersTransparentCornersAndUnclippedEdges() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let view = ActiveWindowOutlineView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        view.strokeColor = .white
        view.strokeWidth = 4
        view.cornerRadius = 16
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        for (x, y) in [(0, 0), (79, 0), (0, 59), (79, 59), (40, 30)] {
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
        }
        for (x, y) in [(40, 1), (40, 58), (1, 30), (78, 30), (40, 4), (40, 55)] {
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.95)
        }
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 40, y: 6)).alphaComponent, 0)
    }

    func testLiveOutlineAndFeedbackCorners() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_OVERLAY_CHECK"] == "1" else {
            throw XCTSkip("Opt-in live preview; use TEST_RUNNER_ZONAL_LIVE_OVERLAY_CHECK=1.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let root = URL(fileURLWithPath: "/tmp/zonal-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersistenceStore(supportDirectory: root)
        store.bootstrap()
        let background = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        background.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.6, alpha: 1)
        background.isReleasedWhenClosed = false
        background.orderFrontRegardless()
        defer { background.close() }
        let controller = ActiveWindowOutlineController(store: store)
        let panel = controller.makePanel()
        let frame = CGRect(x: screen.frame.midX - 204, y: screen.frame.midY - 144, width: 408, height: 288)
        let settings = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.setFrame(frame, display: true)
        settings.orderFrontRegardless()
        defer { settings.close() }
        let outset = OutlineStrokeGeometry.effectOutset(for: 4)
        let panelFrame = frame.insetBy(dx: -outset, dy: -outset)
        let view = ActiveWindowOutlineView(frame: CGRect(origin: .zero, size: panelFrame.size))
        view.cornerRadius = WindowCornerRadiusReader().radius(for: UInt32(settings.windowNumber)) ?? 10
        view.strokeColor = .white
        view.strokeWidth = 4
        panel.contentView = view
        panel.setFrame(panelFrame, display: true)
        controller.configureOrdering(of: panel, parent: settings)
        panel.order(.above, relativeTo: settings.windowNumber)
        defer { panel.orderOut(nil); settings.removeChildWindow(panel) }
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.backgroundColor, .clear)
        let hud = WindowActionNotificationController(store: store)
        hud.show(WindowActionNotification(title: "Overlay preview", detail: "Check rounded corners and the soft shadow",
                                    symbolName: "checkmark", tone: .success, actionTitle: "Undo"), onAction: nil)
        defer { hud.hide() }
        try await Task.sleep(for: .milliseconds(500))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "/tmp/zonal-overlay-compositing.png"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("Live visual inspection blocked: the desktop or Screen Recording permission is unavailable.")
        }
    }
}
