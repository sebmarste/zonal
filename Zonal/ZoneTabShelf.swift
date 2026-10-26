import AppKit

// Quartz coordinates: the visible shelf and native window are separated by a real gap.
struct ZoneTabShelfGeometry {
    static let effectOutset: CGFloat = 12
    let windowFrame: CGRect
    let stripFrame: CGRect
    let panelFrame: CGRect

    var localSurfaceFrame: CGRect {
        stripFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
    }

    init(zoneFrame: CGRect, edge: ZoneTabEdge) {
        let extent = max(0, edge.isVertical ? zoneFrame.width : zoneFrame.height)
        let preferredThickness: CGFloat = (edge.isVertical ? 136 : 24) + 2 * ZoneTabMetrics.minimumPadding
        let scale = min(1, max(0, extent - 1) / (preferredThickness + 4))
        let thickness = preferredThickness * scale
        let gap = 4 * scale
        let reserved = min(max(0, extent - 1), thickness + gap)
        var window = zoneFrame
        var strip = zoneFrame
        switch edge {
        case .top:
            window.origin.y += reserved
            window.size.height = max(0, extent - reserved)
            strip.size.height = thickness
        case .bottom:
            window.size.height = max(0, extent - reserved)
            strip.origin.y = zoneFrame.maxY - thickness
            strip.size.height = thickness
        case .left:
            window.origin.x += reserved
            window.size.width = max(0, extent - reserved)
            strip.size.width = thickness
        case .right:
            window.size.width = max(0, extent - reserved)
            strip.origin.x = zoneFrame.maxX - thickness
            strip.size.width = thickness
        }
        windowFrame = window
        stripFrame = strip
        // Tiny zones may overflow with transparent margins; never clip the shape's shadow.
        panelFrame = strip.insetBy(dx: -Self.effectOutset, dy: -Self.effectOutset)
    }
}
