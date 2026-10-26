import AppKit
import SwiftUI

struct HotZoneTarget: Identifiable, Equatable {
    var id: ZoneID { zoneID }
    var zoneID: ZoneID
    var name: String
    var zoneFrame: NormalizedFrame
    var previewFrame: CGRect
    var frame: CGRect
    var isMaximizeTargetActive: Bool
    var isMembershipActive: Bool
    var landingFrame: CGRect? = nil
    var preservesCustomSize = false
}

enum ZoneDropIntent: Equatable {
    case zoneFit(ZoneID)
    case custom(ZoneID)
    case preserve

    var zoneID: ZoneID? {
        switch self {
        case .zoneFit(let zoneID), .custom(let zoneID): zoneID
        case .preserve: nil
        }
    }
}

struct HotZoneResolver {
    var topOffset: CGFloat = 100
    var edgePadding: CGFloat = 20
    var targetGap: CGFloat = 12
    var preferredTargetWidth: CGFloat = 320
    var preferredTargetHeight: CGFloat = 84
    var minimumTargetWidth: CGFloat = 72
    var minimumTargetHeight: CGFloat = 52

    func targetZone(for point: CGPoint, zones: [ZoneFrame]) -> ZoneID? {
        dropTargets(for: zones).first { $0.frame.contains(point) }?.zoneID
    }

    func dropIntent(for point: CGPoint, zones: [ZoneFrame]) -> ZoneDropIntent {
        if let targetZone = targetZone(for: point, zones: zones) {
            return .zoneFit(targetZone)
        }
        let containingZones = zones.filter { $0.frame.contains(point) }
        guard containingZones.count == 1, let zoneID = containingZones.first?.zoneID else {
            return .preserve
        }
        return .custom(zoneID)
    }

    func dropTargets(for zones: [ZoneFrame]) -> [ZoneFrame] {
        var targetsByIndex: [Int: CGRect] = [:]
        for index in zones.indices {
            targetsByIndex[index] = targetFrame(in: zones[index].frame)
        }

        for group in overlappingTargetGroups(zones: zones, targetsByIndex: targetsByIndex) where group.count > 1 {
            for (zoneIndex, targetFrame) in packedTargetFrames(for: group.map { zones[$0].frame }).enumerated() {
                targetsByIndex[group[zoneIndex]] = targetFrame
            }
        }

        return zones.indices.compactMap { index in
            guard let frame = targetsByIndex[index] else { return nil }
            return ZoneFrame(zoneID: zones[index].zoneID, frame: frame)
        }
    }

    private func overlappingTargetGroups(zones: [ZoneFrame], targetsByIndex: [Int: CGRect]) -> [[Int]] {
        var visited = Set<Int>()
        var groups: [[Int]] = []

        for index in zones.indices where !visited.contains(index) {
            var group: [Int] = []
            var stack = [index]
            visited.insert(index)

            while let current = stack.popLast() {
                group.append(current)
                for candidate in zones.indices where !visited.contains(candidate) {
                    if zones[current].frame.hasPositiveOverlap(with: zones[candidate].frame),
                       targetsByIndex[current]?.hasPositiveOverlap(with: targetsByIndex[candidate] ?? .null) == true {
                        visited.insert(candidate)
                        stack.append(candidate)
                    }
                }
            }

            groups.append(group.sorted())
        }

        return groups
    }

    private func packedTargetFrames(for zoneFrames: [CGRect]) -> [CGRect] {
        guard let container = sharedContainer(for: zoneFrames) else { return [] }
        let count = CGFloat(zoneFrames.count)
        let gapCount = max(0, count - 1)
        let availableWidth = max(24 * count, container.width - edgePadding * 2)
        let gap = gapCount == 0
            ? 0
            : min(targetGap, max(0, (availableWidth - minimumTargetWidth * count) / gapCount))
        let width = min(preferredTargetWidth, max(24, (availableWidth - gap * gapCount) / count))
        let height = targetHeight(in: container)
        let totalWidth = width * count + gap * gapCount
        let startX = container.midX - totalWidth / 2
        let y = targetMinY(in: container, height: height)

        return zoneFrames.indices.map { index in
            CGRect(
                x: startX + CGFloat(index) * (width + gap),
                y: y,
                width: width,
                height: height
            )
        }
    }

    private func sharedContainer(for zoneFrames: [CGRect]) -> CGRect? {
        guard var intersection = zoneFrames.first else { return nil }
        for frame in zoneFrames.dropFirst() {
            intersection = intersection.intersection(frame)
        }
        if !intersection.isNull, intersection.width > minimumTargetWidth, intersection.height > minimumTargetHeight {
            return intersection
        }
        return zoneFrames.dropFirst().reduce(zoneFrames[0]) { $0.union($1) }
    }

    private func targetFrame(in zoneFrame: CGRect) -> CGRect {
        let width = targetWidth(in: zoneFrame)
        let height = targetHeight(in: zoneFrame)
        return CGRect(
            x: zoneFrame.midX - width / 2,
            y: targetMinY(in: zoneFrame, height: height),
            width: width,
            height: height
        )
    }

    private func targetWidth(in zoneFrame: CGRect) -> CGFloat {
        let availableWidth = max(minimumTargetWidth, zoneFrame.width - edgePadding * 2)
        let proportionalWidth = max(120, zoneFrame.width * 0.36)
        return min(preferredTargetWidth, proportionalWidth, availableWidth)
    }

    private func targetHeight(in zoneFrame: CGRect) -> CGFloat {
        let availableHeight = max(minimumTargetHeight, zoneFrame.height - topOffset - edgePadding)
        return min(preferredTargetHeight, availableHeight)
    }

    private func targetMinY(in zoneFrame: CGRect, height: CGFloat) -> CGFloat {
        let preferredY = zoneFrame.minY + topOffset
        let maximumY = max(zoneFrame.minY + edgePadding, zoneFrame.maxY - height - edgePadding)
        return min(max(zoneFrame.minY + edgePadding, preferredY), maximumY)
    }
}

@MainActor
final class HotZoneOverlayController {
    private let resolver = HotZoneResolver()
    private var window: NSWindow?
    private var hostingView: NSHostingView<HotZoneOverlayView>?
    private var isVisible = false
    private var presentedWindowFrame: CGRect?

    func show(
        profile: DisplayProfile,
        zoneFrames: [ZoneFrame],
        coordinateDisplayFrame: CGRect,
        windowFrame: CGRect,
        dropIntent: ZoneDropIntent
    ) {
        let zonesByID = Dictionary(profile.zones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nameResolver = ZoneNameResolver()
        let targets = resolver.dropTargets(for: zoneFrames).map { zoneFrame in
            let zone = zonesByID[zoneFrame.zoneID]
            return HotZoneTarget(
                zoneID: zoneFrame.zoneID,
                name: nameResolver.name(for: zoneFrame.zoneID, in: profile.zones),
                zoneFrame: zone?.frame ?? .full,
                previewFrame: zoneFrames.first { $0.zoneID == zoneFrame.zoneID }?.frame ?? zoneFrame.frame,
                frame: zoneFrame.frame,
                isMaximizeTargetActive: dropIntent == .zoneFit(zoneFrame.zoneID),
                isMembershipActive: dropIntent.zoneID == zoneFrame.zoneID
            )
        }

        show(targets: targets, coordinateDisplayFrame: coordinateDisplayFrame, windowFrame: windowFrame)
    }

    func show(targets: [HotZoneTarget], coordinateDisplayFrame: CGRect, windowFrame: CGRect) {
        let overlay = window ?? makeWindow(frame: windowFrame)
        let rootView = HotZoneOverlayView(
            coordinateDisplayFrame: coordinateDisplayFrame,
            targets: targets
        )
        let content = hostingView ?? NSHostingView(rootView: rootView)
        content.sizingOptions = []
        content.rootView = rootView
        content.frame = CGRect(origin: .zero, size: windowFrame.size)
        content.autoresizingMask = [.width, .height]
        hostingView = content
        if overlay.contentView !== content {
            overlay.contentView = content
        }
        if presentedWindowFrame != windowFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                overlay.setFrame(windowFrame, display: true)
            }
            presentedWindowFrame = windowFrame
        }
        if !isVisible {
            overlay.orderFrontRegardless()
            isVisible = true
        }
        window = overlay
    }

    func hide() {
        guard isVisible else { return }
        window?.orderOut(nil)
        window?.contentView = nil
        hostingView = nil
        isVisible = false
    }

    private func makeWindow(frame: CGRect) -> NSWindow {
        let window = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.hasShadow = false
        return window
    }
}

struct HotZoneOverlayView: View {
    var coordinateDisplayFrame: CGRect
    var targets: [HotZoneTarget]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(targets) { target in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(target.isMaximizeTargetActive ? 0.1 : target.isMembershipActive ? 0.045 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                target.isMembershipActive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.8),
                                lineWidth: target.isMembershipActive ? 3 : 2
                            )
                    }
                    .frame(width: target.previewFrame.width, height: target.previewFrame.height)
                    .position(
                        x: target.previewFrame.midX - coordinateDisplayFrame.minX,
                        y: target.previewFrame.midY - coordinateDisplayFrame.minY
                    )
            }
            ForEach(targets) { target in
                if let landing = target.landingFrame {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])) }
                        .frame(width: landing.width, height: landing.height)
                        .position(x: landing.midX - coordinateDisplayFrame.minX, y: landing.midY - coordinateDisplayFrame.minY)
                }
            }
            ForEach(targets) { target in
                HotZoneTargetView(target: target)
                    .frame(width: target.frame.width, height: target.frame.height)
                    .position(
                        x: target.frame.midX - coordinateDisplayFrame.minX,
                        y: target.frame.midY - coordinateDisplayFrame.minY
                    )
                if target.isMembershipActive && !target.isMaximizeTargetActive && target.landingFrame == nil {
                    Text("\(target.name) · Keep size")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: min(250, target.frame.width + 30))
                        .background(.regularMaterial, in: Capsule())
                        .position(x: target.frame.midX - coordinateDisplayFrame.minX,
                                  y: min(target.frame.maxY + 18, coordinateDisplayFrame.maxY - 20) - coordinateDisplayFrame.minY)
                }
            }
        }
        .frame(width: coordinateDisplayFrame.width, height: coordinateDisplayFrame.height)
        .background(Color.clear)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

struct HotZoneTargetView: View {
    var target: HotZoneTarget

    var body: some View {
        HStack(spacing: 10) {
            if target.frame.width >= 140 {
                ZoneIconView(frame: target.zoneFrame,
                         fill: target.isMaximizeTargetActive ? .accentColor : .secondary.opacity(0.6))
                    .frame(width: 30, height: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(target.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(target.preservesCustomSize ? "Move · Keep size" : ZoneTabAction.fit.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if target.frame.width >= 140 {
                Image(systemName: target.preservesCustomSize ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(target.isMaximizeTargetActive ? Color.accentColor : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: min(220, target.frame.width), height: min(60, target.frame.height))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(target.isMaximizeTargetActive ? 0.14 : 0))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(target.isMaximizeTargetActive ? Color.accentColor.opacity(0.65) : Color.white.opacity(0.14), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
    }
}

private extension CGRect {
    func hasPositiveOverlap(with other: CGRect) -> Bool {
        let overlap = intersection(other)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0
    }
}
