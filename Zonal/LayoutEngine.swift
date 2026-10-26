import CoreGraphics
import Foundation

struct LayoutEngine {
    func zoneFrames(for profile: DisplayProfile, in displayFrame: CGRect) -> [ZoneFrame] {
        profile.zones.map { zone in
            ZoneFrame(
                zoneID: zone.id,
                frame: zoneFrame(for: zone, in: displayFrame, spacing: profile.zoneSpacing),
                displayRoleID: zone.displayRoleID
            )
        }
    }

    func zoneFrames(
        for profile: DisplayProfile,
        displayFramesByRole: [DisplayRoleID: CGRect],
        fallbackDisplayFrame: CGRect?
    ) -> [ZoneFrame] {
        profile.zones.compactMap { zone in
            let roleID = zone.displayRoleID
                ?? profile.displayRoles.first?.id
                ?? .workspace
            guard let displayFrame = displayFramesByRole[roleID] ?? fallbackDisplayFrame else {
                return nil
            }
            return ZoneFrame(
                zoneID: zone.id,
                frame: zoneFrame(for: zone, in: displayFrame, spacing: profile.zoneSpacing),
                displayRoleID: roleID
            )
        }
    }

    func zoneFrame(for zone: Zone, in displayFrame: CGRect, spacing: Double) -> CGRect {
        guard spacing > 0, spacing.isFinite else {
            return zone.frame.roundedToPercentStep().rect(in: displayFrame)
        }
        // Half the gap on each side of a shared boundary; a full gap at the display edge.
        let gap = min(spacing, max(0, min(displayFrame.width, displayFrame.height) - 1))
        let bounds = displayFrame.insetBy(dx: gap / 2, dy: gap / 2)
        let frame = zone.frame.roundedToPercentStep().rect(in: bounds)
        return frame.insetBy(dx: min(gap / 2, max(0, (frame.width - 1) / 2)),
                             dy: min(gap / 2, max(0, (frame.height - 1) / 2)))
    }

    func switcherZoneColumns(
        for zoneFrames: [ZoneFrame],
        profileOrder: [ZoneID]
    ) -> [[ZoneID]] {
        guard !zoneFrames.isEmpty else { return [] }
        let order = Dictionary(uniqueKeysWithValues: profileOrder.enumerated().map { ($1, $0) })
        let union = zoneFrames.dropFirst().reduce(zoneFrames[0].frame) { $0.union($1.frame) }
        let columnTolerance = max(union.width * 0.04, 12)
        let rowTolerance = max(union.height * 0.04, 12)

        struct Column {
            var centerX: CGFloat
            var frames: [ZoneFrame]
        }

        var columns: [Column] = []
        let horizontallyOrdered = zoneFrames.sorted { lhs, rhs in
            if !approximatelyEqual(lhs.frame.midX, rhs.frame.midX) {
                return lhs.frame.midX < rhs.frame.midX
            }
            return (order[lhs.zoneID] ?? .max) < (order[rhs.zoneID] ?? .max)
        }

        for zoneFrame in horizontallyOrdered {
            if let index = columns.indices.min(by: {
                abs(columns[$0].centerX - zoneFrame.frame.midX)
                    < abs(columns[$1].centerX - zoneFrame.frame.midX)
            }), abs(columns[index].centerX - zoneFrame.frame.midX) <= columnTolerance {
                columns[index].frames.append(zoneFrame)
                columns[index].centerX = columns[index].frames.map(\.frame.midX).reduce(0, +)
                    / CGFloat(columns[index].frames.count)
            } else {
                columns.append(Column(centerX: zoneFrame.frame.midX, frames: [zoneFrame]))
            }
        }

        return columns.sorted { $0.centerX < $1.centerX }.map { column in
            column.frames.sorted { lhs, rhs in
                if abs(lhs.frame.midY - rhs.frame.midY) > rowTolerance {
                    return lhs.frame.midY > rhs.frame.midY
                }
                return (order[lhs.zoneID] ?? .max) < (order[rhs.zoneID] ?? .max)
            }.map(\.zoneID)
        }
    }

    func neighboringZoneID(
        from zoneID: ZoneID,
        direction: SwitcherArrowKey,
        columns: [[ZoneID]]
    ) -> ZoneID? {
        guard let columnIndex = columns.firstIndex(where: { $0.contains(zoneID) }),
              let rowIndex = columns[columnIndex].firstIndex(of: zoneID) else {
            return nil
        }

        switch direction {
        case .up:
            guard rowIndex > 0 else { return nil }
            return columns[columnIndex][rowIndex - 1]
        case .down:
            guard rowIndex + 1 < columns[columnIndex].count else { return nil }
            return columns[columnIndex][rowIndex + 1]
        case .left:
            guard columnIndex > 0 else { return nil }
            let target = columns[columnIndex - 1]
            return target[min(rowIndex, target.count - 1)]
        case .right:
            guard columnIndex + 1 < columns.count else { return nil }
            let target = columns[columnIndex + 1]
            return target[min(rowIndex, target.count - 1)]
        }
    }

    private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.5
    }
}
