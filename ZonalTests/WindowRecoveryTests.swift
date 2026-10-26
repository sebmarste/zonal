import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

final class WindowRecoveryTests: XCTestCase {
    func testRestorePlannerSeparatesMovesFromAlreadyPlacedWindows() {
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1
        )
        let unchangedID = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 100)
        let movedID = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 101)
        let resizedID = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 102)
        let target = CGRect(x: 0, y: 0, width: 500, height: 800)
        let plan = RestorePlanner().plan([
            RestorePlanCandidate(
                windowID: unchangedID,
                identity: identity,
                currentFrame: target,
                targetFrame: target,
                containerFrame: target
            ),
            RestorePlanCandidate(
                windowID: movedID,
                identity: identity,
                currentFrame: target.offsetBy(dx: 1, dy: -1),
                targetFrame: target,
                containerFrame: target
            ),
            RestorePlanCandidate(
                windowID: resizedID,
                identity: identity,
                currentFrame: CGRect(x: 0, y: 0, width: 500, height: 799),
                targetFrame: target,
                containerFrame: target
            )
        ])

        XCTAssertEqual(plan.unchangedWindowIDs, [unchangedID])
        XCTAssertEqual(plan.moves.map(\.windowID), [movedID, resizedID])
    }

    func testWakeAfterUnlockSchedulesRecoveryInsteadOfLeavingTabsHidden() {
        var policy = SessionRecoverySignalPolicy()
        XCTAssertTrue(policy.canPresentTabs)
        XCTAssertEqual(policy.action(for: .inactive), .freeze)
        XCTAssertFalse(policy.canPresentTabs)
        XCTAssertEqual(policy.action(for: .wake), .freeze, "Never restore into the lock screen")
        XCTAssertFalse(policy.canPresentTabs)
        XCTAssertEqual(policy.action(for: .active), .restore)
        XCTAssertTrue(policy.canPresentTabs)
        // Observed unplug sequence: screenIsLocked, screenIsUnlocked, didWake.
        XCTAssertEqual(policy.action(for: .wake), .restore)
        XCTAssertEqual(policy.action(for: .wake), .restore, "Repeated wake signals still schedule completion")
        XCTAssertEqual(policy.action(for: .displaySleep), .freeze)
        XCTAssertFalse(policy.canPresentTabs)
        XCTAssertEqual(policy.action(for: .wake), .restore, "Display sleep without locking also resumes")
        XCTAssertTrue(policy.canPresentTabs)
        XCTAssertEqual(policy.action(for: .inactive), .freeze)
        XCTAssertEqual(policy.action(for: .displaySleep), .freeze)
        XCTAssertEqual(policy.action(for: .wake), .freeze)
        XCTAssertEqual(policy.action(for: .active), .restore)
    }

    func testSessionRecoveryCoalescesSignalsAndTracksExplicitUserAdjustments() {
        let firstWindow = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 100)
        let secondWindow = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 101)
        var recovery = SessionRecoveryState()

        XCTAssertTrue(recovery.begin())
        XCTAssertFalse(recovery.begin())
        XCTAssertFalse(recovery.beginRestore())
        XCTAssertTrue(recovery.markInventoryReady())
        XCTAssertFalse(recovery.markInventoryReady())
        XCTAssertTrue(recovery.beginRestore())
        XCTAssertFalse(recovery.beginRestore())
        recovery.recordUserAdjustment(to: firstWindow)

        XCTAssertFalse(recovery.shouldRestore(firstWindow))
        XCTAssertTrue(recovery.shouldRestore(secondWindow))

        recovery.finish()
        XCTAssertFalse(recovery.isActive)
        XCTAssertFalse(recovery.isInventoryReady)
        XCTAssertTrue(recovery.shouldRestore(firstWindow))
    }

    func testSessionRestoreWaitsForTheFrozenDisplaySetupToStabilize() {
        let external = DisplaySignature(
            displayCount: 1,
            displays: [.init(width: 5120, height: 1440, scale: 1)]
        )
        let builtIn = DisplaySignature(
            displayCount: 1,
            displays: [.init(width: 3024, height: 1964, scale: 2)]
        )
        let start = Date(timeIntervalSince1970: 100)
        let externalBindingID = UUID()
        var readiness = SessionDisplayReadinessState()
        readiness.begin(
            expectation: SessionDisplayExpectation(
                profileID: "workspace",
                setupBindingID: externalBindingID,
                signature: external
            ),
            now: start
        )

        XCTAssertEqual(readiness.observe(
            profileID: "workspace",
            setupBindingID: UUID(),
            signature: builtIn,
            now: start.addingTimeInterval(1)
        ), .waiting)
        XCTAssertEqual(readiness.observe(
            profileID: "workspace",
            setupBindingID: externalBindingID,
            signature: external,
            now: start.addingTimeInterval(2)
        ), .waiting)
        XCTAssertEqual(readiness.observe(
            profileID: "workspace",
            setupBindingID: externalBindingID,
            signature: external,
            now: start.addingTimeInterval(2.25)
        ), .ready)
    }

    func testSessionRestoreAcceptsStableChangedSetupWithoutWaitingForOldSetupTimeout() {
        let start = Date(timeIntervalSince1970: 100)
        let laptop = DisplaySignature(displayCount: 1, displays: [.init(width: 1800, height: 1169, scale: 2)])
        let external = DisplaySignature(displayCount: 1, displays: [.init(width: 5120, height: 1440, scale: 1)])
        let laptopBinding = UUID(), externalBinding = UUID()
        var readiness = SessionDisplayReadinessState()
        readiness.begin(expectation: SessionDisplayExpectation(profileID: "main", setupBindingID: laptopBinding,
                                                              signature: laptop), now: start)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: externalBinding,
            signature: external, now: start.addingTimeInterval(1)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: externalBinding,
            signature: external, now: start.addingTimeInterval(1.25)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: externalBinding,
            signature: external, now: start.addingTimeInterval(3)), .ready)
        XCTAssertEqual(readiness.readyDestination?.profileID, "uw")
        XCTAssertFalse(readiness.usesFrozenTargets, "Never apply laptop targets to the ultrawide")
        readiness.invalidateCandidate()
        XCTAssertNil(readiness.readyDestination, "Inventory barrier must revalidate after a topology notification")
        XCTAssertEqual(readiness.observe(profileID: "main", setupBindingID: laptopBinding,
            signature: laptop, now: start.addingTimeInterval(3.25)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "main", setupBindingID: laptopBinding,
            signature: laptop, now: start.addingTimeInterval(3.5)), .ready)
        XCTAssertTrue(readiness.usesFrozenTargets)
    }

    func testSlowWakeHardwareCanAppearAfterOldTimeoutWithoutReleasingRecovery() {
        let start = Date(timeIntervalSince1970: 100)
        let laptop = DisplaySignature(displayCount: 1, displays: [.init(width: 1800, height: 1169, scale: 2)])
        let external = DisplaySignature(displayCount: 1, displays: [.init(width: 5120, height: 1440, scale: 1)])
        let binding = UUID()
        var readiness = SessionDisplayReadinessState()
        readiness.begin(expectation: SessionDisplayExpectation(profileID: "main", setupBindingID: UUID(),
                                                              signature: laptop), now: start)
        XCTAssertEqual(readiness.observe(profileID: nil, setupBindingID: nil,
            signature: laptop, now: start.addingTimeInterval(12)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: external, now: start.addingTimeInterval(16)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: external, now: start.addingTimeInterval(18)), .ready)
        XCTAssertFalse(readiness.usesFrozenTargets)
        readiness.invalidateCandidate()
        XCTAssertEqual(readiness.observe(profileID: nil, setupBindingID: nil,
            signature: external, now: start.addingTimeInterval(30)), .timedOut)
    }

    func testChangedRecoveryDestinationMustRemainConfiguredAndStable() {
        let start = Date(timeIntervalSince1970: 100)
        let first = DisplaySignature(displayCount: 1, displays: [.init(width: 1800, height: 1169, scale: 2)])
        let second = DisplaySignature(displayCount: 1, displays: [.init(width: 5120, height: 1440, scale: 1)])
        let binding = UUID()
        var readiness = SessionDisplayReadinessState()
        readiness.begin(expectation: nil, now: start)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: second, now: start.addingTimeInterval(1)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: first, now: start.addingTimeInterval(2)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: nil,
            signature: second, now: start.addingTimeInterval(3)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: second, now: start.addingTimeInterval(4)), .waiting)
        XCTAssertEqual(readiness.observe(profileID: "uw", setupBindingID: binding,
            signature: second, now: start.addingTimeInterval(6)), .ready)
        XCTAssertFalse(readiness.usesFrozenTargets)
        readiness.finish()
        XCTAssertNil(readiness.readyDestination)
        XCTAssertEqual(readiness.stableSamples, 0)
    }

    func testSessionRestoreRetryPreservesInventoryAndMouseOptOut() {
        let dragged = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 1)
        var recovery = SessionRecoveryState()
        XCTAssertTrue(recovery.begin())
        XCTAssertTrue(recovery.markInventoryReady())
        recovery.recordUserAdjustment(to: dragged)
        XCTAssertTrue(recovery.beginRestore())
        recovery.retryRestore()
        XCTAssertTrue(recovery.isActive)
        XCTAssertTrue(recovery.isInventoryReady)
        XCTAssertFalse(recovery.shouldRestore(dragged))
        XCTAssertTrue(recovery.beginRestore())
    }

    func testSessionRestoreTimesOutWithoutAcceptingTemporaryBuiltInDisplay() {
        let external = DisplaySignature(
            displayCount: 1,
            displays: [.init(width: 5120, height: 1440, scale: 1)]
        )
        let builtIn = DisplaySignature(
            displayCount: 1,
            displays: [.init(width: 3024, height: 1964, scale: 2)]
        )
        let start = Date(timeIntervalSince1970: 100)
        let externalBindingID = UUID()
        var readiness = SessionDisplayReadinessState(timeout: 3)
        readiness.begin(
            expectation: SessionDisplayExpectation(
                profileID: "workspace",
                setupBindingID: externalBindingID,
                signature: external
            ),
            now: start
        )

        XCTAssertEqual(readiness.observe(
            profileID: "workspace",
            setupBindingID: UUID(),
            signature: builtIn,
            now: start.addingTimeInterval(3)
        ), .timedOut)
    }

    func testSessionDisplayTimeoutStartsAtUnlockRatherThanSleep() {
        let external = DisplaySignature(
            displayCount: 1,
            displays: [.init(width: 5120, height: 1440, scale: 1)]
        )
        let expectation = SessionDisplayExpectation(
            profileID: "workspace",
            setupBindingID: UUID(),
            signature: external
        )
        let unlock = Date(timeIntervalSince1970: 10_000)
        var readiness = SessionDisplayReadinessState(timeout: 3)

        readiness.begin(expectation: expectation, now: unlock)

        XCTAssertEqual(readiness.observe(
            profileID: nil,
            setupBindingID: nil,
            signature: external,
            now: unlock.addingTimeInterval(1)
        ), .waiting)
        XCTAssertEqual(readiness.observe(
            profileID: nil,
            setupBindingID: nil,
            signature: external,
            now: unlock.addingTimeInterval(3)
        ), .timedOut)
    }

    func testDisplayTransitionFreezesCaptureAndPreservesUserGestureOptOut() {
        let policy = CustomFrameCapturePolicy()
        var state = DisplayTransitionState()
        let untouched = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 1)
        let dragged = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 2)
        let first = state.begin()
        XCTAssertFalse(policy.shouldCapture(isSessionRecoveryActive: false, isApplyingPlacement: false,
            hasActiveUserInteraction: false, isFullScreen: false, isMinimized: false,
            isDisplayTransitionActive: state.generation != nil))
        state.recordUserAdjustment(to: dragged)
        XCTAssertFalse(state.shouldRestore(dragged))
        XCTAssertTrue(state.shouldRestore(untouched))
        let second = state.begin()
        XCTAssertFalse(state.finish(generation: first))
        XCTAssertNotNil(state.generation)
        XCTAssertFalse(state.shouldRestore(dragged))
        XCTAssertTrue(state.finish(generation: second))
        XCTAssertTrue(state.shouldRestore(dragged))
        XCTAssertTrue(policy.shouldCapture(isSessionRecoveryActive: false, isApplyingPlacement: false,
            hasActiveUserInteraction: false, isFullScreen: false, isMinimized: false,
            isDisplayTransitionActive: state.generation != nil))
    }

    func testAutomaticFrameCaptureIsSuppressedThroughoutSessionRecovery() {
        let policy = CustomFrameCapturePolicy()

        XCTAssertFalse(policy.shouldCapture(
            isSessionRecoveryActive: true,
            isApplyingPlacement: false,
            hasActiveUserInteraction: false,
            isFullScreen: false,
            isMinimized: false
        ))
        XCTAssertTrue(policy.shouldCapture(
            isSessionRecoveryActive: false,
            isApplyingPlacement: false,
            hasActiveUserInteraction: false,
            isFullScreen: false,
            isMinimized: false
        ))
    }

    func testPlacementRetryPolicyCoversDelayedWindowConstraints() {
        let policy = WindowPlacementRetryPolicy()

        XCTAssertEqual(policy.maximumWrites, 2)
        XCTAssertGreaterThan(policy.settleDelay, 0)
        XCTAssertGreaterThan(policy.suppressionDuration, policy.settleDelay)
    }

    func testWindowConstraintRequiresRepeatedMatchingRefusal() {
        let id = LiveWindowID.quartz(processIdentifier: 7, windowNumber: 9)
        let requested = CGRect(x: 10, y: 20, width: 400, height: 300)
        let refused = CGRect(x: 10, y: 20, width: 520, height: 300)
        var memory = WindowConstraintMemory()

        XCTAssertNil(memory.observe(windowID: id, requested: requested, actual: refused))
        XCTAssertEqual(
            memory.observe(windowID: id, requested: requested, actual: refused),
            WindowSizeConstraints(minimumWidth: 520)
        )
        XCTAssertEqual(
            memory.reachableSize(for: id, requested: requested.size),
            CGSize(width: 520, height: 300)
        )
    }

    func testWindowConstraintLearnsRepeatedMaximumSizeRefusal() {
        let id = LiveWindowID.quartz(processIdentifier: 7, windowNumber: 10)
        let requested = CGRect(x: 0, y: 0, width: 1_380, height: 1_410)
        let refused = CGRect(x: 710, y: 0, width: 670, height: 800)
        var memory = WindowConstraintMemory()

        XCTAssertNil(memory.observe(windowID: id, requested: requested, actual: refused))
        XCTAssertEqual(
            memory.observe(windowID: id, requested: requested, actual: refused),
            WindowSizeConstraints(maximumWidth: 670, maximumHeight: 800)
        )
        XCTAssertEqual(
            memory.reachableSize(for: id, requested: requested.size),
            CGSize(width: 670, height: 800)
        )
        XCTAssertEqual(
            memory.reachableSize(for: id, requested: CGSize(width: 500, height: 600)),
            CGSize(width: 500, height: 600)
        )
    }

    func testAccordionKeepsActiveWindowLastAndLimitsPeekArea() {
        let ids = [UUID(), UUID(), UUID()]
        let zone = CGRect(x: 0, y: 0, width: 300, height: 500)
        let frames = ZonePeekStackLayoutPolicy().frames(
            in: zone,
            assignmentIDs: ids,
            activeAssignmentID: ids[0]
        )

        XCTAssertEqual(frames[ids[1]]?.minX, 0)
        XCTAssertEqual(frames[ids[2]]?.minX, 48)
        XCTAssertEqual(frames[ids[0]]?.minX, 96)
        XCTAssertEqual(frames[ids[0]]?.maxX, zone.maxX)
    }

    func testFullHeightPlacementMovesConstrainedWindowToTopBeforeRetryingSize() {
        let container = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let fullHeightZone = CGRect(x: 960, y: 25, width: 480, height: 875)

        let position = WindowPlacementGeometry().position(
            for: fullHeightZone,
            actualSize: CGSize(width: 480, height: 420),
            in: container
        )

        XCTAssertEqual(position, CGPoint(x: 960, y: 25))
    }

    func testTrailingOnlyPlacementKeepsConstrainedWindowAtTrailingEdge() {
        let container = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let bottomRightZone = CGRect(x: 960, y: 500, width: 480, height: 400)

        let position = WindowPlacementGeometry().position(
            for: bottomRightZone,
            actualSize: CGSize(width: 360, height: 300),
            in: container
        )

        XCTAssertEqual(position, CGPoint(x: 1_080, y: 600))
    }

    func testRestoreTriggerDebounceKeepsTheMostImportantCause() {
        XCTAssertEqual(
            RestoreTrigger.displayChange.preferred(over: .applicationLifecycle),
            .displayChange
        )
        XCTAssertEqual(
            RestoreTrigger.systemResume.preferred(over: .spaceChange),
            .systemResume
        )
        XCTAssertEqual(RestoreTrigger.systemResume.discoverySettleDelay, 0)
        XCTAssertGreaterThan(
            RestoreTrigger.displayChange.discoverySettleDelay,
            WindowRescanPolicy().followUpDelays.last ?? 0
        )
    }

    func testRestoreTriggersRequireInventoryBarrierAtConsistencyBoundaries() {
        XCTAssertTrue(RestoreTrigger.launch.requiresInventoryBarrier)
        XCTAssertTrue(RestoreTrigger.systemResume.requiresInventoryBarrier)
        XCTAssertTrue(RestoreTrigger.spaceChange.requiresInventoryBarrier)
        XCTAssertTrue(RestoreTrigger.displayChange.requiresInventoryBarrier)
        XCTAssertTrue(RestoreTrigger.manual.requiresInventoryBarrier)
        XCTAssertTrue(RestoreTrigger.profileApply.requiresInventoryBarrier)

        XCTAssertFalse(RestoreTrigger.applicationLifecycle.requiresInventoryBarrier)
    }

    func testApplicationLifecycleRestoreIsSilentEvenWhenItMovesAWindow() {
        XCTAssertNil(
            RestoreToastPolicy().content(
                for: .applicationLifecycle,
                profileName: "Laptop",
                summary: RestoreRunSummary(moved: 1, unchanged: 0, skipped: 0)
            )
        )
    }

    func testApplicationLifecycleRestoreOnlyIncludesTheLaunchedApplication() {
        let scope = RestoreWindowScope()

        XCTAssertTrue(
            scope.includes(
                bundleIdentifier: "com.example.Editor",
                trigger: .applicationLifecycle,
                applicationBundleIdentifiers: ["com.example.Editor"]
            )
        )
        XCTAssertFalse(
            scope.includes(
                bundleIdentifier: "com.example.Browser",
                trigger: .applicationLifecycle,
                applicationBundleIdentifiers: ["com.example.Editor"]
            )
        )
        XCTAssertTrue(
            scope.includes(
                bundleIdentifier: "com.example.Browser",
                trigger: .profileApply,
                applicationBundleIdentifiers: ["com.example.Editor"]
            )
        )
    }

    func testFailedAutomaticRestoreProducesWarningInsteadOfSuccess() {
        let content = RestoreToastPolicy().content(
            for: .systemResume,
            profileName: "Laptop",
            summary: RestoreRunSummary(
                moved: 0,
                unchanged: 0,
                skipped: 0,
                failed: 1
            )
        )

        XCTAssertEqual(content?.detail, "1 window could not be restored")
        XCTAssertEqual(content?.tone, .warning)
        XCTAssertNil(content?.actionTitle)
    }

    func testPlacementRecoveryRequiresAUniqueNearbySavedFrame() {
        let leftID = UUID()
        let rightID = UUID()
        let matcher = WindowPlacementRecoveryMatcher()
        let candidates = [
            WindowPlacementRecoveryCandidate(
                assignmentID: leftID,
                targetFrame: CGRect(x: 0, y: 0, width: 500, height: 800)
            ),
            WindowPlacementRecoveryCandidate(
                assignmentID: rightID,
                targetFrame: CGRect(x: 500, y: 0, width: 500, height: 800)
            )
        ]

        XCTAssertEqual(
            matcher.assignmentID(
                for: CGRect(x: 2, y: 0, width: 498, height: 800),
                candidates: candidates
            ),
            leftID
        )
        XCTAssertNil(
            matcher.assignmentID(
                for: CGRect(x: 240, y: 0, width: 500, height: 800),
                candidates: candidates
            )
        )
        XCTAssertNil(
            matcher.assignmentID(
                for: CGRect(x: 0, y: 0, width: 500, height: 800),
                candidates: [
                    WindowPlacementRecoveryCandidate(
                        assignmentID: leftID,
                        targetFrame: CGRect(x: 0, y: 0, width: 500, height: 800)
                    ),
                    WindowPlacementRecoveryCandidate(
                        assignmentID: rightID,
                        targetFrame: CGRect(x: 0, y: 0, width: 500, height: 800)
                    )
                ]
            )
        )
    }

    func testDisplayPlacementFrameUsesVisibleFrame() {
        let display = DisplaySnapshot.Display(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
            visibleFrame: CGRect(x: 0, y: 40, width: 5000, height: 1360),
            scale: 2
        )

        XCTAssertEqual(display.placementFrame, CGRect(x: 0, y: 40, width: 5000, height: 1360))
    }




}
