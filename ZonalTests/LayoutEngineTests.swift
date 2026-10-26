import CoreGraphics
import XCTest
@testable import Zonal

final class LayoutEngineTests: XCTestCase {
    func testZoneSpacingHasEqualInnerAndOuterGapsAndReflowsAllZones() {
        let baseline = DisplayProfile(id: "spacing", name: "Spacing", mainZoneID: .left, zones: [
            Zone(id: .left, name: "Left", frame: .init(x: 0, y: 0, width: 0.5, height: 1)),
            Zone(id: .right, name: "Right", frame: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        ])
        var profile = baseline
        profile.zoneSpacing = 16
        let display = CGRect(x: -1200, y: 24, width: 1200, height: 800)
        let engine = LayoutEngine()
        let frames = engine.zoneFrames(for: profile, in: display)
        XCTAssertEqual(frames[0].frame.minX - display.minX, 16)
        XCTAssertEqual(display.maxX - frames[1].frame.maxX, 16)
        XCTAssertEqual(frames[1].frame.minX - frames[0].frame.maxX, 16)
        for frame in frames {
            XCTAssertEqual(frame.frame.minY - display.minY, 16)
            XCTAssertEqual(display.maxY - frame.frame.maxY, 16)
        }
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: baseline, to: profile), [.left, .right])
        let byRole = engine.zoneFrames(for: profile, displayFramesByRole: [.workspace: display], fallbackDisplayFrame: nil)
        XCTAssertEqual(byRole.map(\.frame), frames.map(\.frame))
        profile.zones[0].frame.height = 0.5
        profile.zones[1].frame = .init(x: 0, y: 0.5, width: 1, height: 0.5)
        let stacked = engine.zoneFrames(for: profile, in: display)
        XCTAssertEqual(stacked[1].frame.minY - stacked[0].frame.maxY, 16)
    }

    func testSpacingPreservesOverlapsAndKeepsTinyZonesNonempty() {
        var profile = overlappingProfile
        profile.zoneSpacing = 16
        let frames = LayoutEngine().zoneFrames(for: profile, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(frames.contains { first in frames.contains { $0.zoneID != first.zoneID && $0.frame.intersects(first.frame) } })
        for frame in LayoutEngine().zoneFrames(for: profile, in: CGRect(x: 0, y: 0, width: 20, height: 20)) {
            XCTAssertGreaterThanOrEqual(frame.frame.width, 1)
            XCTAssertGreaterThanOrEqual(frame.frame.height, 1)
        }
    }

    func testProfileSpacingDefaultsAndRoundTrips() throws {
        let encoder = JSONEncoder()
        var profile = sideBySideProfile
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(profile)) as? [String: Any])
        json.removeValue(forKey: "zoneSpacing")
        XCTAssertEqual(try JSONDecoder().decode(DisplayProfile.self, from: JSONSerialization.data(withJSONObject: json)).zoneSpacing, 0)
        profile.zoneSpacing = 12
        XCTAssertEqual(try JSONDecoder().decode(DisplayProfile.self, from: encoder.encode(profile)), profile)
        var configuration = ZonalConfiguration.default
        configuration.profiles[0].zoneSpacing = -1
        XCTAssertThrowsError(try PersistenceValidation.configuration(configuration))
    }

    func testSideBySideProfileUsesExpectedZoneFrames() {
        let frames = LayoutEngine().zoneFrames(
            for: sideBySideProfile,
            in: CGRect(x: 0, y: 0, width: 5120, height: 1440)
        )

        let left = frame(zone: .left, in: frames)
        let center = frame(zone: .center, in: frames)
        let right = frame(zone: .right, in: frames)

        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(left.width, 1126)
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.width, 2868)
        XCTAssertEqual(right.minX, center.maxX)
        XCTAssertEqual(right.width, 1126)
        XCTAssertEqual(right.maxX, 5120)
        XCTAssertFalse(left.intersects(center))
        XCTAssertFalse(center.intersects(right))
    }

    func testZoneFramesSnapHiddenSliderFractionsToDisplayedPercentages() {
        let profile = DisplayProfile(
            id: "test-hidden-fractions",
            name: "Test Hidden Fractions",
            mainZoneID: .center,
            zones: [
                Zone(id: .left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.2224244081182108, height: 1)),
                Zone(id: .center, name: "Center", frame: NormalizedFrame(x: 0.22021355896157924, y: 0, width: 0.5620920590676598, height: 1)),
                Zone(id: .right, name: "Right", frame: NormalizedFrame(x: 0.7785656799623116, y: 0, width: 0.22022577061658793, height: 1))
            ]
        )

        let frames = LayoutEngine().zoneFrames(
            for: profile,
            in: CGRect(x: 0, y: 0, width: 5120, height: 1440)
        )

        let left = frame(zone: .left, in: frames)
        let center = frame(zone: .center, in: frames)
        let right = frame(zone: .right, in: frames)

        XCTAssertEqual(left.width, 1126)
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.width, 2868)
        XCTAssertEqual(right.minX, center.maxX)
        XCTAssertEqual(right.maxX, 5120)
        XCTAssertFalse(left.intersects(center))
        XCTAssertFalse(center.intersects(right))
    }

    func testOverlappingProfileMapsAllZonesToDisplayFrame() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = LayoutEngine().zoneFrames(for: overlappingProfile, in: display)

        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.frame == display })
    }

    func testSideBySideZonesBecomeThreeSwitcherColumns() {
        let engine = LayoutEngine()
        let zoneFrames = engine.zoneFrames(
            for: sideBySideProfile,
            in: CGRect(x: 0, y: 0, width: 5120, height: 1440)
        )

        XCTAssertEqual(
            engine.switcherZoneColumns(
                for: zoneFrames,
                profileOrder: sideBySideProfile.zones.map(\.id)
            ),
            [[.left], [.center], [.right]]
        )
    }

    func testOverlappingZonesBecomeOneSwitcherColumn() {
        let engine = LayoutEngine()
        let zoneFrames = engine.zoneFrames(
            for: overlappingProfile,
            in: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )

        XCTAssertEqual(
            engine.switcherZoneColumns(
                for: zoneFrames,
                profileOrder: overlappingProfile.zones.map(\.id)
            ),
            [overlappingProfile.zones.map(\.id)]
        )
    }

    func testVisualZoneOrderFollowsScreenPosition() {
        let engine = LayoutEngine()
        let profile = DisplayProfile(
            id: "test-reordered",
            name: "Test Reordered",
            mainZoneID: .center,
            zones: [
                Zone(id: .right, name: "Right", frame: NormalizedFrame(x: 0.78, y: 0, width: 0.22, height: 1)),
                Zone(id: .left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.22, height: 1)),
                Zone(id: .center, name: "Center", frame: NormalizedFrame(x: 0.22, y: 0, width: 0.56, height: 1))
            ]
        )
        let zoneFrames = engine.zoneFrames(
            for: profile,
            in: CGRect(x: 0, y: 0, width: 5120, height: 1440)
        )

        XCTAssertEqual(
            engine.switcherZoneColumns(
                for: zoneFrames,
                profileOrder: profile.zones.map(\.id)
            ),
            [[.left], [.center], [.right]]
        )
    }

    func testVerticalVisualZoneOrderFollowsTopToBottomPosition() {
        let engine = LayoutEngine()
        let top = ZoneID(rawValue: "top")
        let bottom = ZoneID(rawValue: "bottom")
        let profile = DisplayProfile(
            id: "test-vertical-reordered",
            name: "Test Vertical Reordered",
            mainZoneID: top,
            zones: [
                Zone(id: bottom, name: "Bottom", frame: NormalizedFrame(x: 0, y: 0, width: 1, height: 0.5)),
                Zone(id: top, name: "Top", frame: NormalizedFrame(x: 0, y: 0.5, width: 1, height: 0.5))
            ]
        )
        let zoneFrames = engine.zoneFrames(
            for: profile,
            in: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )

        XCTAssertEqual(
            engine.switcherZoneColumns(
                for: zoneFrames,
                profileOrder: profile.zones.map(\.id)
            ),
            [[top, bottom]]
        )
    }

    func testSwitcherColumnsCombineHorizontalAndOverlappingZones() {
        let engine = LayoutEngine()
        let left = ZoneID(rawValue: "zone-2")
        let main = ZoneID.main
        let right = ZoneID(rawValue: "zone-3")
        let overlay = ZoneID(rawValue: "zone-4")
        let profile = DisplayProfile(
            id: "combined",
            name: "Combined",
            mainZoneID: main,
            zones: [
                Zone(id: left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.27, height: 1)),
                Zone(id: main, name: "Main", frame: NormalizedFrame(x: 0.27, y: 0, width: 0.46, height: 1)),
                Zone(id: right, name: "Right", frame: NormalizedFrame(x: 0.73, y: 0, width: 0.27, height: 1)),
                Zone(id: overlay, name: "Zone 4", frame: .full)
            ]
        )
        let frames = engine.zoneFrames(
            for: profile,
            in: CGRect(x: 0, y: 0, width: 5120, height: 1440)
        )
        let columns = engine.switcherZoneColumns(
            for: frames,
            profileOrder: profile.zones.map(\.id)
        )

        XCTAssertEqual(columns, [[left], [main, overlay], [right]])
        XCTAssertEqual(engine.neighboringZoneID(from: main, direction: .left, columns: columns), left)
        XCTAssertEqual(engine.neighboringZoneID(from: main, direction: .down, columns: columns), overlay)
        XCTAssertEqual(engine.neighboringZoneID(from: overlay, direction: .up, columns: columns), main)
        XCTAssertEqual(engine.neighboringZoneID(from: overlay, direction: .right, columns: columns), right)
        XCTAssertNil(engine.neighboringZoneID(from: left, direction: .left, columns: columns))
        XCTAssertNil(engine.neighboringZoneID(from: main, direction: .up, columns: columns))
    }

    func testNormalizedFrameCanRoundTripRelativeToZone() {
        let zone = CGRect(x: 100, y: 50, width: 800, height: 600)
        let window = CGRect(x: 300, y: 200, width: 400, height: 300)

        let normalized = NormalizedFrame.relativeFrame(for: window, in: zone)

        XCTAssertEqual(normalized.rect(in: zone), window)
    }

    func testNormalizedFrameRoundTripsWithNegativeAndVerticalDisplayOrigin() {
        let display = CGRect(x: -1512, y: -982, width: 1512, height: 982)
        let window = CGRect(x: -1320, y: -840, width: 900, height: 620)

        let normalized = NormalizedFrame.relativeFrame(for: window, in: display)

        XCTAssertEqual(normalized.rect(in: display), window)
    }

    func testZonesResolveAgainstTheirAssignedDisplays() {
        let builtIn = DisplayRoleID(rawValue: "built-in")
        let ultrawide = DisplayRoleID(rawValue: "ultrawide")
        let profile = DisplayProfile(
            id: "both",
            name: "Both",
            mainZoneID: .center,
            zones: [
                Zone(id: .left, name: "Laptop", frame: .full, displayRoleID: builtIn),
                Zone(
                    id: .center,
                    name: "Wide",
                    frame: NormalizedFrame(x: 0.2, y: 0, width: 0.6, height: 1),
                    displayRoleID: ultrawide
                )
            ]
        )

        let frames = LayoutEngine().zoneFrames(
            for: profile,
            displayFramesByRole: [
                builtIn: CGRect(x: 0, y: 0, width: 1512, height: 982),
                ultrawide: CGRect(x: 1512, y: 0, width: 5120, height: 1440)
            ],
            fallbackDisplayFrame: nil
        )

        XCTAssertEqual(frame(zone: .left, in: frames), CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(frame(zone: .center, in: frames), CGRect(x: 2536, y: 0, width: 3072, height: 1440))
    }

    func testHotZoneTargetsAreGenerousAndNearTopWithTopBreathingRoom() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = LayoutEngine().zoneFrames(for: overlappingProfile, in: display)
        let targets = HotZoneResolver().dropTargets(for: frames)

        XCTAssertEqual(targets.count, 3)
        XCTAssertTrue(targets.allSatisfy { $0.frame.width == 320 })
        XCTAssertTrue(targets.allSatisfy { $0.frame.height == 84 })
        XCTAssertTrue(targets.allSatisfy { $0.frame.width < display.width * 0.25 })
        XCTAssertTrue(targets.allSatisfy { $0.frame.height < display.height * 0.1 })
        XCTAssertTrue(targets.allSatisfy { $0.frame.minY >= display.minY + 100 })
        XCTAssertTrue(targets.allSatisfy { $0.frame.maxY <= display.maxY - 100 })
    }

    func testOverlappingHotZoneTargetsArePackedSideBySide() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = LayoutEngine().zoneFrames(for: overlappingProfile, in: display)
        let targets = HotZoneResolver().dropTargets(for: frames)

        XCTAssertLessThan(frame(zone: .left, in: targets).maxX, frame(zone: .center, in: targets).minX)
        XCTAssertLessThan(frame(zone: .center, in: targets).maxX, frame(zone: .right, in: targets).minX)
        XCTAssertEqual(frame(zone: .left, in: targets).midY, frame(zone: .center, in: targets).midY)
        XCTAssertEqual(frame(zone: .center, in: targets).midY, frame(zone: .right, in: targets).midY)
    }

    func testHotZoneTargetsStayInActualZonesWhenOnlyParentZoneOverlaps() {
        let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let side = ZoneID(rawValue: "side")
        let frames = LayoutEngine().zoneFrames(
            for: DisplayProfile(
                id: "test-parent-overlap",
                name: "Test Parent Overlap",
                mainZoneID: .main,
                zones: [
                    Zone(id: .main, name: "Main", frame: .full),
                    Zone(id: .left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.25, height: 1)),
                    Zone(id: side, name: "Side", frame: NormalizedFrame(x: 0.75, y: 0, width: 0.25, height: 1))
                ]
            ),
            in: display
        )
        let targets = HotZoneResolver().dropTargets(for: frames)

        XCTAssertTrue(frame(zone: .left, in: frames).contains(frame(zone: .left, in: targets).center))
        XCTAssertTrue(frame(zone: side, in: frames).contains(frame(zone: side, in: targets).center))
        XCTAssertGreaterThan(frame(zone: .main, in: targets).minX, frame(zone: .left, in: frames).maxX)
        XCTAssertLessThan(frame(zone: .main, in: targets).maxX, frame(zone: side, in: frames).minX)
    }

    func testHotZoneHitTestingUsesPackedTargets() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frames = LayoutEngine().zoneFrames(for: overlappingProfile, in: display)
        let resolver = HotZoneResolver()
        let targets = resolver.dropTargets(for: frames)

        XCTAssertEqual(resolver.targetZone(for: frame(zone: .left, in: targets).center, zones: frames), .left)
        XCTAssertEqual(resolver.targetZone(for: frame(zone: .center, in: targets).center, zones: frames), .center)
        XCTAssertEqual(resolver.targetZone(for: frame(zone: .right, in: targets).center, zones: frames), .right)
        XCTAssertNil(resolver.targetZone(for: CGPoint(x: display.midX, y: display.maxY - 20), zones: frames))
    }

    func testZoneDropIntentSeparatesMaximizeTargetFromCustomZoneBoundary() {
        let zones = [
            ZoneFrame(zoneID: .left, frame: CGRect(x: 0, y: 0, width: 400, height: 800)),
            ZoneFrame(zoneID: .right, frame: CGRect(x: 400, y: 0, width: 400, height: 800))
        ]
        let resolver = HotZoneResolver()
        let leftTarget = resolver.dropTargets(for: zones)
            .first { $0.zoneID == .left }?.frame ?? .null

        XCTAssertEqual(
            resolver.dropIntent(for: leftTarget.center, zones: zones),
            .zoneFit(.left)
        )
        XCTAssertEqual(
            resolver.dropIntent(for: CGPoint(x: 100, y: 700), zones: zones),
            .custom(.left)
        )
        XCTAssertEqual(
            resolver.dropIntent(for: CGPoint(x: 700, y: 700), zones: zones),
            .custom(.right)
        )
        XCTAssertEqual(
            resolver.dropIntent(for: CGPoint(x: 900, y: 700), zones: zones),
            .preserve
        )
    }

    func testZoneDropIntentRequiresTargetToDisambiguateOverlappingZones() {
        let zones = [
            ZoneFrame(zoneID: .main, frame: CGRect(x: 0, y: 0, width: 800, height: 800)),
            ZoneFrame(zoneID: .left, frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        ]
        let resolver = HotZoneResolver()
        let leftTarget = resolver.dropTargets(for: zones)
            .first { $0.zoneID == .left }?.frame ?? .null

        XCTAssertEqual(
            resolver.dropIntent(for: CGPoint(x: 100, y: 700), zones: zones),
            .preserve
        )
        XCTAssertEqual(
            resolver.dropIntent(for: leftTarget.center, zones: zones),
            .zoneFit(.left)
        )
    }

    private func frame(zone: ZoneID, in frames: [ZoneFrame]) -> CGRect {
        frames.first { $0.zoneID == zone }?.frame ?? .null
    }

    private var sideBySideProfile: DisplayProfile {
        DisplayProfile(
            id: "test-side-by-side",
            name: "Test Side By Side",
            mainZoneID: .center,
            zones: [
                Zone(id: .left, name: "Left", frame: NormalizedFrame(x: 0, y: 0, width: 0.22, height: 1)),
                Zone(id: .center, name: "Center", frame: NormalizedFrame(x: 0.22, y: 0, width: 0.56, height: 1)),
                Zone(id: .right, name: "Right", frame: NormalizedFrame(x: 0.78, y: 0, width: 0.22, height: 1))
            ]
        )
    }

    private var overlappingProfile: DisplayProfile {
        DisplayProfile(
            id: "test-overlap",
            name: "Test Overlap",
            mainZoneID: .center,
            zones: [
                Zone(id: .left, name: "Left", frame: .full),
                Zone(id: .center, name: "Center", frame: .full),
                Zone(id: .right, name: "Right", frame: .full)
            ]
        )
    }
}
