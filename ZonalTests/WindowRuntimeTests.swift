import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

private final class PlacementResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AXPlacementResult] = []
    var values: [AXPlacementResult] { lock.withLock { storage } }
    func append(_ result: AXPlacementResult) { lock.withLock { storage.append(result) } }
}

private final class BlockingPlacementAccess: AXPlacementAccess, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true
    private var storedFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private var storedWrites: [CGRect] = []
    var writes: [CGRect] { lock.withLock { storedWrites } }
    func prepare(_ element: AXUIElement) {}
    func frame(of element: AXUIElement) -> CGRect? { lock.withLock { storedFrame } }
    func apply(_ frame: CGRect, container: CGRect?, to element: AXUIElement, isCurrent: () -> Bool) {
        let block = lock.withLock { let result = shouldBlock; shouldBlock = false; return result }
        if block {
            started.signal()
            guard resume.wait(timeout: .now() + 3) == .success else { return }
        }
        guard isCurrent() else { return }
        lock.withLock { storedFrame = frame; storedWrites.append(frame) }
    }
}

private final class SettlingPlacementAccess: AXPlacementAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let deferred: Bool
    private var storedFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private var pendingFrame: CGRect?
    private var waits = 0
    var waitCount: Int { lock.withLock { waits } }
    init(deferred: Bool) { self.deferred = deferred }
    func prepare(_ element: AXUIElement) {}
    func frame(of element: AXUIElement) -> CGRect? { lock.withLock { storedFrame } }
    func apply(_ frame: CGRect, container: CGRect?, to element: AXUIElement, isCurrent: () -> Bool) {
        guard isCurrent() else { return }
        lock.withLock {
            if deferred { pendingFrame = frame } else { storedFrame = frame }
        }
    }
    func settle() {
        lock.withLock {
            waits += 1
            if let pendingFrame { storedFrame = pendingFrame }
            pendingFrame = nil
        }
    }
}

private final class RecordingFocusAccess: AXFocusAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(token: UUID, onMainThread: Bool)] = []
    private var appliedTokens: [UUID] = []
    var invocations: [(token: UUID, onMainThread: Bool)] { lock.withLock { calls } }
    var applied: [UUID] { lock.withLock { appliedTokens } }
    var blockedToken: UUID?
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)

    func focus(_ job: AXFocusJob, isCurrent: () -> Bool) {
        lock.withLock { calls.append((job.token, Thread.isMainThread)) }
        if job.token == blockedToken {
            started.signal()
            guard resume.wait(timeout: .now() + 3) == .success else { return }
        }
        if isCurrent() { lock.withLock { appliedTokens.append(job.token) } }
        returned.signal()
    }
}

private final class FocusOperationRecorder: @unchecked Sendable {
    let lock = NSLock()
    var operations: [String] = []
    func record(_ operation: String) { lock.withLock { operations.append(operation) } }
}

final class WindowRuntimeTests: XCTestCase {
    func testSingleWindowFocusNeverActivatesAllApplicationWindows() {
        let recorder = FocusOperationRecorder()
        let access = SystemAXFocusAccess(setAttribute: { _, attribute, _ in
            recorder.record(attribute as String)
            return .success
        }, raise: { _ in
            recorder.record("raise")
            return .success
        }, activateFrontWindow: { pid in
            recorder.record("activate-front-only-\(pid)")
            return true
        })
        access.focus(AXFocusJob(token: UUID(), pid: 42, element: AXUIElementCreateApplication(42)), isCurrent: { true })
        XCTAssertFalse(recorder.operations.contains(kAXFrontmostAttribute))
        XCTAssertEqual(recorder.operations.suffix(3), ["raise", kAXFocusedAttribute, "activate-front-only-42"])
    }

    func testFailedRaiseDoesNotActivatePreviouslyFrontmostSibling() {
        let recorder = FocusOperationRecorder()
        let access = SystemAXFocusAccess(setAttribute: { _, _, _ in .success },
            raise: { _ in .cannotComplete }, activateFrontWindow: { _ in
                recorder.record("activation")
                return true
            })
        access.focus(AXFocusJob(token: UUID(), pid: 42, element: AXUIElementCreateApplication(42)), isCurrent: { true })
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    @MainActor
    func testSessionSuspensionStopsPollingAndCoalescesResume() async throws {
        let registry = WindowRegistry(inventoryProvider: { $0([], nil) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        var transitions: [Bool] = []
        tracker.onSessionActivityChanged = { transitions.append($0) }
        tracker.start()
        defer { tracker.stop() }
        XCTAssertTrue(tracker.isReconciliationTimerActive)
        tracker.setSessionInactive(true)
        tracker.setSessionInactive(true)
        XCTAssertFalse(tracker.isReconciliationTimerActive)
        XCTAssertEqual(transitions, [false])
        tracker.setSessionInactive(false)
        tracker.setSessionInactive(false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(tracker.isReconciliationTimerActive)
        XCTAssertEqual(transitions, [false, true])
        tracker.setSessionInactive(true)
        tracker.setSessionInactive(false)
        tracker.setSessionInactive(true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(tracker.isReconciliationTimerActive)
        XCTAssertEqual(transitions, [false, true, false, false], "A late wake must not restart work after another lock")
    }


    func testSelfAccessibilityRunsOnMainWhileForeignAccessStaysOnWorker() {
        let own = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let foreign = AXUIElementCreateApplication(42)
        let completed = expectation(description: "self and foreign AX thread routing")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            let ownResult = AXThreadAccess.perform(for: own) {
                XCTAssertTrue(Thread.isMainThread, "Self-AX invokes AppKit directly")
                return 123
            }
            XCTAssertEqual(ownResult, 123)
            AXThreadAccess.perform(for: foreign) {
                XCTAssertFalse(Thread.isMainThread, "Foreign AX must not block UI rendering")
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    @MainActor
    func testSelfAccessibilityAlreadyOnMainDoesNotRedispatch() {
        let own = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var executed = false
        AXThreadAccess.perform(for: own) {
            XCTAssertTrue(Thread.isMainThread)
            executed = true
        }
        XCTAssertTrue(executed)
    }

    func testBatchedGeometryRejectsMissingFailedAndWronglyTypedAttributes() throws {
        let element = AXUIElementCreateApplication(42)
        var point = CGPoint(x: 30, y: 40)
        var size = CGSize(width: 500, height: 400)
        var error = AXError.noValue
        let position = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let extent = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        let failure = try XCTUnwrap(AXValueCreate(.axError, &error))
        func frame(_ values: [String: Any]) -> CGRect? {
            AXWindowSnapshot(element: element, attributes: values, directID: nil).frame
        }
        XCTAssertEqual(frame([kAXPositionAttribute: position, kAXSizeAttribute: extent]),
                       CGRect(origin: point, size: size))
        XCTAssertNil(frame([kAXPositionAttribute: position]))
        XCTAssertNil(frame([kAXPositionAttribute: position, kAXSizeAttribute: failure]))
        XCTAssertNil(frame([kAXPositionAttribute: extent, kAXSizeAttribute: position]))
        XCTAssertNil(frame([kAXPositionAttribute: "invalid", kAXSizeAttribute: extent]))
    }

    func testFocusAXWorkAndCompletionRunOffMainThread() {
        let access = RecordingFocusAccess()
        let executor = AXFocusExecutor(access: access)
        let completed = expectation(description: "focus worker completed")
        let token = UUID()
        executor.submit(AXFocusJob(token: token, pid: 42, element: AXUIElementCreateApplication(42))) {
            XCTAssertFalse(Thread.isMainThread)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(access.invocations.map(\.token), [token])
        XCTAssertEqual(access.invocations.map(\.onMainThread), [false])
        XCTAssertEqual(access.applied, [token])
    }

    func testFocusCancellationDropsQueuedWorkAndStopsInFlightApplication() {
        let access = RecordingFocusAccess()
        let executor = AXFocusExecutor(access: access)
        let running = UUID()
        let queued = UUID()
        access.blockedToken = running
        let cancelledCompletion = expectation(description: "cancelled focus must not complete")
        cancelledCompletion.isInverted = true
        executor.submit(AXFocusJob(token: running, pid: 42, element: AXUIElementCreateApplication(42))) {
            cancelledCompletion.fulfill()
        }
        XCTAssertEqual(access.started.wait(timeout: .now() + 2), .success)
        defer { access.resume.signal() }
        executor.submit(AXFocusJob(token: queued, pid: 42, element: AXUIElementCreateApplication(42))) {
            cancelledCompletion.fulfill()
        }
        executor.cancel()
        XCTAssertFalse(executor.isCurrent(running))
        XCTAssertFalse(executor.isCurrent(queued))
        access.resume.signal()
        XCTAssertEqual(access.returned.wait(timeout: .now() + 2), .success)
        wait(for: [cancelledCompletion], timeout: 0.2)
        // A subsequent request on the same serial queue also acts as a drain barrier.
        let finished = expectation(description: "new request after cancelled queue")
        let fresh = UUID()
        executor.submit(AXFocusJob(token: fresh, pid: 42, element: AXUIElementCreateApplication(42))) {
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(access.invocations.map(\.token), [running, fresh])
        XCTAssertEqual(access.applied, [fresh])
    }

    func testFocusForAnotherApplicationBypassesBlockedApplicationQueue() {
        let access = RecordingFocusAccess()
        let executor = AXFocusExecutor(access: access)
        let blocked = UUID()
        let independent = UUID()
        access.blockedToken = blocked
        executor.submit(AXFocusJob(token: blocked, pid: 42, element: AXUIElementCreateApplication(42))) {}
        XCTAssertEqual(access.started.wait(timeout: .now() + 2), .success)
        defer { access.resume.signal() }
        let completed = expectation(description: "other app focuses while first is blocked")
        executor.submit(AXFocusJob(token: independent, pid: 99, element: AXUIElementCreateApplication(99))) {
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(access.applied, [independent])
        XCTAssertFalse(executor.isCurrent(blocked))
        XCTAssertTrue(executor.isCurrent(independent))
        XCTAssertEqual(access.invocations.map(\.onMainThread), [false, false])
    }

    func testOutlineStrokeFollowsActualWindowEdgeWithTransparentOutset() {
        for bounds in [CGRect(x: 0, y: 0, width: 700, height: 500), CGRect(x: 0, y: 0, width: 6, height: 4)] {
            for width in 1...8 {
                for radius: CGFloat in [0, 10, 16, 26] {
                    let outset = OutlineStrokeGeometry.effectOutset(for: CGFloat(width))
                    let panelBounds = bounds.insetBy(dx: -outset, dy: -outset)
                    let geometry = OutlineStrokeGeometry(bounds: panelBounds, width: CGFloat(width), radius: radius)
                    XCTAssertEqual(geometry.rect, bounds)
                    XCTAssertTrue(panelBounds.contains(geometry.rect.insetBy(dx: -geometry.width / 2, dy: -geometry.width / 2)))
                    XCTAssertGreaterThanOrEqual(geometry.radius, 0)
                    XCTAssertLessThanOrEqual(geometry.radius, min(geometry.rect.width, geometry.rect.height) / 2)
                    if bounds.width == 700 && radius > 0 {
                        XCTAssertEqual(geometry.radius, radius)
                    }
                }
            }
        }
    }

    func testFastPlacementSkipsWaitOnlyAfterVerifiedFrame() {
        for (immediate, deferred, expectedWaits) in [(true, false, 0), (false, false, 1), (true, true, 1)] {
            let access = SettlingPlacementAccess(deferred: deferred)
            let completed = expectation(description: "verified placement")
            let target = CGRect(x: 200, y: 20, width: 400, height: 300)
            let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0.12), sink: AXPlacementResultSink { result in
                XCTAssertEqual(result.outcome, .placed)
                XCTAssertEqual(result.actual, target)
                XCTAssertEqual(result.writes, 1)
                completed.fulfill()
            }, access: access, waitForSettle: { _ in access.settle() })
            scheduler.submit(AXPlacementJob(token: UUID(), windowID: .quartz(processIdentifier: 42, windowNumber: 10),
                                           pid: 42, element: AXUIElementCreateApplication(42),
                                           target: target, container: nil, verifyImmediately: immediate))
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(access.waitCount, expectedWaits)
        }
    }

    func testOnePointPositionErrorTriggersVerifiedPlacement() {
        let access = SettlingPlacementAccess(deferred: false)
        let completed = expectation(description: "one-point offset corrected")
        let target = CGRect(x: 1, y: 0, width: 100, height: 100)
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0), sink: AXPlacementResultSink { result in
            XCTAssertEqual(result.outcome, .placed)
            XCTAssertEqual(result.actual, target)
            XCTAssertEqual(result.writes, 1)
            completed.fulfill()
        }, access: access)
        scheduler.submit(AXPlacementJob(token: UUID(), windowID: .quartz(processIdentifier: 42, windowNumber: 10),
                                       pid: 42, element: AXUIElementCreateApplication(42), target: target,
                                       container: nil, verifyImmediately: true))
        wait(for: [completed], timeout: 2)
    }

    func testRefusedPositionIsReportedAsConstrainedWithBoundedRetries() {
        struct RefusingAccess: AXPlacementAccess {
            func prepare(_ element: AXUIElement) {}
            func frame(of element: AXUIElement) -> CGRect? { CGRect(x: 1, y: 0, width: 100, height: 100) }
            func apply(_ frame: CGRect, container: CGRect?, to element: AXUIElement, isCurrent: () -> Bool) {}
        }
        let completed = expectation(description: "position refusal is bounded")
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0, maximumWrites: 2), sink: AXPlacementResultSink { result in
            XCTAssertEqual(result.outcome, .constrained)
            XCTAssertEqual(result.writes, 2)
            XCTAssertNil(result.learnedConstraint, "A position refusal must not create a size constraint")
            completed.fulfill()
        }, access: RefusingAccess())
        scheduler.submit(AXPlacementJob(token: UUID(), windowID: .quartz(processIdentifier: 42, windowNumber: 10),
                                       pid: 42, element: AXUIElementCreateApplication(42),
                                       target: CGRect(x: 0, y: 0, width: 100, height: 100), container: nil))
        wait(for: [completed], timeout: 2)
    }

    func testCornerRadiusQueryFallsBackAndRejectsInvalidValues() {
        XCTAssertNil(WindowCornerRadiusReader(loadPrivateSymbols: false).radius(for: 7))
        XCTAssertNil(WindowCornerRadiusReader.validatedRadius(nil))
        XCTAssertNil(WindowCornerRadiusReader.validatedRadius(NSNumber(value: Double.nan)))
        XCTAssertNil(WindowCornerRadiusReader.validatedRadius(-1))
        XCTAssertNil(WindowCornerRadiusReader.validatedRadius(999))
        XCTAssertEqual(WindowCornerRadiusReader.validatedRadius(0), 0)
        XCTAssertEqual(WindowCornerRadiusReader.validatedRadius(16), 16)
        XCTAssertEqual(WindowCornerRadiusReader.validatedRadius(26), 26)
    }

    func testOutlineTransientFrameRetriesAreBounded() {
        let policy = OutlineRefreshRetryPolicy()
        XCTAssertEqual((0..<5).compactMap { policy.delay(afterAttempt: $0) }, [0.05, 0.1, 0.2, 0.4, 0.8])
        XCTAssertNil(policy.delay(afterAttempt: -1))
        XCTAssertNil(policy.delay(afterAttempt: 5))
        XCTAssertNil(policy.delay(afterAttempt: 100))
    }

    func testOutlineRejectsStaleSnapshots() {
        var state = OutlineRefreshState()
        let old = state.revision
        for _ in 0..<100 { state.invalidate() }
        XCTAssertFalse(state.accepts(old))
        XCTAssertTrue(state.accepts(state.revision))
        let beforeHide = state.revision
        state.invalidate()
        XCTAssertFalse(state.accepts(beforeHide))
    }

    func testOutlineAcceptsEitherDisplayButExcludesFullscreenAndOffscreenFrames() {
        let displays = [CGRect(x: 0, y: 0, width: 900, height: 700), CGRect(x: -800, y: 200, width: 800, height: 600)]
        let policy = OutlineVisibilityPolicy()
        XCTAssertTrue(policy.shouldShow(frame: CGRect(x: 20, y: 20, width: 400, height: 300), displays: displays))
        XCTAssertTrue(policy.shouldShow(frame: CGRect(x: -750, y: 220, width: 400, height: 300), displays: displays))
        XCTAssertFalse(policy.shouldShow(frame: displays[0], displays: displays))
        XCTAssertFalse(policy.shouldShow(frame: CGRect(x: 2000, y: 20, width: 400, height: 300), displays: displays))
        XCTAssertFalse(policy.shouldShow(frame: displays[0], displays: []))
    }

    func testOutlineUsesActualBoundsForSmallAndFloatingWindows() {
        let small = CGRect(x: -700, y: 80, width: 260, height: 180)
        let key = OutlineWindowKey(pid: 42, number: 7)
        let rows: [[String: Any]] = [[
            kCGWindowNumber as String: UInt32(7),
            kCGWindowOwnerPID as String: Int32(42),
            kCGWindowLayer as String: 3,
            kCGWindowBounds as String: small.dictionaryRepresentation
        ]]
        let frames = ActiveWindowOutlineController.visibleFrames(from: rows)
        XCTAssertEqual(frames[key], small)
        XCTAssertTrue(OutlineVisibilityPolicy().shouldShow(
            frame: small, displays: [CGRect(x: -900, y: 0, width: 900, height: 700)]
        ))
    }

    func testDoctorRejectsInvalidAndUnexpectedSignaturesAndInactiveServer() {
        let policy = ZonalDoctorPolicy()
        XCTAssertEqual(policy.signatureFinding(identifier: "com.sebmarste.zonal", team: "XW6G452649", isValid: true).level, .ok)
        XCTAssertEqual(policy.signatureFinding(identifier: "com.sebmarste.zonal", team: nil, isValid: true).level, .warning)
        XCTAssertEqual(policy.signatureFinding(identifier: "com.sebmarste.zonal.dev", team: nil, isValid: true).level, .ok)
        XCTAssertEqual(policy.signatureFinding(identifier: "com.sebmarste.zonal.dev", team: nil, isValid: false).level, .error)
        XCTAssertEqual(policy.signatureFinding(identifier: "another.app", team: "XW6G452649", isValid: true).level, .warning)
        XCTAssertEqual(policy.signatureFinding(identifier: "com.sebmarste.zonal", team: "XW6G452649", isValid: false).level, .error)
        XCTAssertEqual(policy.automationFinding(isRunning: false).level, .warning)
        XCTAssertEqual(policy.automationFinding(isRunning: true).level, .ok)
    }

    func testFullscreenCompanionRequiresUniqueIdentityAndSameDisplayTopology() {
        let identity = WindowIdentity(bundleIdentifier: "test.app", processIdentifier: 42, cgWindowID: 10,
                                      axRole: "AXWindow", axSubrole: "AXStandardWindow", observedOrder: 0)
        let snapshot = DisplaySnapshot(displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                                                       visibleFrame: CGRect(x: 0, y: 24, width: 900, height: 676), scale: 1)])
        let policy = FullScreenCompanionPolicy()
        func accepts(_ identities: [WindowIdentity], current: DisplaySnapshot = snapshot, profile: String = "desk", fullscreen: Bool = true) -> Bool {
            policy.canUseCache(isFullScreen: fullscreen, focusedIdentity: identity, cachedIdentities: identities,
                               cachedProfileID: "desk", currentProfileID: profile, cachedDisplays: snapshot, currentDisplays: current)
        }
        XCTAssertTrue(accepts([identity]))
        XCTAssertFalse(accepts([]))
        XCTAssertFalse(accepts([identity, identity]))
        XCTAssertFalse(accepts([identity], profile: "mobile"))
        XCTAssertFalse(accepts([identity], fullscreen: false))
        var relocated = snapshot
        relocated.displays[0].frame.origin.y = 200
        XCTAssertFalse(accepts([identity], current: relocated))
        var sibling = identity
        sibling.cgWindowID = 11
        XCTAssertFalse(accepts([sibling]))
        XCTAssertTrue(policy.usesNativeSwitcher(isFullScreen: true, hasCompanion: false, fallbackEnabled: true))
        XCTAssertFalse(policy.usesNativeSwitcher(isFullScreen: true, hasCompanion: true, fallbackEnabled: true))
        XCTAssertFalse(policy.usesNativeSwitcher(isFullScreen: true, hasCompanion: false, fallbackEnabled: false))
        XCTAssertFalse(policy.usesNativeSwitcher(isFullScreen: false, hasCompanion: false, fallbackEnabled: true))
    }

    func testPeekDirectionsPreserveZoneEdgesAndCapTotalStrips() throws {
        let ids = [UUID(), UUID(), UUID()]
        let zone = CGRect(x: -900, y: 40, width: 600, height: 400)
        for direction in ZonePeekDirection.allCases {
            let frames = ZonePeekStackLayoutPolicy(preferredPeekWidth: 160).frames(
                in: zone, assignmentIDs: ids, activeAssignmentID: ids[0], direction: direction
            )
            let active = try XCTUnwrap(frames[ids[0]])
            XCTAssertTrue(zone.contains(active))
            for id in ids {
                XCTAssertEqual(frames[id]?.size, active.size)
                XCTAssertTrue(zone.contains(try XCTUnwrap(frames[id])))
            }
            if direction == .left || direction == .right {
                XCTAssertEqual(active.width, 360)
                XCTAssertEqual(direction == .left ? active.maxX : active.minX, direction == .left ? zone.maxX : zone.minX)
            } else {
                XCTAssertEqual(active.height, 240)
                XCTAssertEqual(direction == .top ? active.maxY : active.minY, direction == .top ? zone.maxY : zone.minY)
            }
        }
        var config = ZonalConfiguration.default
        config.profiles[0].zones[0].peekWidth = 96
        config.profiles[0].zones[0].peekDirection = .bottom
        XCTAssertEqual(try JSONDecoder().decode(ZonalConfiguration.self, from: JSONEncoder().encode(config)), config)
    }

    func testPeekFocusChangesNeverResizeAnyWindow() throws {
        let ids = [UUID(), UUID(), UUID()]
        let zone = CGRect(x: 100, y: 24, width: 1000, height: 800)
        for direction in ZonePeekDirection.allCases {
            let policy = ZonePeekStackLayoutPolicy()
            let before = policy.frames(in: zone, assignmentIDs: ids, activeAssignmentID: ids[0], direction: direction)
            for active in ids {
                let after = policy.frames(in: zone, assignmentIDs: ids.reversed(), activeAssignmentID: active, direction: direction)
                for id in ids {
                    let old = try XCTUnwrap(before[id])
                    let new = try XCTUnwrap(after[id])
                    XCTAssertEqual(old.size, new.size)
                    XCTAssertFalse(WindowPlacementGeometry().needsResize(from: old.size, to: new.size))
                }
            }
            let single = policy.frames(in: zone, assignmentIDs: [ids[0]], activeAssignmentID: ids[0], direction: direction)
            XCTAssertEqual(single[ids[0]], zone)
        }
    }

    func testPeekSettingsReflowWithoutDependingOnWorkspaceCache() {
        let original = DefaultProfiles.main
        var changed = original
        let zoneID = changed.zones[0].id
        changed.zones[0].windowPresentation = .peekStack
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: original, to: changed), [zoneID])
        let enabled = changed
        changed.zones[0].peekWidth = 96
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: enabled, to: changed), [zoneID])
        let widened = changed
        changed.zones[0].peekDirection = .right
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: widened, to: changed), [zoneID])
        let redirected = changed
        changed.zones[0].windowPresentation = .overlap
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: redirected, to: changed), [zoneID])
        XCTAssertTrue(ZoneReflowPolicy.changedZones(from: changed, to: changed).isEmpty)
    }

    func testEnhancedUIAnimationTransactionRestoresModeAfterPlacement() {
        var enhanced = true
        var writes: [Bool] = []
        var actual = CGRect(x: 650, y: 160, width: 586, height: 488)
        let target = CGRect(x: 56, y: 30, width: 596, height: 1050)
        AXFrameAdjustment.perform(readEnhancedUI: { enhanced }, writeEnhancedUI: {
            enhanced = $0
            writes.append($0)
        }) {
            WindowPlacementGeometry().apply(target, container: nil, readFrame: { actual },
                setSize: { size in
                    // Enhanced UI can defer/revert a resize when position changes follow.
                    if !enhanced { actual.size = size }
                    return true
                }, setPosition: { actual.origin = $0 }, isCurrent: { true })
        }
        XCTAssertEqual(actual, target)
        XCTAssertEqual(writes, [false, true])
        XCTAssertTrue(enhanced)
    }

    func testEnhancedUITransactionDoesNotEnableDisabledOrUnavailableMode() {
        for initial: Bool? in [false, nil] {
            var writes: [Bool] = []
            var performed = false
            AXFrameAdjustment.perform(readEnhancedUI: { initial }, writeEnhancedUI: { writes.append($0) }) {
                performed = true
            }
            XCTAssertTrue(performed)
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testCancelledPlacementRestoresEnhancedUI() {
        var writes: [Bool] = []
        AXFrameAdjustment.perform(readEnhancedUI: { true }, writeEnhancedUI: { writes.append($0) }) {
            WindowPlacementGeometry().apply(CGRect(x: 0, y: 0, width: 900, height: 700),
                container: nil, readFrame: { nil },
                setSize: { _ in XCTFail("Cancelled placement must not resize"); return false },
                setPosition: { _ in XCTFail("Cancelled placement must not move") }, isCurrent: { false })
        }
        XCTAssertEqual(writes, [false, true])
    }

    func testPositionOnlyPlacementSkipsSizeWritesButRealResizeDoesNot() {
        let geometry = WindowPlacementGeometry()
        let size = CGSize(width: 700, height: 600)
        XCTAssertFalse(geometry.needsResize(from: size, to: size))
        XCTAssertTrue(geometry.needsResize(from: size, to: CGSize(width: 701, height: 599)))
        XCTAssertTrue(geometry.needsResize(from: size, to: CGSize(width: 698, height: 598)))
        XCTAssertFalse(geometry.needsResize(from: size, to: CGSize(width: 700.005, height: 599.995)))
        XCTAssertTrue(geometry.needsResize(from: size, to: CGSize(width: 750, height: 600)))
        XCTAssertTrue(geometry.needsResize(from: size, to: CGSize(width: 700, height: 900)))
    }

    func testBorderReductionCanGrowWindowsAtDisplayEdges() {
        let display = CGRect(x: 0, y: 30, width: 5120, height: 1410)
        for zone in [CGRect(x: 3789, y: 30, width: 1331, height: 1410),
                     CGRect(x: 0, y: 30, width: 5120, height: 1410)] {
            for edge in ZoneTabEdge.allCases {
                var actual = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: 6).windowFrame
                let target = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: 0).windowFrame
                WindowPlacementGeometry().apply(target, container: display, readFrame: { actual }, setSize: { size in
                    // Chromium clips growth at the current screen-edge position.
                    actual.size = CGSize(width: min(size.width, display.maxX - actual.minX),
                                         height: min(size.height, display.maxY - actual.minY))
                    return true
                }, setPosition: { actual.origin = $0 }, isCurrent: { true })
                XCTAssertEqual(actual, target, "\(edge): reposition before retrying screen-edge growth")
            }
        }
    }

    func testPlacementSchedulerDoesNotSkipSmallSizeChangesAtTheSamePosition() {
        let access = SettlingPlacementAccess(deferred: false)
        let completed = expectation(description: "small resize applied")
        let target = CGRect(x: 0, y: 0, width: 102, height: 98)
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0), sink: AXPlacementResultSink { result in
            XCTAssertEqual(result.actual, target)
            XCTAssertEqual(result.writes, 1)
            completed.fulfill()
        }, access: access)
        scheduler.submit(AXPlacementJob(token: UUID(), windowID: .quartz(processIdentifier: 42, windowNumber: 1),
            pid: 42, element: AXUIElementCreateApplication(42), target: target, container: nil))
        wait(for: [completed], timeout: 2)
    }

    func testPlacementSchedulerSupersedesRunningAndQueuedJobs() {
        let access = BlockingPlacementAccess()
        let completed = expectation(description: "old and final jobs finish")
        completed.expectedFulfillmentCount = 2
        let results = PlacementResults()
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0), sink: AXPlacementResultSink {
            results.append($0)
            completed.fulfill()
        }, access: access)
        let element = AXUIElementCreateApplication(42)
        let id = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 10)
        func job(_ x: CGFloat) -> AXPlacementJob {
            AXPlacementJob(token: UUID(), windowID: id, pid: 42, element: element,
                           target: CGRect(x: x, y: 20, width: 400, height: 300), container: nil)
        }
        let first = job(100), second = job(200), last = job(300)
        scheduler.submit(first)
        XCTAssertEqual(access.started.wait(timeout: .now() + 2), .success)
        scheduler.submit(second)
        scheduler.submit(last)
        access.resume.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(results.values.map(\.token), [first.token, last.token])
        XCTAssertEqual(results.values.map(\.outcome), [.superseded, .placed])
        XCTAssertEqual(access.writes, [last.target])
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scheduler.diagnosticSummary().contains("lanes=0")
        }, object: nil)
        wait(for: [idle], timeout: 2)
    }

    func testPlacementSchedulerRemovalCancelsBlockedWriteAndPrunesConstraints() {
        let access = BlockingPlacementAccess()
        let completed = expectation(description: "removed job finishes")
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0), sink: AXPlacementResultSink { result in
            XCTAssertEqual(result.outcome, .superseded)
            completed.fulfill()
        }, access: access)
        let id = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 10)
        scheduler.submit(AXPlacementJob(token: UUID(), windowID: id, pid: 42,
                                       element: AXUIElementCreateApplication(42),
                                       target: CGRect(x: 100, y: 20, width: 400, height: 300), container: nil))
        XCTAssertEqual(access.started.wait(timeout: .now() + 2), .success)
        scheduler.retainWindows([])
        access.resume.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(access.writes.isEmpty)
        var memory = WindowConstraintMemory()
        let requested = CGRect(x: 0, y: 0, width: 100, height: 100)
        let actual = CGRect(x: 0, y: 0, width: 300, height: 200)
        _ = memory.observe(windowID: id, requested: requested, actual: actual)
        _ = memory.observe(windowID: id, requested: requested, actual: actual)
        memory.retain([])
        XCTAssertEqual(memory.reachableSize(for: id, requested: requested.size), requested.size)
        XCTAssertNil(memory.observe(windowID: id, requested: requested, actual: actual))
    }

    func testBlockedApplicationDoesNotBlockAnotherPlacementLane() {
        let access = BlockingPlacementAccess()
        let independent = expectation(description: "second app completes while first is blocked")
        let blocked = expectation(description: "first app completes after release")
        let scheduler = AXPlacementScheduler(policy: .init(settleDelay: 0), sink: AXPlacementResultSink { result in
            XCTAssertEqual(result.outcome, .placed)
            if result.windowID == .quartz(processIdentifier: 43, windowNumber: 11) {
                independent.fulfill()
            } else {
                blocked.fulfill()
            }
        }, access: access)
        func job(pid: Int32, number: UInt32, x: CGFloat) -> AXPlacementJob {
            AXPlacementJob(token: UUID(), windowID: .quartz(processIdentifier: pid, windowNumber: number),
                           pid: pid, element: AXUIElementCreateApplication(pid),
                           target: CGRect(x: x, y: 20, width: 400, height: 300), container: nil)
        }
        scheduler.submit(job(pid: 42, number: 10, x: 100))
        XCTAssertEqual(access.started.wait(timeout: .now() + 2), .success)
        scheduler.submit(job(pid: 43, number: 11, x: 200))
        wait(for: [independent], timeout: 2)
        access.resume.signal()
        wait(for: [blocked], timeout: 2)
    }



}
