import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

final class WindowInteractionTests: XCTestCase {
    func testAutomaticNoOpRestoreDoesNotProduceToast() {
        let summary = RestoreRunSummary(moved: 0, unchanged: 4, skipped: 0)
        let policy = RestoreToastPolicy()

        XCTAssertNil(policy.content(for: .applicationLifecycle, profileName: "Laptop", summary: summary))
        XCTAssertNil(policy.content(for: .spaceChange, profileName: "Laptop", summary: summary))
        XCTAssertNil(policy.content(for: .systemResume, profileName: "Laptop", summary: summary))
        XCTAssertNil(policy.content(for: .displayChange, profileName: "Laptop", summary: summary))
    }

    func testAutomaticRestoreWithActualMovementProducesAccurateToast() {
        let content = RestoreToastPolicy().content(
            for: .spaceChange,
            profileName: "Laptop",
            summary: RestoreRunSummary(moved: 2, unchanged: 1, skipped: 0)
        )

        XCTAssertEqual(content?.title, "Laptop")
        XCTAssertEqual(content?.detail, "2 windows restored")
        XCTAssertEqual(content?.actionTitle, "Undo")
    }

    func testRestoreToastReportsOnlyVerifiedOutcomes() {
        let content = RestoreToastPolicy().content(
            for: .systemResume,
            profileName: "Laptop",
            summary: RestoreRunSummary(
                moved: 1,
                unchanged: 0,
                skipped: 0,
                failed: 1,
                userAdjusted: 1
            )
        )

        XCTAssertEqual(
            content?.detail,
            "1 window restored · 1 user adjustment kept · 1 failed"
        )
        XCTAssertEqual(content?.tone, .warning)
        XCTAssertEqual(content?.actionTitle, "Undo")
    }

    func testSwitcherHoverRequiresPointerMovementAfterKeyboardInteraction() {
        let policy = SwitcherHoverActivationPolicy()
        let anchor = CGPoint(x: 120, y: 240)

        XCTAssertFalse(policy.shouldActivate(pointerLocation: anchor, since: anchor))
        XCTAssertFalse(policy.shouldActivate(
            pointerLocation: CGPoint(x: 120.2, y: 240.2),
            since: anchor
        ))
        XCTAssertTrue(policy.shouldActivate(
            pointerLocation: CGPoint(x: 121, y: 240),
            since: anchor
        ))
    }

    func testDragUpdatesRunImmediatelyThenCoalesceToDisplayCadence() {
        let policy = DragEventCoalescingPolicy(maximumUpdatesPerSecond: 120)

        XCTAssertEqual(policy.delay(since: nil, now: 10), 0)
        XCTAssertEqual(
            policy.delay(since: 10, now: 10.004),
            1.0 / 120.0 - 0.004,
            accuracy: 0.000_001
        )
        XCTAssertEqual(policy.delay(since: 10, now: 10.009), 0)
    }

    func testZoneDragSnapsToAnotherZoneAndOptionBypassesIt() {
        let left = Zone(
            id: .left,
            name: "Left",
            frame: NormalizedFrame(x: 0, y: 0, width: 0.4, height: 1)
        )
        let proposed = NormalizedFrame(x: 0.405, y: 0, width: 0.3, height: 1)
        let policy = ZoneGeometrySnappingPolicy()

        let snapped = policy.snappedDrag(
            proposed: proposed,
            movingZoneID: .right,
            zones: [left],
            horizontalThreshold: 0.01,
            verticalThreshold: 0.01,
            isDisabled: false
        )
        XCTAssertEqual(snapped.frame.x, 0.4)
        XCTAssertTrue(snapped.guides.contains(
            ZoneSnapGuide(axis: .vertical, position: 0.4, label: "Left")
        ))

        let bypassed = policy.snappedDrag(
            proposed: proposed,
            movingZoneID: .right,
            zones: [left],
            horizontalThreshold: 0.01,
            verticalThreshold: 0.01,
            isDisabled: true
        )
        XCTAssertEqual(bypassed.frame.x, 0.41)
        XCTAssertTrue(bypassed.guides.isEmpty)
    }

    func testSharedBoundaryResizePreservesNeighborFarEdges() {
        let top = ZoneID(rawValue: "top")
        let bottom = ZoneID(rawValue: "bottom")
        let original: [ZoneID: NormalizedFrame] = [
            top: NormalizedFrame(x: 0, y: 0, width: 0.5, height: 0.5),
            bottom: NormalizedFrame(x: 0, y: 0.5, width: 0.5, height: 0.5),
            .right: NormalizedFrame(x: 0.5, y: 0, width: 0.5, height: 1)
        ]

        let horizontal = ZoneSharedBoundaryPolicy().resizedLayout(
            zoneID: top,
            from: original,
            to: NormalizedFrame(x: 0, y: 0, width: 0.6, height: 0.5),
            linkHorizontalBoundary: true,
            linkVerticalBoundary: false
        )
        XCTAssertEqual(horizontal[top]?.width, 0.6)
        XCTAssertEqual(horizontal[.right]?.x, 0.6)
        XCTAssertEqual(horizontal[.right]?.width, 0.4)

        let vertical = ZoneSharedBoundaryPolicy().resizedLayout(
            zoneID: top,
            from: original,
            to: NormalizedFrame(x: 0, y: 0, width: 0.5, height: 0.6),
            linkHorizontalBoundary: false,
            linkVerticalBoundary: true
        )
        XCTAssertEqual(vertical[top]?.height, 0.6)
        XCTAssertEqual(vertical[bottom]?.y, 0.6)
        XCTAssertEqual(vertical[bottom]?.height, 0.4)
    }

    func testWindowDragClassifierUsesPointerLocationOnlyForResizeEdges() {
        let classifier = WindowDragGestureClassifier()
        let bounds = CGRect(x: 100, y: 100, width: 700, height: 500)

        XCTAssertEqual(
            classifier.pointerIntent(at: CGPoint(x: 450, y: 136), windowBounds: bounds),
            .regular
        )
        XCTAssertEqual(
            classifier.pointerIntent(at: CGPoint(x: 104, y: 136), windowBounds: bounds),
            .resizeEdge
        )
        XCTAssertEqual(
            classifier.pointerIntent(at: CGPoint(x: 104, y: 104), windowBounds: bounds),
            .resizeEdge
        )
        XCTAssertEqual(
            classifier.pointerIntent(at: CGPoint(x: 450, y: 104), windowBounds: bounds),
            .regular
        )
    }

    func testClickFocusPeekMovementDoesNotBecomeManualDrag() {
        let initial = CGRect(x: 1331, y: 30, width: 2410, height: 1410)
        var gesture = WindowDragGesture(
            window: managedWindow(cgWindowID: 15964, observedOrder: 0),
            initialEventLocation: CGPoint(x: 1350.394531, y: 441.972656),
            lastEventLocation: CGPoint(x: 1350.394531, y: 441.972656),
            initialFrame: initial, lastFrame: initial, beganAt: 0
        )
        let classifier = WindowDragGestureClassifier()
        // Replay the MacBook click: a 48pt focus reflow, but only 0.375pt of pointer jitter.
        for (time, pointerX) in [(0.028, 1350.144531), (0.066, 1350.019531), (1.0, 1350.019531)] {
            gesture.lastEventLocation.x = pointerX
            gesture.observe(frame: initial.offsetBy(dx: 48, dy: 0), timestamp: time)
            let classification = classifier.classify(current: .undecided, pointerIntent: .regular,
                evidence: gesture.evidence, dragThreshold: 6, resizeThreshold: 6, forceDecision: true)
            XCTAssertEqual(classification, .undecided)
            XCTAssertNil(WindowInteractionClassifier().action(for: classification,
                zoneDropIsActive: true, dropIntent: .custom(.main)))
        }
        XCTAssertEqual(gesture.evidence.maximumPositionDistance, 48)
        XCTAssertEqual(gesture.evidence.maximumPointerDistance, 0.375, accuracy: 0.001)
    }

    func testStationaryPointerCannotTurnAutomaticResizeIntoManualResize() {
        for intent: WindowPointerIntent in [.regular, .resizeEdge] {
            XCTAssertEqual(WindowDragGestureClassifier().classify(current: .undecided, pointerIntent: intent,
                evidence: WindowGestureEvidence(maximumPositionDistance: 48, maximumSizeDistance: 48,
                                                sampleCount: 4, elapsed: 1),
                dragThreshold: 6, resizeThreshold: 6, forceDecision: true), .undecided)
        }
    }

    func testGestureRetainsPointerTravelWhenReturningToStartingPoint() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        var gesture = WindowDragGesture(window: managedWindow(cgWindowID: 30, observedOrder: 0),
            initialEventLocation: CGPoint(x: 200, y: 120), lastEventLocation: CGPoint(x: 220, y: 120),
            initialFrame: initial, lastFrame: initial)
        gesture.observe(frame: initial.offsetBy(dx: 20, dy: 0), timestamp: 0.1)
        gesture.lastEventLocation = gesture.initialEventLocation
        gesture.observe(frame: initial, timestamp: 0.2)
        XCTAssertEqual(gesture.evidence.maximumPointerDistance, 20)
        XCTAssertEqual(WindowDragGestureClassifier().classify(current: .undecided, pointerIntent: .regular,
            evidence: gesture.evidence, dragThreshold: 6, resizeThreshold: 6), .drag)
    }

    func testWindowDragDefaultRecognizesSixPointWindowMovement() {
        let classifier = WindowDragGestureClassifier()

        XCTAssertEqual(WindowDragGestureClassifier.defaultDragThreshold, 6)
        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: .regular,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 7,
                    maximumPositionDistance: 7,
                    maximumSizeDistance: 0,
                    sampleCount: 1,
                    elapsed: 0.01
                ),
                dragThreshold: WindowDragGestureClassifier.defaultDragThreshold,
                resizeThreshold: 6
            ),
            .drag
        )
    }

    func testDelayedTopLeftResizeDoesNotBecomeDragFromFirstPositionSample() {
        let classifier = WindowDragGestureClassifier()
        let bounds = CGRect(x: 100, y: 100, width: 700, height: 500)
        let intent = classifier.pointerIntent(at: CGPoint(x: 104, y: 104), windowBounds: bounds)

        XCTAssertEqual(intent, .resizeEdge)
        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: intent,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 18,
                    maximumPositionDistance: 18,
                    maximumSizeDistance: 0,
                    sampleCount: 1,
                    elapsed: 0.02
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .undecided
        )
        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: intent,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 18,
                    maximumPositionDistance: 18,
                    maximumSizeDistance: 14,
                    sampleCount: 2,
                    elapsed: 0.04
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .resize
        )
    }

    func testBottomRightResizeClassifiesFromSizeChange() {
        let classifier = WindowDragGestureClassifier()
        let bounds = CGRect(x: 100, y: 100, width: 700, height: 500)
        let intent = classifier.pointerIntent(at: CGPoint(x: 796, y: 596), windowBounds: bounds)

        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: intent,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 16,
                    maximumPositionDistance: 0,
                    maximumSizeDistance: 16,
                    sampleCount: 1,
                    elapsed: 0.02
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .resize
        )
    }

    func testEdgeGestureWithPositionEvidenceRemainsResizeAfterGraceSamples() {
        let classifier = WindowDragGestureClassifier()
        let evidence = WindowGestureEvidence(
            maximumPointerDistance: 18,
            maximumPositionDistance: 18,
            maximumSizeDistance: 0,
            sampleCount: 2,
            elapsed: 0.09
        )

        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: .resizeEdge,
                evidence: evidence,
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .resize
        )
    }

    func testTitlebarDragStaysDragThroughTransientSizeChange() {
        let classifier = WindowDragGestureClassifier()
        let drag = classifier.classify(
            current: .undecided,
            pointerIntent: .regular,
            evidence: WindowGestureEvidence(
                maximumPointerDistance: 18,
                maximumPositionDistance: 18,
                maximumSizeDistance: 0,
                sampleCount: 1,
                elapsed: 0.02
            ),
            dragThreshold: 10,
            resizeThreshold: 6
        )

        XCTAssertEqual(drag, .drag)
        XCTAssertEqual(
            classifier.classify(
                current: drag,
                pointerIntent: .regular,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 22,
                    maximumPositionDistance: 22,
                    maximumSizeDistance: 20,
                    sampleCount: 2,
                    elapsed: 0.05
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .drag
        )
    }

    func testTextSelectionWithoutWindowMovementNeverClassifiesAsDrag() {
        let classifier = WindowDragGestureClassifier()

        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: .regular,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 80,
                    maximumPositionDistance: 0,
                    maximumSizeDistance: 0,
                    sampleCount: 8,
                    elapsed: 0.4
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .undecided
        )
    }

    func testResizeEdgePointerMotionAloneNeverClassifiesAsDrag() {
        let classifier = WindowDragGestureClassifier()

        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: .resizeEdge,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 40,
                    maximumPositionDistance: 0,
                    maximumSizeDistance: 0,
                    sampleCount: 4,
                    elapsed: 0.2
                ),
                dragThreshold: 10,
                resizeThreshold: 6
            ),
            .undecided
        )
    }

    func testMouseUpFrameMovementConfirmsFastDrag() {
        let classifier = WindowDragGestureClassifier()

        XCTAssertEqual(
            classifier.classify(
                current: .undecided,
                pointerIntent: .regular,
                evidence: WindowGestureEvidence(
                    maximumPointerDistance: 18,
                    maximumPositionDistance: 18,
                    maximumSizeDistance: 0,
                    sampleCount: 1,
                    elapsed: 0.02
                ),
                dragThreshold: 10,
                resizeThreshold: 6,
                forceDecision: true
            ),
            .drag
        )
    }

    func testWindowDragResizePolicyKeepsActiveDragAliveThroughTransientSizeChanges() {
        let policy = WindowDragResizePolicy()
        let resizeLikeChange = FrameChange(positionDistance: 8, sizeDistance: 12)

        XCTAssertTrue(
            resizeLikeChange.isLikelyResize(resizeThreshold: 6)
        )
        XCTAssertFalse(
            policy.shouldCancelDrag(frameChange: resizeLikeChange, isDragging: true, resizeThreshold: 6)
        )
    }

    func testWindowDragResizePolicyCancelsResizeBeforeDragStarts() {
        let policy = WindowDragResizePolicy()
        let resizeLikeChange = FrameChange(positionDistance: 8, sizeDistance: 12)

        XCTAssertTrue(
            policy.shouldCancelDrag(frameChange: resizeLikeChange, isDragging: false, resizeThreshold: 6)
        )
    }

    func testWindowDragGestureTracksLatestEventLocationForDrop() {
        var gesture = WindowDragGesture(
            window: managedWindow(cgWindowID: 30, observedOrder: 1),
            initialEventLocation: CGPoint(x: 100, y: 120),
            lastEventLocation: CGPoint(x: 100, y: 120),
            initialFrame: CGRect(x: 80, y: 80, width: 600, height: 400),
            lastFrame: CGRect(x: 80, y: 80, width: 600, height: 400)
        )

        gesture.lastEventLocation = CGPoint(x: 420, y: 140)

        XCTAssertEqual(gesture.lastEventLocation, CGPoint(x: 420, y: 140))
    }

    func testWindowInteractionClassifierNormalizesMoveResizeAndZoneDrops() {
        let classifier = WindowInteractionClassifier()

        XCTAssertNil(
            classifier.action(
                for: .undecided,
                zoneDropIsActive: true,
                dropIntent: .preserve
            )
        )
        XCTAssertEqual(
            classifier.action(
                for: .resize,
                zoneDropIsActive: true,
                dropIntent: .zoneFit(.left)
            ),
            .resize
        )
        XCTAssertEqual(
            classifier.action(
                for: .drag,
                zoneDropIsActive: false,
                dropIntent: .zoneFit(.left)
            ),
            .move
        )
        XCTAssertEqual(
            classifier.action(
                for: .drag,
                zoneDropIsActive: true,
                dropIntent: .zoneFit(.left)
            ),
            .snap(.left)
        )
        XCTAssertEqual(
            classifier.action(
                for: .drag,
                zoneDropIsActive: true,
                dropIntent: .custom(.right)
            ),
            .customPosition(.right)
        )
    }

    func testWindowInteractionJournalIsBoundedAndPrivacySafe() {
        var journal = WindowInteractionJournal(limit: 3)
        let windowID = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 100)

        journal.record(kind: .observing, phase: .began, windowID: windowID)
        journal.record(kind: .move, phase: .classified, windowID: windowID)
        journal.record(kind: .snap(.left), phase: .preview, windowID: windowID)
        journal.record(kind: .snap(.left), phase: .completed, windowID: windowID)

        XCTAssertEqual(journal.events.count, 3)
        XCTAssertEqual(journal.events.first?.sequence, 2)
        XCTAssertEqual(journal.events.last?.kind, .snap(.left))
        XCTAssertTrue(journal.diagnosticLines.allSatisfy { !$0.contains("title=") })
        XCTAssertTrue(journal.diagnosticLines.last?.contains("action=snap:left") == true)
    }

    func testPointerScreenSelectionUsesDisplayContainingMouse() {
        let primary = ScreenFrameCandidate(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 876)
        )
        let external = ScreenFrameCandidate(
            frame: CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: -176, width: 1920, height: 1056)
        )

        XCTAssertEqual(
            PointerScreenSelectionPolicy().visibleFrame(
                containing: CGPoint(x: 2000, y: 400),
                candidates: [primary, external],
                fallback: primary.visibleFrame
            ),
            external.visibleFrame
        )
        XCTAssertEqual(
            PointerScreenSelectionPolicy().visibleFrame(
                containing: CGPoint(x: -500, y: 400),
                candidates: [primary, external],
                fallback: primary.visibleFrame
            ),
            primary.visibleFrame
        )
    }

    func testFloatingHUDPlacementAnchorsVisibleSurfaceAtBottomCorners() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let panelSize = CGSize(width: 468, height: 106)
        let policy = FloatingHUDPlacementPolicy()

        XCTAssertEqual(
            policy.frame(
                visibleFrame: visibleFrame,
                panelSize: panelSize,
                effectOutset: 24,
                surfaceInset: 20,
                corner: .bottomLeading
            ),
            CGRect(x: 96, y: 46, width: 468, height: 106)
        )
        XCTAssertEqual(
            policy.frame(
                visibleFrame: visibleFrame,
                panelSize: panelSize,
                effectOutset: 24,
                surfaceInset: 20,
                corner: .bottomTrailing
            ),
            CGRect(x: 836, y: 46, width: 468, height: 106)
        )
    }

    func testDragZoneActivationModesAreExplicit() {
        XCTAssertTrue(DragZoneActivationMode.always.isActive(shiftKeyPressed: false))
        XCTAssertTrue(DragZoneActivationMode.always.isActive(shiftKeyPressed: true))
        XCTAssertFalse(DragZoneActivationMode.shiftKey.isActive(shiftKeyPressed: false))
        XCTAssertTrue(DragZoneActivationMode.shiftKey.isActive(shiftKeyPressed: true))
        XCTAssertFalse(DragZoneActivationMode.off.isActive(shiftKeyPressed: true))
    }




}
