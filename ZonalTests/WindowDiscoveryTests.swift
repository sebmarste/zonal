import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

final class WindowDiscoveryTests: XCTestCase {
    func testAXExclusionReasonsPreserveTheExactInclusionPolicy() {
        var snapshot = AXWindowSnapshot(element: AXUIElementCreateApplication(42), attributes: [
            kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: "AXStandardWindow"
        ], directID: 1)
        XCTAssertTrue(snapshot.isStandard)
        XCTAssertNil(snapshot.exclusionReason)
        for (subrole, reason) in [(kAXUnknownSubrole, "unknown-subrole"),
                                  ("AXSystemDialog", "system-dialog"),
                                  ("AXFloatingWindow", "floating-window")] {
            snapshot.attributes[kAXSubroleAttribute] = subrole
            XCTAssertFalse(snapshot.isStandard)
            XCTAssertEqual(snapshot.exclusionReason, reason)
        }
        snapshot.attributes[kAXRoleAttribute] = "AXApplication"
        XCTAssertEqual(snapshot.exclusionReason, "non-window-role")
        snapshot.attributes[kAXRoleAttribute] = kAXWindowRole
        snapshot.attributes[kAXSubroleAttribute] = "AXDialog"
        snapshot.attributes["AXIdentifier"] = "_NS:8"
        snapshot.attributes[kAXTitleAttribute] = " Window "
        XCTAssertEqual(snapshot.exclusionReason, "transient-host")
        snapshot.attributes[kAXTitleAttribute] = "Settings"
        XCTAssertTrue(snapshot.isStandard, "Real dialogs must remain eligible")
        snapshot.attributes[kAXSubroleAttribute] = nil
        XCTAssertTrue(snapshot.isStandard)
    }

    func testRejectionDiagnosticsAreBoundedCountsWithoutWindowContent() {
        var diagnostics = WindowScanDiagnostics()
        diagnostics.enumeratedAXWindowCount = 8
        diagnostics.onScreenNativeWindowCount = 6
        for _ in 0..<1_000 {
            diagnostics.recordRejection(bundleIdentifier: "test.editor", reason: "unknown-subrole")
        }
        diagnostics.recordRejection(bundleIdentifier: "test.browser", reason: "destroyed-element")
        XCTAssertEqual(diagnostics.rejectedWindowCounts.count, 2)
        XCTAssertEqual(diagnostics.rejectionSummary,
                       "test.browser:destroyed-element=1, test.editor:unknown-subrole=1000")
        XCTAssertTrue(diagnostics.rejectedAllVisibleWindows)
        diagnostics.eligibleAXWindowCount = 1
        XCTAssertFalse(diagnostics.rejectedAllVisibleWindows)
        diagnostics.eligibleAXWindowCount = 0
        diagnostics.enumeratedAXWindowCount = 0
        XCTAssertFalse(diagnostics.rejectedAllVisibleWindows, "Failed enumeration is a different failure")
        diagnostics.enumeratedAXWindowCount = 8
        diagnostics.onScreenNativeWindowCount = 0
        XCTAssertFalse(diagnostics.rejectedAllVisibleWindows, "An empty desktop is not this failure")
    }

    func testWindowHitTestSkipsOwnOutlineButKeepsForeignOcclusion() {
        func row(pid: pid_t, id: UInt32, frame: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: id,
             kCGWindowLayer as String: 0, kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let outline = row(pid: 10, id: 99, frame: frame.insetBy(dx: -2, dy: -2))
        let target = row(pid: 42, id: 1, frame: frame)
        let point = CGPoint(x: 200, y: 110)
        XCTAssertEqual(WindowHitTestPolicy.windowID(in: [outline, target], at: point, excludingProcessIdentifier: 10), 1)
        XCTAssertEqual(WindowHitTestPolicy.windowID(in: [outline, target], excludingProcessIdentifier: 10), 1)
        XCTAssertNil(WindowHitTestPolicy.windowID(in: [outline], at: point, excludingProcessIdentifier: 10))
        let foreign = row(pid: 43, id: 2, frame: frame)
        XCTAssertEqual(WindowHitTestPolicy.windowID(in: [outline, foreign, target], at: point, excludingProcessIdentifier: 10), 2)
        XCTAssertNil(WindowHitTestPolicy.windowID(in: [outline, target], at: CGPoint(x: 0, y: 0), excludingProcessIdentifier: 10))
    }

    @MainActor
    func testOutlineFocusRecoveryCoalescesPendingReadsAndDoesNotRecordUnchangedFocus() {
        var active = managedWindow(cgWindowID: 1, observedOrder: 0)
        active.element = AXUIElementCreateApplication(42)
        var reads: [(AXFocusRead) -> Void] = []
        let registry = WindowRegistry(inventoryProvider: { $0([active], active.element) },
                                      focusedElementProvider: { reads.append($0) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { active },
                                    frontmostProcessIdentifier: { 42 })
        tracker.start()
        defer { tracker.stop() }
        tracker.captureFocusedWindow(origin: "initial")
        var focusChanges = 0
        tracker.onFocusChanged = { _ in focusChanges += 1 }
        var projected: [LiveWindowID?] = []
        for _ in 0..<100 { tracker.refreshOutlineFocus { projected.append($0?.id) } }
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(registry.outlineFocusProcessIdentifier, 42)
        reads[0](.window(active.element))
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        XCTAssertEqual(focusChanges, 0)
        XCTAssertEqual(projected, [active.id])
        tracker.refreshOutlineFocus { projected.append($0?.id) }
        XCTAssertEqual(reads.count, 2)
        reads[1](.incomplete)
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        XCTAssertEqual(focusChanges, 0)
        XCTAssertEqual(projected, [active.id])
    }

    @MainActor
    func testOutlineFocusRecoveryRejectsActivationAndStopRaces() {
        var active = managedWindow(cgWindowID: 1, observedOrder: 0)
        active.element = AXUIElementCreateApplication(42)
        var frontmost: pid_t? = 42
        var reads: [(AXFocusRead) -> Void] = []
        let registry = WindowRegistry(inventoryProvider: { $0([active], active.element) },
                                      focusedElementProvider: { reads.append($0) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { active },
                                    frontmostProcessIdentifier: { frontmost })
        tracker.start()
        tracker.captureFocusedWindow(origin: "initial")
        var projected = 0
        tracker.refreshOutlineFocus { _ in projected += 1 }
        frontmost = 43
        reads[0](AXFocusRead.none)
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        tracker.refreshOutlineFocus { _ in projected += 1 }
        frontmost = 42
        _ = tracker.beginAXFocus(processIdentifier: 42)
        reads[1](AXFocusRead.none)
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        tracker.refreshOutlineFocus { _ in projected += 1 }
        tracker.stop()
        reads[2](.window(active.element))
        tracker.refreshOutlineFocus { _ in projected += 1 }
        XCTAssertEqual(tracker.focusedWindowID, active.id, "Stopped recovery must not mutate the retained snapshot")
        XCTAssertEqual(reads.count, 3)
        XCTAssertEqual(projected, 0)
    }

    @MainActor
    func testOutlineFocusRecoveryFindsMissedActivationFromExactCachedElement() {
        var first = managedWindow(cgWindowID: 1, observedOrder: 0)
        first.element = AXUIElementCreateApplication(42)
        var second = managedWindow(cgWindowID: 2, observedOrder: 0)
        second.element = AXUIElementCreateApplication(43)
        second.identity.processIdentifier = 43
        second.id = .quartz(processIdentifier: 43, windowNumber: 2)
        var frontmost: pid_t? = 42
        var read: ((AXFocusRead) -> Void)?
        let registry = WindowRegistry(inventoryProvider: { $0([first, second], first.element) },
                                      focusedElementProvider: { read = $0 })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { first },
                                    frontmostProcessIdentifier: { frontmost })
        tracker.start()
        defer { tracker.stop() }
        registry.noteFocusedWindow(second)
        tracker.captureFocusedWindow(origin: "initial")
        var changedTo: LiveWindowID?
        tracker.onFocusChanged = { changedTo = $0?.id }
        frontmost = 43
        tracker.refreshOutlineFocus()
        XCTAssertEqual(registry.outlineFocusProcessIdentifier, 43)
        read?(.window(second.element))
        XCTAssertEqual(changedTo, second.id)
        XCTAssertEqual(tracker.focusedWindowID, second.id)
    }

    @MainActor
    func testRepeatedOutlineFocusAbsenceDoesNotInvalidatePendingFocusGeneration() {
        var reads: [(AXFocusRead) -> Void] = []
        let registry = WindowRegistry(inventoryProvider: { $0([], nil) },
                                      focusedElementProvider: { reads.append($0) })
        let tracker = WindowTracker(registry: registry, frontmostProcessIdentifier: { 42 })
        tracker.start()
        defer { tracker.stop() }
        var projections = 0
        tracker.refreshOutlineFocus { window in
            XCTAssertNil(window)
            projections += 1
        }
        reads[0](AXFocusRead.none)
        let generation = tracker.beginAXFocus(processIdentifier: 42)
        var repeatedClear = 0
        tracker.onFocusChanged = { _ in repeatedClear += 1 }
        tracker.refreshOutlineFocus { window in
            XCTAssertNil(window)
            projections += 1
        }
        reads[1](AXFocusRead.none)
        XCTAssertTrue(tracker.acceptsAXFocus(processIdentifier: 42, generation: generation))
        XCTAssertEqual(repeatedClear, 0)
        XCTAssertEqual(projections, 2)
        XCTAssertNil(tracker.focusedWindow)
    }

    @MainActor
    func testBackgroundFocusNotificationDoesNotMutateInventoryOrCancelForegroundRequest() {
        var active = managedWindow(cgWindowID: 1, observedOrder: 0)
        active.element = AXUIElementCreateApplication(42)
        let registry = WindowRegistry(inventoryProvider: { $0([active], active.element) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { active },
                                    frontmostProcessIdentifier: { 42 })
        tracker.reconcile()
        let token = tracker.beginAXFocus(processIdentifier: 42)
        let originalIDs = tracker.windows.map(\.id)
        tracker.receiveAXNotification(name: kAXFocusedWindowChangedNotification,
                                      element: AXUIElementCreateApplication(43),
                                      focusRead: .window(AXUIElementCreateApplication(43)))
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        XCTAssertEqual(tracker.windows.map(\.id), originalIDs)
        XCTAssertNotNil(token)
        XCTAssertTrue(tracker.acceptsAXFocus(processIdentifier: 42, generation: token))
        XCTAssertEqual(tracker.observerHealthByPID[43]?.focusWindows, 1)
    }

    @MainActor
    func testRapidActivationRejectsStaleFocusCompletionEvenAfterReturningToSameApp() {
        var frontmost: pid_t? = 42
        let tracker = WindowTracker(registry: WindowRegistry(), frontmostProcessIdentifier: { frontmost })
        let first = tracker.beginAXFocus(processIdentifier: 42)
        frontmost = 43
        XCTAssertFalse(tracker.acceptsAXFocus(processIdentifier: 42, generation: first))
        let second = tracker.beginAXFocus(processIdentifier: 43)
        frontmost = 42
        let third = tracker.beginAXFocus(processIdentifier: 42)
        XCTAssertFalse(tracker.acceptsAXFocus(processIdentifier: 42, generation: first))
        XCTAssertFalse(tracker.acceptsAXFocus(processIdentifier: 43, generation: second))
        XCTAssertTrue(tracker.acceptsAXFocus(processIdentifier: 42, generation: third))
        frontmost = nil
        XCTAssertNil(tracker.beginAXFocus(processIdentifier: nil))
        XCTAssertFalse(tracker.acceptsAXFocus(processIdentifier: 42, generation: third))
    }

    @MainActor
    func testAXHealthCountsNilAndIncompleteFocusCallbacks() {
        let tracker = WindowTracker(registry: WindowRegistry(), frontmostProcessIdentifier: { 42 })
        let app = AXUIElementCreateApplication(42)
        tracker.receiveAXNotification(name: kAXFocusedWindowChangedNotification, element: app, focusRead: AXFocusRead.none)
        tracker.receiveAXNotification(name: kAXFocusedWindowChangedNotification, element: app, focusRead: .incomplete)
        let health = tracker.observerHealthByPID[42]
        XCTAssertEqual(health?.callbacks, 2)
        XCTAssertEqual(health?.focusAbsences, 1)
        XCTAssertEqual(health?.incompleteFocusReads, 1)
        XCTAssertNotNil(health?.lastCallbackAt)
        XCTAssertEqual(tracker.lastAXEventName, kAXFocusedWindowChangedNotification)
        XCTAssertTrue(tracker.detailedDiagnosticLines().contains { $0.contains("pid=42 attached=false callbacks=2") })
    }

    func testFocusedWindowReadDistinguishesAbsenceFromTimeout() {
        let element = AXUIElementCreateApplication(42)
        XCTAssertNotNil(AXFocusRead.classify(error: .success, element: element).element)
        for error in [AXError.success, .noValue] {
            if case .none = AXFocusRead.classify(error: error, element: nil) {} else {
                XCTFail("A confirmed missing focused window must be authoritative")
            }
        }
        for error in [AXError.cannotComplete, .apiDisabled, .failure] {
            XCTAssertFalse(AXFocusRead.classify(error: error, element: nil).isComplete)
        }
    }

    func testNotificationRegistrationRetriesOnlyTransientFailuresWithABound() {
        let policy = AXNotificationRegistrationPolicy()
        XCTAssertEqual(policy.retryDelay(error: .cannotComplete, attempt: 0), 0.1)
        XCTAssertEqual(policy.retryDelay(error: .cannotComplete, attempt: 1), 0.2)
        XCTAssertNil(policy.retryDelay(error: .cannotComplete, attempt: 2))
        for error in [AXError.notificationUnsupported, .attributeUnsupported, .notImplemented,
                      .invalidUIElement, .apiDisabled, .success] {
            XCTAssertNil(policy.retryDelay(error: error, attempt: 0))
        }
    }

    @MainActor
    func testAuthoritativeNoFocusClearsOutlineFocusButRetainsWindowInventory() {
        let active = managedWindow(cgWindowID: 1, observedOrder: 0)
        let tracker = WindowTracker(registry: WindowRegistry(), focusedWindowProvider: { active })
        tracker.captureFocusedWindow(origin: "test")
        var cleared = 0
        tracker.onFocusChanged = { if $0 == nil { cleared += 1 } }
        tracker.observeFocusRead(.incomplete, origin: "timeout")
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        XCTAssertEqual(cleared, 0)
        tracker.observeFocusRead(AXFocusRead.classify(error: .noValue, element: nil), origin: "close")
        XCTAssertNil(tracker.focusedWindowID)
        XCTAssertNil(tracker.focusedWindow)
        XCTAssertEqual(tracker.windows.map(\.id), [active.id])
        XCTAssertEqual(cleared, 1)
        tracker.observeFocusRead(.none, origin: "repeated")
        XCTAssertEqual(cleared, 1)
        tracker.captureFocusedWindow(origin: "reopened")
        XCTAssertEqual(tracker.focusedWindowID, active.id)
    }

    @MainActor
    func testBackgroundApplicationNoFocusCannotClearAnotherApplicationsFocus() {
        let active = managedWindow(cgWindowID: 1, observedOrder: 0)
        let tracker = WindowTracker(registry: WindowRegistry(), focusedWindowProvider: { active })
        tracker.captureFocusedWindow(origin: "test")
        tracker.observeFocusRead(.none, origin: "background-close", processIdentifier: 43)
        XCTAssertEqual(tracker.focusedWindowID, active.id)
    }

    @MainActor
    func testCompleteFrontmostInventoryNoFocusClearsPreviouslyFocusedWindow() {
        let active = managedWindow(cgWindowID: 1, observedOrder: 0)
        let registry = WindowRegistry(inventoryProvider: { completion in completion([active], nil) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { active })
        tracker.captureFocusedWindow(origin: "test")
        var cleared = false
        tracker.onFocusChanged = { if $0 == nil { cleared = true } }
        tracker.reconcile()
        XCTAssertTrue(cleared)
        XCTAssertNil(tracker.focusedWindow)
        XCTAssertEqual(tracker.windows.map(\.id), [active.id])
    }

    @MainActor
    func testOlderNoFocusInventoryCannotOverrideANewerFocusedWindow() {
        var first = managedWindow(cgWindowID: 1, observedOrder: 0)
        first.element = AXUIElementCreateApplication(42)
        var second = managedWindow(cgWindowID: 2, observedOrder: 0)
        second.element = AXUIElementCreateApplication(43)
        var observed = first
        var publish: (([ManagedWindow], AXUIElement?) -> Void)?
        let registry = WindowRegistry(inventoryProvider: { publish = $0 })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { observed })
        tracker.captureFocusedWindow(origin: "first")
        tracker.reconcile()
        observed = second
        tracker.captureFocusedWindow(origin: "newer-focus")
        publish?([first, second], nil)
        XCTAssertEqual(tracker.focusedWindowID, second.id)
    }

    func testMetadataRequestsRejectOlderSiblingUpdatesAndDestroyedWindowResults() {
        let first = AXUIElementCreateApplication(42)
        let second = AXUIElementCreateApplication(43)
        var requests = AXMetadataRequests()
        let older = requests.begin(element: first)
        let unrelated = requests.begin(element: second)
        let newer = requests.begin(element: first)
        XCTAssertFalse(requests.finish(element: first, generation: older))
        XCTAssertTrue(requests.finish(element: second, generation: unrelated))
        XCTAssertTrue(requests.finish(element: first, generation: newer))
        XCTAssertFalse(requests.finish(element: first, generation: newer))
        let destroyed = requests.begin(element: first)
        requests.invalidate(element: first)
        XCTAssertFalse(requests.finish(element: first, generation: destroyed))
    }

    @MainActor
    func testReconciliationBarrierWaitsForQueuedSpaceReset() {
        var publications: [([ManagedWindow], AXUIElement?) -> Void] = []
        let registry = WindowRegistry(inventoryProvider: { publications.append($0) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        var completions: [String] = []
        tracker.reconcile { completions.append("first") }
        tracker.reconcile(resetSpaceMembership: true) { completions.append("reset") }
        XCTAssertEqual(publications.count, 1)
        XCTAssertTrue(completions.isEmpty)
        publications[0]([], nil)
        XCTAssertEqual(publications.count, 2)
        XCTAssertTrue(completions.isEmpty)
        publications[1]([], nil)
        XCTAssertEqual(completions, ["first", "reset"])
    }

    @MainActor
    func testInventoryWorkersKeepMainResponsiveAndSealTimedOutResults() async {
        let release = DispatchSemaphore(value: 0)
        let workerStarted = expectation(description: "worker starts off-main")
        let workerFinished = expectation(description: "late worker finishes")
        let mainResponsive = expectation(description: "main remains responsive")
        let scanFinished = expectation(description: "bounded scan completes")
        let pool = AXApplicationExecutorPool(scanTimeout: 0.03) { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            workerStarted.fulfill()
            _ = release.wait(timeout: .now() + 2)
            defer { workerFinished.fulfill() }
            return AXApplicationSnapshot(windows: [], focusedElement: nil)
        }
        var publications = 0
        var published: AXEnumerationBatch?
        pool.enumerateWindows(for: [42], resolver: WindowIDResolver(loadPrivateSymbol: false)) { batch in
            publications += 1
            published = batch
            XCTAssertNil(batch.snapshot(pid: 42))
            scanFinished.fulfill()
        }
        DispatchQueue.main.async { mainResponsive.fulfill() }
        await fulfillment(of: [workerStarted, mainResponsive, scanFinished], timeout: 1)
        release.signal()
        await fulfillment(of: [workerFinished], timeout: 1)
        // Seal is the snapshot boundary: finishing a timed-out worker cannot mutate it.
        XCTAssertNil(published?.snapshot(pid: 42))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(publications, 1)
    }

    @MainActor
    func testInventoryPublishesOnceAllOwnerMetadataIsReady() async {
        let scanFinished = expectation(description: "complete inventory publishes")
        let pool = AXApplicationExecutorPool(scanTimeout: 1) { _, _ in
            AXApplicationSnapshot(windows: [], focusedElement: nil)
        }
        pool.enumerateWindows(for: [42, 43], resolver: WindowIDResolver(loadPrivateSymbol: false)) { batch in
            XCTAssertNotNil(batch.snapshot(pid: 42))
            XCTAssertNotNil(batch.snapshot(pid: 43))
            scanFinished.fulfill()
        }
        await fulfillment(of: [scanFinished], timeout: 1)
    }

    func testQuartzlessSiblingIdentitiesRemainDistinctWithSharedPersistentHints() {
        let first = WindowIdentity(bundleIdentifier: "test.editor", processIdentifier: 42,
                                   cgWindowID: nil, axRole: "AXWindow", axSubrole: nil,
                                   observedOrder: 0, stableIdentifier: "shared", documentURL: "file:///same",
                                   sessionID: UUID())
        var second = first
        second.sessionID = UUID()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
        var reordered = first
        reordered.observedOrder = 99
        reordered.titleHint = "changed title"
        XCTAssertEqual(first, reordered)
        XCTAssertEqual(Set([first, reordered]).count, 1)
        var persistentOnly = first
        persistentOnly.sessionID = nil
        XCTAssertNotEqual(first, persistentOnly)
    }

    func testDestroyedWindowCannotBeReinsertedByLateFocusProjection() {
        let registry = WindowRegistry()
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        registry.noteFocusedWindow(window)
        XCTAssertNotNil(registry.focusedWindow(element: window.element))
        registry.forgetWindow(element: window.element)
        registry.noteFocusedWindow(window)
        XCTAssertNil(registry.focusedWindow(element: window.element))
        XCTAssertNil(registry.window(cgWindowID: 1))
    }

    @MainActor
    func testInvalidObserverRegistrationDoesNotDestroyOrBlacklistEnumeratedWindow() {
        var window = managedWindow(cgWindowID: 1, observedOrder: 0)
        window.element = AXUIElementCreateApplication(42)
        let registry = WindowRegistry(inventoryProvider: { $0([window], window.element) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { window },
                                    frontmostProcessIdentifier: { 42 })
        tracker.start()
        defer { tracker.stop() }
        tracker.captureFocusedWindow(origin: "test")
        var focusChanges: [LiveWindowID?] = []
        tracker.onFocusChanged = { focusChanges.append($0?.id) }
        var ready = 0
        tracker.onWindowObserverReady = { _ in ready += 1 }
        for partialSuccess in [false, true, false] {
            tracker.handleNotificationRegistrationResult(element: window.element, pid: 42, isApplication: false,
                registered: partialSuccess, failures: [(kAXUIElementDestroyedNotification, .invalidUIElement)])
            XCTAssertEqual(tracker.windows.map(\.id), [window.id])
            XCTAssertEqual(tracker.focusedWindowID, window.id)
            registry.noteFocusedWindow(window)
            XCTAssertNotNil(registry.window(cgWindowID: 1), "The live AX element must never be tombstoned by attachment errors")
            tracker.reconcile()
        }
        XCTAssertTrue(focusChanges.isEmpty)
        tracker.handleNotificationRegistrationResult(element: window.element, pid: 42, isApplication: false,
            registered: true, failures: [])
        XCTAssertEqual(ready, 1, "A later successful attachment must notify recovery")
        tracker.handleWindowDestroyed(element: window.element)
        registry.noteFocusedWindow(window)
        XCTAssertNil(registry.window(cgWindowID: 1), "An actual destroy notification still rejects late focus results")
        XCTAssertTrue(tracker.windows.isEmpty)
    }

    func testMouseTargetingRejectsAmbiguityAndKnownDifferentWindowIDs() {
        XCTAssertNil(WindowIDResolver.uniqueCandidateIndex(
            targetWindowID: 1, directWindowIDs: [nil, nil], fallbackMatches: [0, 1]))
        XCTAssertNil(WindowIDResolver.uniqueCandidateIndex(
            targetWindowID: 1, directWindowIDs: [2], fallbackMatches: [0]))
        XCTAssertEqual(WindowIDResolver.uniqueCandidateIndex(
            targetWindowID: 1, directWindowIDs: [nil, 1], fallbackMatches: [0]), 1)
        XCTAssertEqual(WindowIDResolver.uniqueCandidateIndex(
            targetWindowID: 1, directWindowIDs: [nil, nil], fallbackMatches: [1]), 1)
        XCTAssertNil(WindowIDResolver.uniqueCandidateIndex(
            targetWindowID: 1, directWindowIDs: [1, 1, nil], fallbackMatches: [2]))
    }

    func testIdenticalDisplaysMatchTheirCapturedBindingInEitherEnumerationOrder() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let manager = ProfileManager(store: store)
        func display(_ id: UInt32, _ x: CGFloat, _ persistentID: String) -> DisplaySnapshot.Display {
            .init(id: id, frame: CGRect(x: x, y: 0, width: 1920, height: 1080),
                  visibleFrame: CGRect(x: x, y: 0, width: 1920, height: 1080), scale: 1,
                  persistentID: persistentID, name: "Same monitor", rotation: 0, isBuiltIn: false)
        }
        let left = display(1, 0, "left")
        let right = display(2, 1920, "right")
        let snapshot = DisplaySnapshot(displays: [left, right])
        var profile = DefaultProfiles.main
        profile.setupBindings = [manager.setupBinding(for: snapshot)]
        XCTAssertNotNil(manager.matchedSetupBinding(for: profile, snapshot: snapshot))
        // Synthetic display IDs have no OS main-display designation; test mapping independently.
        profile.setupBindings[0].mainDisplayPersistentID = nil
        XCTAssertNotNil(manager.matchedSetupBinding(for: profile,
                                                    snapshot: DisplaySnapshot(displays: [right, left])))
        let ambiguous = DisplaySnapshot(displays: [display(3, 0, "new-left"), display(4, 1920, "new-right")])
        XCTAssertNil(manager.matchedSetupBinding(for: profile, snapshot: ambiguous))
        let swapped = DisplaySnapshot(displays: [display(1, 1920, "left"), display(2, 0, "right")])
        XCTAssertNil(manager.matchedSetupBinding(for: profile, snapshot: swapped))
    }

    @MainActor
    func testClosingFocusedWindowClearsOutlineThenRecoversFocusWithoutScan() async throws {
        var closed = managedWindow(cgWindowID: 1, observedOrder: 0)
        closed.element = AXUIElementCreateApplication(42)
        var replacement = managedWindow(cgWindowID: 2, observedOrder: 1)
        replacement.element = AXUIElementCreateApplication(43)
        var observed: ManagedWindow? = closed
        let tracker = WindowTracker(registry: WindowRegistry(), focusedWindowProvider: { observed })
        var events: [LiveWindowID?] = []
        tracker.onFocusChanged = { events.append($0?.id) }
        tracker.captureFocusedWindow(origin: "test")
        tracker.handleWindowDestroyed(element: closed.element)
        XCTAssertEqual(events, [closed.id, nil])
        XCTAssertNil(tracker.focusedWindow)
        // A stale AX result must not resurrect the destroyed window.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(tracker.windows.contains { $0.id == closed.id })
        observed = replacement
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(tracker.focusedWindowID, replacement.id)
        XCTAssertEqual(events, [closed.id, nil, replacement.id])
    }

    @MainActor
    func testCloseRecoveryDoesNotOverrideNewerFocusAndIsBounded() async throws {
        var closed = managedWindow(cgWindowID: 1, observedOrder: 0)
        closed.element = AXUIElementCreateApplication(42)
        var replacement = managedWindow(cgWindowID: 2, observedOrder: 1)
        replacement.element = AXUIElementCreateApplication(43)
        var observed: ManagedWindow? = closed
        var reads = 0
        let tracker = WindowTracker(registry: WindowRegistry(), focusedWindowProvider: {
            reads += 1
            return observed
        })
        tracker.captureFocusedWindow(origin: "test")
        tracker.handleWindowDestroyed(element: closed.element)
        observed = replacement
        tracker.captureFocusedWindow(origin: "newer-focus")
        let readsBeforeWait = reads
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reads, readsBeforeWait)
        XCTAssertEqual(tracker.focusedWindowID, replacement.id)

        tracker.handleWindowDestroyed(element: replacement.element)
        observed = nil
        let readsBeforeRecovery = reads
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(reads - readsBeforeRecovery, 4)
        XCTAssertNil(tracker.focusedWindowID)
    }

    @MainActor
    func testClosingBackgroundWindowDoesNotClearFocus() {
        let active = managedWindow(cgWindowID: 1, observedOrder: 0)
        let tracker = WindowTracker(registry: WindowRegistry(), focusedWindowProvider: { active })
        tracker.captureFocusedWindow(origin: "test")
        var events = 0
        tracker.onFocusChanged = { _ in events += 1 }
        tracker.handleWindowDestroyed(element: AXUIElementCreateApplication(43))
        XCTAssertEqual(tracker.focusedWindowID, active.id)
        XCTAssertEqual(events, 0)
    }

    func testWindowIDResolverPrefersDirectAndFallsBackCleanly() {
        let element = AXUIElementCreateSystemWide()
        var fallbackCalls = 0
        let direct = WindowIDResolver(directResolver: { _ in 42 })
        XCTAssertEqual(
            direct.resolve(element: element) {
                fallbackCalls += 1
                return 7
            },
            ResolvedWindowID(windowID: 42, source: .direct)
        )
        XCTAssertEqual(fallbackCalls, 0)

        let fallback = WindowIDResolver(loadPrivateSymbol: false)
        XCTAssertEqual(
            fallback.resolve(element: element) { 7 },
            ResolvedWindowID(windowID: 7, source: .publicHeuristic)
        )
        XCTAssertEqual(
            fallback.resolve(element: element) { nil },
            ResolvedWindowID(windowID: nil, source: .sessionOnly)
        )
    }

    func testIncompleteInventoryNeedsRepeatedCompleteAbsenceBeforeRemoval() {
        let policy = WindowAbsencePolicy(completeScansRequiredForRemoval: 3)

        XCTAssertFalse(policy.shouldRemove(consecutiveCompleteAbsences: 1))
        XCTAssertFalse(policy.shouldRemove(consecutiveCompleteAbsences: 2))
        XCTAssertTrue(policy.shouldRemove(consecutiveCompleteAbsences: 3))
    }

    func testSpaceEpochKeepsOnlyConfirmedMinimizedWindows() {
        let policy = SpaceEpochPolicy()

        XCTAssertEqual(policy.resolvedEpoch(
            isOnCurrentSpace: true,
            isMinimized: false,
            previousEpoch: nil,
            currentEpoch: 4
        ), 4)
        XCTAssertEqual(policy.resolvedEpoch(
            isOnCurrentSpace: false,
            isMinimized: true,
            previousEpoch: 4,
            currentEpoch: 4
        ), 4)
        XCTAssertFalse(policy.isIncluded(
            windowEpoch: 4,
            isOnCurrentSpace: false,
            isMinimized: true,
            currentEpoch: 5
        ))
    }

    func testTrackingJournalIsBoundedAndContainsNoWindowMetadataFields() {
        var journal = WindowTrackingJournal(capacity: 3)
        for index in 0..<5 {
            journal.append(
                event: "focus.observed",
                processIdentifier: 10,
                bundleIdentifier: "com.example.app",
                spaceEpoch: 1,
                observerGeneration: 2,
                detail: "focusSequence=\(index)"
            )
        }

        XCTAssertEqual(journal.entries.map(\.sequence), [3, 4, 5])
        XCTAssertFalse(String(describing: journal.entries).contains("documentURL"))
        XCTAssertFalse(String(describing: journal.entries).contains("titleHint"))
    }

    func testWindowRescanPolicyRetriesDuringStartupReadinessWindow() {
        let policy = WindowRescanPolicy()

        XCTAssertGreaterThanOrEqual(policy.followUpDelays.count, 3)
        XCTAssertEqual(policy.followUpDelays, policy.followUpDelays.sorted())
        XCTAssertGreaterThanOrEqual(policy.followUpDelays.last ?? 0, 1.5)
    }

    func testWindowEventRefreshPolicyDebouncesAndRateLimitsInventoryScans() {
        let policy = WindowEventRefreshPolicy(
            debounceDelay: 0.15,
            minimumInterval: 1.0,
            recoveryInterval: 5.0
        )

        XCTAssertEqual(policy.delay(lastRefreshAt: nil, now: 20), 0.15)
        XCTAssertEqual(policy.delay(lastRefreshAt: 19.8, now: 20), 0.8, accuracy: 0.001)
        XCTAssertEqual(policy.delay(lastRefreshAt: 18, now: 20), 0.15)
        XCTAssertGreaterThan(policy.recoveryInterval, policy.minimumInterval)
    }

    func testWindowInclusionPolicyRejectsGenericTransientDialogHostsOnly() {
        let policy = WindowInclusionPolicy()

        XCTAssertTrue(policy.isTransientHost(
            subrole: "AXDialog",
            stableIdentifier: "_NS:8",
            titleHint: "window"
        ))
        XCTAssertFalse(policy.isTransientHost(
            subrole: "AXDialog",
            stableIdentifier: "open-panel",
            titleHint: "open"
        ))
        XCTAssertFalse(policy.isTransientHost(
            subrole: "AXStandardWindow",
            stableIdentifier: "_NS:8",
            titleHint: "window"
        ))
    }

    func testSessionWindowIdentitySeparatesQuartzlessSiblingsAndIsNotPersisted() throws {
        let firstSession = UUID()
        let first = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1,
            titleHint: "old title",
            sessionID: firstSession
        )
        let renamed = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 99,
            titleHint: "new title",
            sessionID: firstSession
        )
        let sibling = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 2,
            sessionID: UUID()
        )

        XCTAssertEqual(first, renamed)
        XCTAssertNotEqual(first, sibling)
        XCTAssertEqual(Set([first, renamed, sibling]).count, 2)
        let decoded = try JSONDecoder().decode(
            WindowIdentity.self,
            from: JSONEncoder().encode(first)
        )
        XCTAssertNil(decoded.sessionID)
    }

    func testSessionWindowIdentityIsAnExactLiveAssignmentHint() {
        let sessionID = UUID()
        let assignmentIdentity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1,
            titleHint: "before",
            sessionID: sessionID
        )
        let rescannedIdentity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 99,
            titleHint: "after",
            sessionID: sessionID
        )
        let siblingIdentity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 2,
            sessionID: UUID()
        )

        XCTAssertTrue(assignmentIdentity.matchesSameLiveWindow(as: rescannedIdentity))
        XCTAssertFalse(assignmentIdentity.matchesSameLiveWindow(as: siblingIdentity))
    }

    func testWindowIdentityIgnoresEnumerationOrder() {
        let first = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1
        )
        let laterScan = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 99
        )

        XCTAssertEqual(first, laterScan)
        XCTAssertEqual(Set([first, laterScan]).count, 1)
    }

    func testWindowRegistryDoesNotGuessAmongSameAppSiblings() {
        let registry = WindowRegistry()
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 99
        )
        let windows = [
            managedWindow(cgWindowID: 10, observedOrder: 1),
            managedWindow(cgWindowID: 20, observedOrder: 2)
        ]

        XCTAssertNil(registry.bestMatch(for: identity, in: windows))
    }

    func testWindowRegistryAssignmentMatchingSeparatesSameAppWindows() {
        let registry = WindowRegistry()
        let assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: 10,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .left,
            updatedAt: Date()
        )

        XCTAssertTrue(registry.assignment(assignment, matches: managedWindow(cgWindowID: 10, observedOrder: 1)))
        XCTAssertFalse(registry.assignment(assignment, matches: managedWindow(cgWindowID: 20, observedOrder: 1)))
    }

    func testWindowFingerprintMatchingRejectsEqualSameAppCandidates() {
        let registry = WindowRegistry()
        let fingerprint = PersistentWindowFingerprint(
            bundleIdentifier: "com.example.App",
            stableIdentifier: nil,
            documentURL: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            titleHint: "document"
        )
        let windows = [
            managedWindow(cgWindowID: 10, observedOrder: 1, titleHint: "document"),
            managedWindow(cgWindowID: 20, observedOrder: 2, titleHint: "document")
        ]

        guard case .ambiguous = registry.match(for: fingerprint, in: windows) else {
            return XCTFail("Equal-scoring candidates must remain ambiguous")
        }
    }


}
