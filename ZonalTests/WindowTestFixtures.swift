import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

struct FixedDisplayProvider: DisplaySnapshotProviding {
    var snapshot: DisplaySnapshot

    func currentSnapshot() -> DisplaySnapshot { snapshot }
}


extension XCTestCase {
    func managedWindow(
        cgWindowID: UInt32,
        observedOrder: Int,
        titleHint: String? = nil
    ) -> ManagedWindow {
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: cgWindowID,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: observedOrder,
            titleHint: titleHint
        )
        return ManagedWindow(
            id: .quartz(processIdentifier: 42, windowNumber: cgWindowID),
            identity: identity,
            appName: "Example",
            title: nil,
            icon: nil,
            element: AXUIElementCreateSystemWide()
        )
    }

    func switcherItem(
        assignmentID: UUID,
        windowID: UInt32,
        zoneID: ZoneID
    ) -> SwitcherItem {
        SwitcherItem(
            assignmentID: assignmentID,
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: windowID,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: Int(windowID)
            ),
            appName: "Example",
            title: "Window \(windowID)",
            icon: nil,
            zoneID: zoneID,
            zoneName: ZoneNameResolver().name(
                for: zoneID,
                in: [Zone(id: zoneID, name: "Configured \(zoneID.rawValue)", frame: .full)]
            ),
            zoneFrame: .full,
            isActive: false
        )
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
