import AppKit
import XCTest
@testable import Zonal

@MainActor
private final class NativeOutlineEvents { var values: [OutlineWindowServerEvent] = [] }

final class OutlineWindowServerTests: XCTestCase {
    func testWindowServerPayloadRequiresKnownEventAndCompleteNonzeroWindowID() {
        var payload: UInt32 = 42
        withUnsafePointer(to: &payload) { pointer in
            let raw = UnsafeRawPointer(pointer)
            XCTAssertNil(OutlineWindowServerEvent.decode(number: 806, payload: nil, length: 4))
            XCTAssertNil(OutlineWindowServerEvent.decode(number: 806, payload: raw, length: 3))
            XCTAssertNil(OutlineWindowServerEvent.decode(number: 806, payload: raw, length: -1))
            XCTAssertNil(OutlineWindowServerEvent.decode(number: 999, payload: raw, length: 4))
            let events: [(UInt32, OutlineWindowServerEvent)] = [
                (804, .closed(42)), (806, .moved(42)), (807, .resized(42)),
                (808, .reordered(42)), (811, .levelChanged(42)), (815, .shown(42)), (816, .hidden(42))
            ]
            for (number, expected) in events {
                XCTAssertEqual(OutlineWindowServerEvent.decode(number: number, payload: raw, length: 4), expected)
            }
        }
        payload = 0
        withUnsafePointer(to: &payload) {
            XCTAssertNil(OutlineWindowServerEvent.decode(number: 804, payload: UnsafeRawPointer($0), length: 4))
        }
        XCTAssertEqual(OutlineWindowServerEvent.decode(number: 1508, payload: nil, length: 0), .frontApplicationChanged)
    }

    func testCallbackCopiesUnalignedPayloadBeforeItExpires() {
        var bytes: [UInt8] = [0xff, 0x78, 0x56, 0x34, 0x12]
        let event = bytes.withUnsafeBytes {
            OutlineWindowServerEvent.decode(number: 806, payload: $0.baseAddress!.advanced(by: 1), length: 4)
        }
        bytes = [0, 0, 0, 0, 0]
        XCTAssertEqual(event, .moved(0x12345678))
    }

    @MainActor
    func testStoppedOpaqueRouteRejectsLateEventsAndOldTargetIDs() {
        let routes = OutlineWindowServerRoutes.shared
        let token = routes.add { _ in XCTFail("No callback should be delivered by this test") }
        routes.observe(42, token: token)
        XCTAssertNotNil(routes.handler(for: token, event: .moved(42)))
        XCTAssertNil(routes.handler(for: token, event: .moved(43)))
        XCTAssertNotNil(routes.handler(for: token, event: .frontApplicationChanged))
        routes.observe(43, token: token)
        XCTAssertNil(routes.handler(for: token, event: .closed(42)))
        routes.remove(token)
        XCTAssertNil(routes.handler(for: token, event: .moved(43)))
        XCTAssertNil(routes.handler(for: token, event: .frontApplicationChanged))
        let next = routes.add { _ in }
        defer { routes.remove(next) }
        XCTAssertNotEqual(next, token)
        XCTAssertNil(routes.handler(for: token, event: .frontApplicationChanged))
    }

    @MainActor
    func testLiveWindowServerLifecycleAndTargetRelativeOrdering() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_WINDOW_SERVER_CHECK"] == "1" else {
            throw XCTSkip("Opt-in private WindowServer smoke test; use TEST_RUNNER_ZONAL_LIVE_WINDOW_SERVER_CHECK=1.")
        }
        let adapter = OutlineWindowServer()
        let events = NativeOutlineEvents()
        guard adapter.start(onEvent: { events.values.append($0) }) else {
            throw XCTSkip("Optional WindowServer notifications unavailable; public fallback remains active.")
        }
        defer { adapter.stop() }
        var target: NSWindow! = autoreleasepool {
            NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 160),
                     styleMask: [.titled], backing: .buffered, defer: false)
        }
        target.isReleasedWhenClosed = false
        target.level = .floating
        target.orderFrontRegardless()
        defer { target?.close() }
        let panel = NSPanel(contentRect: target.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        defer { panel.close() }
        let id = try XCTUnwrap(UInt32(exactly: target.windowNumber))
        let panelID = try XCTUnwrap(UInt32(exactly: panel.windowNumber))
        let primaryFrame = try XCTUnwrap(NSScreen.screens.first?.frame)
        func nativeStateMatches(expectedFrame: CGRect) -> Bool {
            guard adapter.level(for: panelID) == target.level,
                  let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
                  let panelIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == panelID }),
                  let targetIndex = windows.firstIndex(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
                  let dictionary = windows[panelIndex][kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { return false }
            let expected = CGRect(x: expectedFrame.minX, y: primaryFrame.maxY - expectedFrame.maxY,
                                  width: expectedFrame.width, height: expectedFrame.height)
            return panelIndex < targetIndex && abs(bounds.minX - expected.minX) < 1
                && abs(bounds.minY - expected.minY) < 1 && abs(bounds.width - expected.width) < 1
                && abs(bounds.height - expected.height) < 1
        }
        func verifyNativeState(expectedFrame: CGRect, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !nativeStateMatches(expectedFrame: expectedFrame), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(nativeStateMatches(expectedFrame: expectedFrame),
                          "WindowServer must apply the panel's current frame, target level and exact relative order", file: file, line: line)
        }
        XCTAssertTrue(adapter.observe(windowID: id))
        let initialLevelDeadline = ContinuousClock.now + .seconds(2)
        while adapter.level(for: id) != target.level, ContinuousClock.now < initialLevelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(adapter.level(for: id), target.level)
        XCTAssertTrue(adapter.order(panel: panel, relativeTo: id), adapter.lastOrderFailure ?? "ordering failed")
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, target.level)
        try await verifyNativeState(expectedFrame: panel.frame)
        let deadline = ContinuousClock.now + .seconds(2)
        target.setFrameOrigin(CGPoint(x: 140, y: 100))
        while !events.values.contains(.moved(id)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(events.values.contains(.moved(id)), "Native callback ABI must deliver the subscribed window's copied ID")
        target.level = .normal
        let changedLevelDeadline = ContinuousClock.now + .seconds(2)
        while adapter.level(for: id) != target.level, ContinuousClock.now < changedLevelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(adapter.level(for: id), target.level)
        XCTAssertTrue(adapter.order(panel: panel, relativeTo: id), adapter.lastOrderFailure ?? "ordering failed")
        XCTAssertEqual(panel.level, .normal)
        try await verifyNativeState(expectedFrame: panel.frame)
        // Exercise an unflushed AppKit move followed immediately by a transaction.
        panel.setFrameOrigin(CGPoint(x: 310, y: 240))
        let movedPanelFrame = panel.frame
        XCTAssertTrue(adapter.order(panel: panel, relativeTo: id), adapter.lastOrderFailure ?? "ordering failed")
        try await verifyNativeState(expectedFrame: movedPanelFrame)
        // A focus handoff between differently sized windows must never publish
        // the next origin with the previous size while AppKit's resize is pending.
        func quartzFrame() throws -> CGRect {
            let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionIncludingWindow, panelID) as? [[String: Any]])
            let bounds = try XCTUnwrap(rows.first?[kCGWindowBounds as String] as? NSDictionary)
            return try XCTUnwrap(CGRect(dictionaryRepresentation: bounds))
        }
        for next in [CGRect(x: 120, y: 150, width: 420, height: 280),
                     CGRect(x: 600, y: 300, width: 260, height: 180), movedPanelFrame] {
            let previous = try quartzFrame()
            panel.setFrame(next, display: true)
            XCTAssertTrue(adapter.order(panel: panel, relativeTo: id))
            let expected = CGRect(x: next.minX, y: primaryFrame.maxY - next.maxY,
                                  width: next.width, height: next.height)
            let immediate = try quartzFrame()
            XCTAssertTrue(immediate == previous || immediate == expected,
                          "Move and resize must stay together: \(previous) -> \(immediate) -> \(expected)")
            try await verifyNativeState(expectedFrame: next)
        }
        target.orderOut(nil)
        let hiddenDeadline = ContinuousClock.now + .seconds(2)
        while !events.values.contains(.hidden(id)), ContinuousClock.now < hiddenDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(events.values.contains(.hidden(id)), "Expected native hide callback for exact subscribed target; got \(events.values)")
        events.values.removeAll()
        target.orderFrontRegardless()
        let shownDeadline = ContinuousClock.now + .seconds(2)
        while !events.values.contains(.shown(id)), ContinuousClock.now < shownDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(events.values.contains(.shown(id)), "Expected native re-show callback for subscribed target")
        events.values.removeAll()
        target.close()
        target = nil
        let closedDeadline = ContinuousClock.now + .seconds(2)
        while !events.values.contains(.closed(id)) && !events.values.contains(.hidden(id)), ContinuousClock.now < closedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // AppKit can retain a hidden native window after public close. Either exact
        // lifecycle signal invalidates the outline; this smoke does not claim to
        // prove 804 destruction delivery for retained AppKit windows.
        XCTAssertTrue(events.values.contains(.closed(id)) || events.values.contains(.hidden(id)),
                      "Closing the exact target must deliver native hide or destruction; got \(events.values)")
        XCTAssertGreaterThan(adapter.callbackCount, 0)
        XCTAssertEqual(adapter.orderFailures, 0)
        adapter.stop()
        let count = events.values.count
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(events.values.count, count, "Stopped callbacks must not reach the released route")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ActiveWindowOutlineController(
            store: PersistenceStore(supportDirectory: directory), windowServer: adapter)
        controller.start()
        XCTAssertTrue(adapter.isRunning)
        XCTAssertTrue(adapter.observe(windowID: panelID))
        controller.start()
        XCTAssertEqual(adapter.observedWindowID, panelID, "Repeated start must preserve the active subscription")
        controller.stop()
        XCTAssertFalse(adapter.isRunning)
        XCTAssertNil(adapter.observedWindowID)
        controller.start()
        XCTAssertTrue(adapter.isRunning)
        controller.stop()
    }

    @MainActor
    func testUnavailablePrivateSymbolsPreservePublicFallback() {
        let adapter = OutlineWindowServer(loadPrivateSymbols: false)
        XCTAssertFalse(adapter.isSupported)
        XCTAssertFalse(adapter.start { _ in XCTFail("Unavailable adapter must not dispatch") })
        XCTAssertFalse(adapter.isRunning)
        XCTAssertFalse(adapter.observe(windowID: 42))
        XCTAssertNil(adapter.observedWindowID)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(adapter.order(panel: panel, relativeTo: 42))
        XCTAssertFalse(panel.isVisible)
        adapter.stop()
        XCTAssertFalse(adapter.isRunning)
    }
}
