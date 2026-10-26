import SwiftUI

// Quartz coordinates throughout; the panel includes the tray's transparent shadow margin.
struct ZoneTabFrameGeometry: Equatable {
    static let effectOutset: CGFloat = 12

    var windowFrame: CGRect
    var stripFrame: CGRect
    var panelFrame: CGRect
    var surfaceFrame: CGRect
    let tabPadding: CGFloat

    var localSurfaceFrame: CGRect {
        surfaceFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
    }

    init(zoneFrame: CGRect, edge: ZoneTabEdge, borderWidth: CGFloat = ZoneTabMetrics.defaultBorderWidth) {
        let borderWidth = ZoneTabMetrics.clampedBorderWidth(borderWidth)
        tabPadding = max(ZoneTabMetrics.minimumPadding, borderWidth)
        surfaceFrame = CGRect(origin: zoneFrame.origin,
                              size: CGSize(width: max(1, zoneFrame.width), height: max(1, zoneFrame.height)))
        // Shadow space belongs outside the visible frame, not between it and the native window.
        panelFrame = surfaceFrame.insetBy(dx: -Self.effectOutset, dy: -Self.effectOutset)
        let innerFrame = surfaceFrame.insetBy(dx: min(borderWidth, (surfaceFrame.width - 1) / 2),
                                              dy: min(borderWidth, (surfaceFrame.height - 1) / 2))
        let extent = edge.isVertical ? surfaceFrame.width : surfaceFrame.height
        let oppositeBorder = edge.isVertical ? innerFrame.minX - surfaceFrame.minX : innerFrame.minY - surfaceFrame.minY
        let thickness = min((edge.isVertical ? 136 : 24) + 2 * tabPadding, max(0, extent - oppositeBorder - 1))
        windowFrame = innerFrame
        // The tab band includes its entire padding; it does not sit inside another border.
        stripFrame = surfaceFrame
        switch edge {
        case .top:
            stripFrame.size.height = thickness
            windowFrame.origin.y = max(innerFrame.minY, stripFrame.maxY)
            windowFrame.size.height = innerFrame.maxY - windowFrame.minY
        case .bottom:
            stripFrame.origin.y = surfaceFrame.maxY - thickness
            stripFrame.size.height = thickness
            windowFrame.size.height = min(innerFrame.maxY, stripFrame.minY) - innerFrame.minY
        case .left:
            stripFrame.size.width = thickness
            windowFrame.origin.x = max(innerFrame.minX, stripFrame.maxX)
            windowFrame.size.width = innerFrame.maxX - windowFrame.minX
        case .right:
            stripFrame.origin.x = surfaceFrame.maxX - thickness
            stripFrame.size.width = thickness
            windowFrame.size.width = min(innerFrame.maxX, stripFrame.minX) - innerFrame.minX
        }
    }
}

// Both tab backings draw their shadow inside the transparent hosting panel.
struct ZoneTabSurface: View {
    var surfaceFrame: CGRect
    var cornerRadius: CGFloat
    var borderOpacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(borderOpacity), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1)
            .frame(width: surfaceFrame.width, height: surfaceFrame.height)
            .offset(x: surfaceFrame.minX, y: surfaceFrame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}
