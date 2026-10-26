import XCTest
@testable import Zonal

final class ZoneTabFrameTests: XCTestCase {
    func testTabPaddingUsesBorderOrMinimumWithoutDoubleCountingOnEveryEdge() {
        let zone = CGRect(x: -600, y: 24, width: 1000, height: 800)
        for border in [CGFloat(0), 2, 4, 7, 24] {
            for edge in ZoneTabEdge.allCases {
                let geometry = ZoneTabFrameGeometry(zoneFrame: zone, edge: edge, borderWidth: border)
                let layout = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: border)
                let padding = max(4, border)
                let content = geometry.stripFrame.insetBy(dx: padding, dy: padding)
                XCTAssertEqual(layout.tabPadding, padding)
                XCTAssertEqual(geometry.panelFrame, zone.insetBy(dx: -12, dy: -12))
                XCTAssertEqual(geometry.surfaceFrame, zone)
                XCTAssertTrue(zone.contains(geometry.windowFrame))
                XCTAssertTrue(zone.contains(geometry.stripFrame))
                XCTAssertFalse(geometry.windowFrame.intersects(geometry.stripFrame))
                XCTAssertEqual(edge.isVertical ? content.width : content.height, edge.isVertical ? 136 : 24)
                if edge.isVertical {
                    XCTAssertEqual(content.minY - zone.minY, padding)
                    XCTAssertEqual(zone.maxY - content.maxY, padding)
                    XCTAssertEqual(geometry.windowFrame.height, zone.height - 2 * border)
                } else {
                    XCTAssertEqual(content.minX - zone.minX, padding)
                    XCTAssertEqual(zone.maxX - content.maxX, padding)
                    XCTAssertEqual(geometry.windowFrame.width, zone.width - 2 * border)
                }
                switch edge {
                case .top:
                    XCTAssertEqual(content.minY - zone.minY, padding)
                    XCTAssertEqual(geometry.windowFrame.minY - content.maxY, padding)
                    XCTAssertEqual(zone.maxY - geometry.windowFrame.maxY, border)
                case .bottom:
                    XCTAssertEqual(zone.maxY - content.maxY, padding)
                    XCTAssertEqual(content.minY - geometry.windowFrame.maxY, padding)
                    XCTAssertEqual(geometry.windowFrame.minY - zone.minY, border)
                case .left:
                    XCTAssertEqual(content.minX - zone.minX, padding)
                    XCTAssertEqual(geometry.windowFrame.minX - content.maxX, padding)
                    XCTAssertEqual(zone.maxX - geometry.windowFrame.maxX, border)
                case .right:
                    XCTAssertEqual(zone.maxX - content.maxX, padding)
                    XCTAssertEqual(content.minX - geometry.windowFrame.maxX, padding)
                    XCTAssertEqual(geometry.windowFrame.minX - zone.minX, border)
                }
            }
        }
    }

    func testTinyZonesKeepPositiveContentAndFullShadowMargin() {
        for size in [CGSize(width: 0, height: 0), CGSize(width: 1, height: 1),
                     CGSize(width: 20, height: 60), CGSize(width: 200, height: 20)] {
            for edge in ZoneTabEdge.allCases {
                let geometry = ZoneTabFrameGeometry(zoneFrame: CGRect(origin: .zero, size: size), edge: edge)
                XCTAssertGreaterThanOrEqual(geometry.windowFrame.width, 1)
                XCTAssertGreaterThanOrEqual(geometry.windowFrame.height, 1)
                XCTAssertGreaterThanOrEqual(geometry.stripFrame.width, 0)
                XCTAssertGreaterThanOrEqual(geometry.stripFrame.height, 0)
                XCTAssertEqual(geometry.localSurfaceFrame.minX, ZoneTabFrameGeometry.effectOutset)
                XCTAssertEqual(geometry.localSurfaceFrame.minY, ZoneTabFrameGeometry.effectOutset)
                XCTAssertEqual(geometry.panelFrame.maxX - geometry.surfaceFrame.maxX,
                               ZoneTabFrameGeometry.effectOutset)
                XCTAssertEqual(geometry.panelFrame.maxY - geometry.surfaceFrame.maxY,
                               ZoneTabFrameGeometry.effectOutset)
            }
        }
    }
}
