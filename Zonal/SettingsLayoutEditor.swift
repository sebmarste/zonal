import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileLayoutEditor: View {
    @Binding var profile: DisplayProfile
    @Binding var selectedZoneID: ZoneID?
    var mainZoneID: ZoneID?
    var commit: () -> Void

    @State private var dragStartFrames: [ZoneID: NormalizedFrame] = [:]
    @State private var resizeStartLayouts: [ZoneID: [ZoneID: NormalizedFrame]] = [:]
    @State private var snapGuides: [ZoneSnapGuide] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Zone spacing")
                Slider(value: $profile.zoneSpacing, in: DisplayProfile.zoneSpacingRange, step: 1,
                       onEditingChanged: { editing in if !editing { commit() } })
                    .accessibilityLabel("Zone spacing")
                TextField("Points", value: Binding(get: { profile.zoneSpacing }, set: { value in
                    guard value.isFinite else { return }
                    profile.zoneSpacing = min(DisplayProfile.zoneSpacingRange.upperBound, max(0, value.rounded()))
                    commit()
                }), format: .number)
                    .frame(width: 44)
                Text("pt").foregroundStyle(.secondary)
            }
            .padding(14)
            Text("Space between zones and around the display. Applies to this profile.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if !profile.displayRoles.isEmpty {
                ProfileDisplayOverview(
                    profile: $profile,
                    selectedZoneID: $selectedZoneID,
                    commit: commit
                )
                .frame(height: profile.displayRoles.count > 1 ? 168 : 118)
                .padding(14)
                Divider()
            }
            if let selectedZone, !profile.displayRoles.isEmpty {
                HStack {
                    Text(selectedZone.name)
                        .font(.headline)
                    Spacer()
                    Picker("Display", selection: displayRoleBinding(zoneID: selectedZone.id)) {
                        ForEach(profile.displayRoles) { role in
                            Text(role.name).tag(role.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
            }
            GeometryReader { proxy in
                let displayRect = fittedDisplayRect(in: proxy.size)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.16), lineWidth: 1.5)
                        )
                        .frame(width: displayRect.width, height: displayRect.height)
                        .position(x: displayRect.midX, y: displayRect.midY)

                    ForEach(profile.zones.filter { ($0.displayRoleID ?? editingRoleID) == editingRoleID }) { zone in
                        let previewWidth = CGFloat(profile.displayRoles.first { $0.id == editingRoleID }?.descriptor.width ?? 1920)
                        let rect = LayoutEngine().zoneFrame(for: zone, in: displayRect,
                            spacing: profile.zoneSpacing * displayRect.width / max(1, previewWidth))
                        let isSelected = zone.id == selectedZoneID
                        ZoneRectView(
                            zone: zone,
                            rect: rect,
                            isSelected: isSelected,
                            isMain: zone.id == mainZoneID,
                            select: { selectedZoneID = zone.id },
                            drag: dragGesture(zoneID: zone.id, displayRect: displayRect),
                            resize: resizeGesture(zoneID: zone.id, displayRect: displayRect)
                        )
                    }

                    ZoneSnapGuides(guides: snapGuides, displayRect: displayRect)
                        .zIndex(110)

                    SelectTargetOverlay(
                        profile: profile,
                        displayRect: displayRect,
                        displayRoleID: editingRoleID,
                        selectedZoneID: selectedZoneID,
                        select: { selectedZoneID = $0 }
                    )
                    .zIndex(100)

                    if let selectedZone {
                        GeometryGuides(
                            frame: selectedZone.frame,
                            displayRect: displayRect,
                            value: { percentValue(zoneID: selectedZone.id, dimension: $0) },
                            allowedRange: {
                                allowedRange(for: $0, zoneID: selectedZone.id, frame: selectedZone.frame)
                            },
                            commit: { dimension, value in
                                commitPercent(value, zoneID: selectedZone.id, dimension: dimension)
                            }
                        )
                        .zIndex(120)
                    }
                }
            }
        }
        .onAppear {
            selectedZoneID = selectedZoneID ?? profile.mainZoneID
        }
    }

    private var selectedZone: Zone? {
        guard let selectedZoneID else { return nil }
        return profile.zones.first { $0.id == selectedZoneID }
    }

    private var editingRoleID: DisplayRoleID {
        selectedZone?.displayRoleID
            ?? profile.displayRoles.first?.id
            ?? .workspace
    }

    private func dragGesture(zoneID: ZoneID, displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let zoneIndex = profile.zones.firstIndex(where: { $0.id == zoneID }) else { return }
                if dragStartFrames[zoneID] == nil {
                    dragStartFrames[zoneID] = profile.zones[zoneIndex].frame
                }
                guard let start = dragStartFrames[zoneID] else { return }
                let result = ZoneGeometrySnappingPolicy().snappedDrag(
                    proposed: NormalizedFrame(
                        x: start.x + Double(value.translation.width / displayRect.width),
                        y: start.y + Double(value.translation.height / displayRect.height),
                        width: start.width,
                        height: start.height
                    ),
                    movingZoneID: zoneID,
                    zones: zonesOnEditingDisplay,
                    horizontalThreshold: 6 / Double(max(1, displayRect.width)),
                    verticalThreshold: 6 / Double(max(1, displayRect.height)),
                    isDisabled: NSEvent.modifierFlags.contains(.option)
                )
                profile.zones[zoneIndex].frame = result.frame
                snapGuides = result.guides
            }
            .onEnded { _ in
                dragStartFrames[zoneID] = nil
                snapGuides = []
                commit()
            }
    }

    private func resizeGesture(zoneID: ZoneID, displayRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard profile.zones.contains(where: { $0.id == zoneID }) else { return }
                if resizeStartLayouts[zoneID] == nil {
                    resizeStartLayouts[zoneID] = Dictionary(
                        uniqueKeysWithValues: zonesOnEditingDisplay.map { ($0.id, $0.frame) }
                    )
                }
                guard let startLayout = resizeStartLayouts[zoneID],
                      let start = startLayout[zoneID] else { return }
                let startZones = zonesOnEditingDisplay.map { zone in
                    Zone(
                        id: zone.id,
                        name: zone.name,
                        frame: startLayout[zone.id] ?? zone.frame,
                        displayRoleID: zone.displayRoleID
                    )
                }
                let result = ZoneGeometrySnappingPolicy().snappedBottomRightResize(
                    proposed: NormalizedFrame(
                        x: start.x,
                        y: start.y,
                        width: start.width + Double(value.translation.width / displayRect.width),
                        height: start.height + Double(value.translation.height / displayRect.height)
                    ),
                    resizingZoneID: zoneID,
                    zones: startZones,
                    horizontalThreshold: 6 / Double(max(1, displayRect.width)),
                    verticalThreshold: 6 / Double(max(1, displayRect.height)),
                    isDisabled: NSEvent.modifierFlags.contains(.option)
                )
                let layout = ZoneSharedBoundaryPolicy().resizedLayout(
                    zoneID: zoneID,
                    from: startLayout,
                    to: result.frame,
                    linkHorizontalBoundary: true,
                    linkVerticalBoundary: true
                )
                apply(layout: layout)
                snapGuides = result.guides
            }
            .onEnded { _ in
                resizeStartLayouts[zoneID] = nil
                snapGuides = []
                commit()
            }
    }

    private var zonesOnEditingDisplay: [Zone] {
        profile.zones.filter { ($0.displayRoleID ?? editingRoleID) == editingRoleID }
    }

    private func percentValue(zoneID: ZoneID, dimension: ZoneDimension) -> Int {
        guard let frame = profile.zones.first(where: { $0.id == zoneID })?.frame else { return 0 }
        return Int((dimension.value(in: frame) * 100).rounded())
    }

    private func allowedRange(
        for dimension: ZoneDimension,
        zoneID: ZoneID,
        frame: NormalizedFrame
    ) -> ClosedRange<Int> {
        switch dimension {
        case .x:
            return 0...max(0, Int(((1 - frame.width) * 100).rounded()))
        case .y:
            return 0...max(0, Int(((1 - frame.height) * 100).rounded()))
        case .width:
            let adjacentMaximum = zonesOnEditingDisplay
                .filter {
                    $0.id != zoneID
                        && abs($0.frame.x - (frame.x + frame.width)) <= 0.005
                        && min(frame.y + frame.height, $0.frame.y + $0.frame.height)
                            - max(frame.y, $0.frame.y) > 0.01
                }
                .map { $0.frame.x + $0.frame.width - frame.x - 0.05 }
                .min()
            let maximum = min(1 - frame.x, adjacentMaximum ?? 1)
            return 5...max(5, Int(floor(maximum * 100)))
        case .height:
            let adjacentMaximum = zonesOnEditingDisplay
                .filter {
                    $0.id != zoneID
                        && abs($0.frame.y - (frame.y + frame.height)) <= 0.005
                        && min(frame.x + frame.width, $0.frame.x + $0.frame.width)
                            - max(frame.x, $0.frame.x) > 0.01
                }
                .map { $0.frame.y + $0.frame.height - frame.y - 0.05 }
                .min()
            let maximum = min(1 - frame.y, adjacentMaximum ?? 1)
            return 5...max(5, Int(floor(maximum * 100)))
        }
    }

    private func commitPercent(
        _ value: Int,
        zoneID: ZoneID,
        dimension: ZoneDimension
    ) {
        guard let zoneIndex = profile.zones.firstIndex(where: { $0.id == zoneID }) else { return }
        let originalLayout = Dictionary(
            uniqueKeysWithValues: zonesOnEditingDisplay.map { ($0.id, $0.frame) }
        )
        var proposed = profile.zones[zoneIndex].frame
        dimension.set(Double(value) / 100, in: &proposed)
        proposed = proposed.roundedToPercentStep()
        if dimension == .width || dimension == .height {
            apply(layout: ZoneSharedBoundaryPolicy().resizedLayout(
                zoneID: zoneID,
                from: originalLayout,
                to: proposed,
                linkHorizontalBoundary: dimension == .width,
                linkVerticalBoundary: dimension == .height
            ))
        } else {
            profile.zones[zoneIndex].frame = proposed
        }
        commit()
    }

    private func apply(layout: [ZoneID: NormalizedFrame]) {
        for zoneIndex in profile.zones.indices {
            if let frame = layout[profile.zones[zoneIndex].id] {
                profile.zones[zoneIndex].frame = frame
            }
        }
    }

    private func displayRoleBinding(zoneID: ZoneID) -> Binding<DisplayRoleID> {
        Binding(
            get: {
                profile.zones.first { $0.id == zoneID }?.displayRoleID
                    ?? profile.displayRoles.first?.id
                    ?? .workspace
            },
            set: { roleID in
                guard let zoneIndex = profile.zones.firstIndex(where: { $0.id == zoneID }) else { return }
                profile.zones[zoneIndex].displayRoleID = roleID
                commit()
            }
        )
    }

    private func fittedDisplayRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 28
        let topInset: CGFloat = 28
        let available = CGSize(width: max(1, size.width - inset * 2), height: max(1, size.height - inset - topInset))
        let descriptor = profile.displayRoles.first { $0.id == editingRoleID }?.descriptor
        let aspect = descriptor.map {
            CGFloat($0.width) / max(1, CGFloat($0.height))
        } ?? CGFloat(16.0 / 10.0)
        let width = min(available.width, available.height * aspect)
        let height = width / aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: topInset + (available.height - height) / 2,
            width: width,
            height: height
        )
    }
}

private struct ProfileDisplayOverview: View {
    @Binding var profile: DisplayProfile
    @Binding var selectedZoneID: ZoneID?
    var commit: () -> Void

    @State private var draggedZoneID: ZoneID?

    var body: some View {
        GeometryReader { proxy in
            let canvas = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
            ZStack(alignment: .topLeading) {
                ForEach(Array(profile.displayRoles.enumerated()), id: \.element.id) { index, role in
                    let rect = displayRect(for: role, index: index, in: canvas)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(role.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(zones(for: role.id)) { zone in
                                Text(zone.name)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        zone.id == selectedZoneID
                                            ? Color.accentColor.opacity(0.24)
                                            : Color.primary.opacity(0.07),
                                        in: Capsule()
                                    )
                                    .onTapGesture { selectedZoneID = zone.id }
                                    .onDrag {
                                        draggedZoneID = zone.id
                                        return NSItemProvider(object: zone.id.rawValue as NSString)
                                    }
                            }
                        }
                    }
                    .padding(9)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .background(
                        Color.accentColor.opacity(role.id == selectedRoleID ? 0.13 : 0.06),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                Color.accentColor.opacity(role.id == selectedRoleID ? 0.58 : 0.25),
                                lineWidth: role.id == selectedRoleID ? 1.5 : 1
                            )
                    }
                    .position(x: rect.midX, y: rect.midY)
                    .onTapGesture {
                        selectedZoneID = zones(for: role.id).first?.id ?? selectedZoneID
                    }
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        guard let draggedZoneID,
                              let zoneIndex = profile.zones.firstIndex(where: { $0.id == draggedZoneID }) else {
                            return false
                        }
                        profile.zones[zoneIndex].displayRoleID = role.id
                        selectedZoneID = draggedZoneID
                        self.draggedZoneID = nil
                        commit()
                        return true
                    }
                    .accessibilityLabel("\(role.name), \(zones(for: role.id).count) zones")
                }
            }
        }
    }

    private var selectedRoleID: DisplayRoleID? {
        guard let selectedZoneID else { return nil }
        return profile.zones.first { $0.id == selectedZoneID }?.displayRoleID
    }

    private func zones(for roleID: DisplayRoleID) -> [Zone] {
        profile.zones.filter { ($0.displayRoleID ?? profile.displayRoles.first?.id) == roleID }
    }

    private func displayRect(for role: DisplayRole, index: Int, in canvas: CGRect) -> CGRect {
        if let frame = profile.setupBindings.last?.relativeFrames[role.descriptor.persistentID] {
            return frame.rect(in: canvas)
        }
        let count = max(1, profile.displayRoles.count)
        let spacing: CGFloat = 8
        let width = (canvas.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return CGRect(
            x: canvas.minX + CGFloat(index) * (width + spacing),
            y: canvas.minY,
            width: width,
            height: canvas.height
        )
    }
}

private struct SelectTargetOverlay: View {
    private let resolver = HotZoneResolver(topOffset: 16, edgePadding: 16)

    var profile: DisplayProfile
    var displayRect: CGRect
    var displayRoleID: DisplayRoleID
    var selectedZoneID: ZoneID?
    var select: (ZoneID) -> Void

    var body: some View {
        let targets = targetFrames()
        ZStack(alignment: .topLeading) {
            ForEach(targets, id: \.zoneID) { target in
                let zone = profile.zones.first { $0.id == target.zoneID }
                Button {
                    select(target.zoneID)
                } label: {
                    HStack(spacing: 10) {
                        Text(ZoneNameResolver().name(for: target.zoneID, in: profile.zones))
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ZoneIconView(frame: zone?.frame ?? .full)
                            .frame(width: 34, height: 21)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(target.zoneID == selectedZoneID ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: target.zoneID == selectedZoneID ? 2 : 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
                .frame(width: target.frame.width, height: target.frame.height)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .position(x: target.frame.midX, y: target.frame.midY)
            }
        }
        .frame(width: displayRect.maxX + 1, height: displayRect.maxY + 1, alignment: .topLeading)
        .allowsHitTesting(true)
    }

    private func targetFrames() -> [ZoneFrame] {
        let zones = profile.zones.filter {
            ($0.displayRoleID ?? displayRoleID) == displayRoleID
        }.map { zone in
            ZoneFrame(zoneID: zone.id, frame: zone.frame.rect(in: displayRect))
        }
        return resolver.dropTargets(for: zones)
    }
}

private struct ZoneRectView<Drag: Gesture, Resize: Gesture>: View {
    var zone: Zone
    var rect: CGRect
    var isSelected: Bool
    var isMain: Bool
    var select: () -> Void
    var drag: Drag
    var resize: Resize

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.blue.opacity(0.16) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.82) : Color.gray.opacity(0.46), lineWidth: isSelected ? 2.5 : 1.25)
            )
            .overlay(alignment: .bottomTrailing) {
                Color.clear
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .gesture(resize)
                    .accessibilityLabel("Resize \(zone.name)")
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .zIndex(isSelected ? 10 : 1)
            .onTapGesture(perform: select)
            .gesture(drag)
    }
}

private enum ZoneDimension: Equatable {
    case x
    case y
    case width
    case height

    var label: String {
        switch self {
        case .x: "x"
        case .y: "y"
        case .width: "w"
        case .height: "h"
        }
    }

    func value(in frame: NormalizedFrame) -> Double {
        switch self {
        case .x: frame.x
        case .y: frame.y
        case .width: frame.width
        case .height: frame.height
        }
    }

    func set(_ value: Double, in frame: inout NormalizedFrame) {
        switch self {
        case .x: frame.x = value
        case .y: frame.y = value
        case .width: frame.width = value
        case .height: frame.height = value
        }
    }
}

private struct ZoneSnapGuides: View {
    var guides: [ZoneSnapGuide]
    var displayRect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                let isHorizontal = guide.axis == .horizontal
                let position = isHorizontal
                    ? displayRect.minY + displayRect.height * guide.position
                    : displayRect.minX + displayRect.width * guide.position
                Rectangle()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(
                        width: isHorizontal ? displayRect.width : 2,
                        height: isHorizontal ? 2 : displayRect.height
                    )
                    .position(
                        x: isHorizontal ? displayRect.midX : position,
                        y: isHorizontal ? position : displayRect.midY
                    )
                Text("Align · \(guide.label)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .position(
                        x: isHorizontal ? displayRect.maxX - 48 : position,
                        y: isHorizontal ? position - 12 : displayRect.minY + 14
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GeometryGuides: View {
    var frame: NormalizedFrame
    var displayRect: CGRect
    var value: (ZoneDimension) -> Int
    var allowedRange: (ZoneDimension) -> ClosedRange<Int>
    var commit: (ZoneDimension, Int) -> Void

    var body: some View {
        let zoneRect = frame.rect(in: displayRect)
        let horizontalGap = zoneRect.minX - displayRect.minX
        let verticalGap = zoneRect.minY - displayRect.minY
        let horizontalBadgeWidth: CGFloat = 86
        let verticalBadgeHeight: CGFloat = 30
        let proposedXBadgeX = horizontalGap >= horizontalBadgeWidth + 12
            ? displayRect.minX + horizontalGap / 2
            : displayRect.minX - horizontalBadgeWidth / 2 - 10
        let xBadgeX = max(horizontalBadgeWidth / 2 + 8, proposedXBadgeX)
        let yBadgeY = verticalGap >= verticalBadgeHeight + 12
            ? displayRect.minY + verticalGap / 2
            : displayRect.minY - verticalBadgeHeight / 2 - 10
        let minimumVerticalControlY = zoneRect.minY + verticalBadgeHeight / 2 + 10
        let maximumVerticalControlY = max(
            minimumVerticalControlY,
            zoneRect.maxY - verticalBadgeHeight / 2 - 10
        )
        let verticalControlY = min(
            maximumVerticalControlY,
            max(minimumVerticalControlY, zoneRect.minY + zoneRect.height * 0.72)
        )

        ZStack(alignment: .topLeading) {
            GuideLine(
                orientation: .horizontal,
                rect: CGRect(
                    x: displayRect.minX,
                    y: verticalControlY,
                    width: max(0, horizontalGap),
                    height: 1
                ),
                dimension: .x,
                value: value(.x),
                allowedRange: allowedRange(.x),
                commit: { commit(.x, $0) },
                badgePosition: CGPoint(x: xBadgeX, y: verticalControlY)
            )
            GuideLine(
                orientation: .vertical,
                rect: CGRect(
                    x: zoneRect.midX,
                    y: displayRect.minY,
                    width: 1,
                    height: max(0, verticalGap)
                ),
                dimension: .y,
                value: value(.y),
                allowedRange: allowedRange(.y),
                commit: { commit(.y, $0) },
                badgePosition: CGPoint(x: zoneRect.midX, y: yBadgeY)
            )
            GuideLine(
                orientation: .horizontal,
                rect: CGRect(
                    x: zoneRect.minX,
                    y: max(zoneRect.minY + 14, zoneRect.maxY - 18),
                    width: zoneRect.width,
                    height: 1
                ),
                dimension: .width,
                value: value(.width),
                allowedRange: allowedRange(.width),
                commit: { commit(.width, $0) },
                badgePosition: CGPoint(x: zoneRect.midX, y: max(zoneRect.minY + 14, zoneRect.maxY - 18))
            )
            GuideLine(
                orientation: .vertical,
                rect: CGRect(
                    x: max(zoneRect.minX + 18, zoneRect.maxX - 18),
                    y: zoneRect.minY,
                    width: 1,
                    height: zoneRect.height
                ),
                dimension: .height,
                value: value(.height),
                allowedRange: allowedRange(.height),
                commit: { commit(.height, $0) },
                badgePosition: CGPoint(
                    x: max(zoneRect.minX + 18, zoneRect.maxX - 18),
                    y: verticalControlY
                )
            )
        }
        .frame(width: displayRect.maxX + 96, height: displayRect.maxY + 48, alignment: .topLeading)
    }
}

private struct GuideLine: View {
    enum Orientation {
        case horizontal
        case vertical
    }

    var orientation: Orientation
    var rect: CGRect
    var dimension: ZoneDimension
    var value: Int
    var allowedRange: ClosedRange<Int>
    var commit: (Int) -> Void
    var badgePosition: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            DimensionGuideShape(
                orientation: orientation,
                showsArrowheads: showsArrowheads
            )
                .stroke(
                    Color.secondary.opacity(0.68),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
                .frame(
                    width: max(
                        2,
                        orientation == .horizontal ? rect.width : guideCrossAxisSize
                    ),
                    height: max(
                        2,
                        orientation == .horizontal ? guideCrossAxisSize : rect.height
                    )
                )
                .position(x: rect.midX, y: rect.midY)

            GuideValueBadge(
                label: dimension.label,
                value: value,
                allowedRange: allowedRange,
                commit: commit
            )
                .position(badgePosition)
        }
    }

    private var guideLength: CGFloat {
        orientation == .horizontal ? rect.width : rect.height
    }

    private var showsArrowheads: Bool {
        guideLength >= 30
    }

    private var guideCrossAxisSize: CGFloat {
        showsArrowheads ? 10 : 2
    }
}

private struct DimensionGuideShape: Shape {
    var orientation: GuideLine.Orientation
    var showsArrowheads: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arrowDepth: CGFloat = 6
        let arrowHalfWidth: CGFloat = 4

        switch orientation {
        case .horizontal:
            let y = rect.midY
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            if showsArrowheads {
                path.move(to: CGPoint(x: rect.minX + arrowDepth, y: y - arrowHalfWidth))
                path.addLine(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.minX + arrowDepth, y: y + arrowHalfWidth))
                path.move(to: CGPoint(x: rect.maxX - arrowDepth, y: y - arrowHalfWidth))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX - arrowDepth, y: y + arrowHalfWidth))
            }
        case .vertical:
            let x = rect.midX
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            if showsArrowheads {
                path.move(to: CGPoint(x: x - arrowHalfWidth, y: rect.minY + arrowDepth))
                path.addLine(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x + arrowHalfWidth, y: rect.minY + arrowDepth))
                path.move(to: CGPoint(x: x - arrowHalfWidth, y: rect.maxY - arrowDepth))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + arrowHalfWidth, y: rect.maxY - arrowDepth))
            }
        }
        return path
    }
}

private struct GuideValueBadge: View {
    var label: String
    var value: Int
    var allowedRange: ClosedRange<Int>
    var commit: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            TransactionalPercentField(
                value: value,
                allowedRange: allowedRange,
                accessibilityLabel: "\(label) percentage",
                commit: commit
            )
                .frame(width: 34)
            Text("%")
                .foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit().weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .fixedSize()
    }
}

private struct TransactionalPercentField: NSViewRepresentable {
    var value: Int
    var allowedRange: ClosedRange<Int>
    var accessibilityLabel: String
    var commit: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.focusRingType = .none
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.setAccessibilityLabel(accessibilityLabel)
        guard field.currentEditor() == nil else { return }
        field.stringValue = String(value)
        field.textColor = .labelColor
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TransactionalPercentField
        private var originalValue: Int
        private var didCommitDuringEditing = false

        init(parent: TransactionalPercentField) {
            self.parent = parent
            self.originalValue = parent.value
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            originalValue = parent.value
            didCommitDuringEditing = false
            field.stringValue = String(parent.value)
            field.currentEditor()?.selectAll(nil)
            validate(field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            validate(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if !didCommitDuringEditing {
                commitDraft(in: field)
            }
            field.textColor = .labelColor
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                didCommitDuringEditing = commitDraft(in: field)
                if didCommitDuringEditing {
                    field.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.stringValue = String(originalValue)
                field.textColor = .labelColor
                didCommitDuringEditing = true
                field.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                nudge(field, delta: 1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                nudge(field, delta: -1)
                return true
            default:
                return false
            }
        }

        private func nudge(_ field: NSTextField, delta: Int) {
            let current = Int(field.stringValue) ?? parent.value
            let next = min(parent.allowedRange.upperBound, max(parent.allowedRange.lowerBound, current + delta))
            field.stringValue = String(next)
            field.textColor = .labelColor
            originalValue = next
            parent.commit(next)
            field.currentEditor()?.selectAll(nil)
        }

        @discardableResult
        private func commitDraft(in field: NSTextField) -> Bool {
            guard let value = Int(field.stringValue), parent.allowedRange.contains(value) else {
                NSSound.beep()
                field.stringValue = String(originalValue)
                field.textColor = .labelColor
                return false
            }
            if value != originalValue {
                parent.commit(value)
                originalValue = value
            }
            return true
        }

        private func validate(_ field: NSTextField) {
            let value = Int(field.stringValue)
            field.textColor = value.map(parent.allowedRange.contains) == true
                ? .labelColor
                : .systemRed
        }
    }
}
