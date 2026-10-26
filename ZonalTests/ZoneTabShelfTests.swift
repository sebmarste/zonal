import AppKit
import XCTest
@testable import Zonal

final class ZoneTabShelfTests: XCTestCase {
    @MainActor
    func testTabPanelKeepsShadowMarginAboveMenuBarBoundary() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let panel = ZoneTabController.makePanel()
        defer { panel.orderOut(nil) }
        for height: CGFloat in [32, 500] {
            let surface = CGRect(x: screen.visibleFrame.minX + 100,
                                 y: screen.visibleFrame.maxY - height, width: 500, height: height)
            let footprint = surface.insetBy(dx: -12, dy: -12)
            panel.setFrame(footprint, display: true)
            panel.orderFrontRegardless()
            XCTAssertEqual(panel.frame, footprint, "AppKit must not shift the visible tabs below the zone edge")
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(panel.backgroundColor, .clear)
            XCTAssertFalse(panel.hasShadow)
        }
    }

    func testShelfUsesCompactSpacingWithoutClippingItsShadowOnEveryEdge() {
        let zone = CGRect(x: -600, y: 24, width: 1000, height: 800)
        for edge in ZoneTabEdge.allCases {
            let geometry = ZoneTabShelfGeometry(zoneFrame: zone, edge: edge)
            let strip = geometry.stripFrame
            let window = geometry.windowFrame
            XCTAssertEqual(edge.isVertical ? strip.width : strip.height, edge.isVertical ? 144 : 32)
            XCTAssertTrue(zone.contains(window))
            XCTAssertTrue(zone.contains(strip))
            XCTAssertEqual(geometry.panelFrame.insetBy(dx: 12, dy: 12), strip)
            XCTAssertEqual(geometry.localSurfaceFrame,
                           CGRect(x: 12, y: 12, width: strip.width, height: strip.height))
            if edge.isVertical {
                XCTAssertEqual(strip.minY, zone.minY)
                XCTAssertEqual(strip.maxY, zone.maxY)
                XCTAssertEqual(window.width, zone.width - 148)
                XCTAssertEqual(window.height, zone.height)
            } else {
                XCTAssertEqual(strip.minX, zone.minX)
                XCTAssertEqual(strip.maxX, zone.maxX)
                XCTAssertEqual(window.height, zone.height - 36)
                XCTAssertEqual(window.width, zone.width)
            }
            switch edge {
            case .top:
                XCTAssertEqual(strip.minY, zone.minY)
                XCTAssertEqual(window.minY - strip.maxY, 4)
            case .bottom:
                XCTAssertEqual(zone.maxY - strip.maxY, 0)
                XCTAssertEqual(strip.minY - window.maxY, 4)
            case .left:
                XCTAssertEqual(strip.minX, zone.minX)
                XCTAssertEqual(window.minX - strip.maxX, 4)
            case .right:
                XCTAssertEqual(zone.maxX - strip.maxX, 0)
                XCTAssertEqual(strip.minX - window.maxX, 4)
            }
        }
    }

    func testTinyZonesKeepPositiveWindowSpaceAndUnclippedEffectOutset() {
        for size in [CGSize(width: 20, height: 20), CGSize(width: 1, height: 1),
                     CGSize(width: 0.5, height: 0.5), .zero,
                     CGSize(width: 12, height: 400), CGSize(width: 500, height: 12)] {
            let zone = CGRect(origin: CGPoint(x: -40, y: 120), size: size)
            for edge in ZoneTabEdge.allCases {
                let geometry = ZoneTabShelfGeometry(zoneFrame: zone, edge: edge)
                XCTAssertGreaterThanOrEqual(geometry.windowFrame.width, min(1, size.width))
                XCTAssertGreaterThanOrEqual(geometry.windowFrame.height, min(1, size.height))
                for frame in [geometry.windowFrame, geometry.stripFrame, geometry.panelFrame] {
                    XCTAssertTrue(frame.minX.isFinite && frame.minY.isFinite)
                    XCTAssertGreaterThanOrEqual(frame.width, 0)
                    XCTAssertGreaterThanOrEqual(frame.height, 0)
                }
                XCTAssertEqual(geometry.stripFrame.minX - geometry.panelFrame.minX, 12, accuracy: 0.0001)
                XCTAssertEqual(geometry.stripFrame.minY - geometry.panelFrame.minY, 12, accuracy: 0.0001)
                XCTAssertEqual(geometry.panelFrame.maxX - geometry.stripFrame.maxX, 12, accuracy: 0.0001)
                XCTAssertEqual(geometry.panelFrame.maxY - geometry.stripFrame.maxY, 12, accuracy: 0.0001)
            }
        }
    }
}
