import SwiftUI

struct ZoneIconView: View {
    var frame: NormalizedFrame
    var fill: Color = .accentColor
    var outline: Color = .secondary.opacity(0.62)
    var lineWidth: CGFloat = 1.4

    var body: some View {
        GeometryReader { proxy in
            let displayRect = fittedDisplayRect(in: proxy.size)
            let zoneRect = zoneRect(in: displayRect)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: displayCornerRadius(for: displayRect), style: .continuous)
                    .stroke(outline, lineWidth: lineWidth)
                    .frame(width: displayRect.width, height: displayRect.height)
                    .position(x: displayRect.midX, y: displayRect.midY)

                RoundedRectangle(cornerRadius: zoneCornerRadius(for: zoneRect), style: .continuous)
                    .fill(fill)
                    .frame(width: zoneRect.width, height: zoneRect.height)
                    .position(x: zoneRect.midX, y: zoneRect.midY)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func fittedDisplayRect(in size: CGSize) -> CGRect {
        let aspect: CGFloat = 16 / 10
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func zoneRect(in displayRect: CGRect) -> CGRect {
        let safeFrame = frame.clamped()
        let minX = displayRect.minX + displayRect.width * safeFrame.x
        let minY = displayRect.minY + displayRect.height * safeFrame.y
        let width = max(lineWidth * 1.8, displayRect.width * safeFrame.width)
        let height = max(lineWidth * 1.8, displayRect.height * safeFrame.height)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func displayCornerRadius(for rect: CGRect) -> CGFloat {
        max(3, min(rect.width, rect.height) * 0.16)
    }

    private func zoneCornerRadius(for rect: CGRect) -> CGFloat {
        max(1.5, min(rect.width, rect.height) * 0.14)
    }
}
