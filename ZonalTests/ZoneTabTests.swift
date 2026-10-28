import AppKit
import SwiftUI
import XCTest
@testable import Zonal

@MainActor
final class ZoneTabTests: XCTestCase {
    func testSpacingUsesSameBoundsForWindowTargetsAndTabSurfaces() throws {
        let (store, service, tracker, manager, _, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let snapshot = manager.currentSnapshot()
        let display = snapshot.displays[0].placementFrame
        for presentation in ZoneWindowPresentation.allCases {
            var config = store.loadConfiguration()
            config.profiles[0].zoneSpacing = 16
            config.profiles[0].zones[0].windowPresentation = presentation
            XCTAssertTrue(store.saveConfiguration(config))
            manager.reloadProfiles()
            service.reconcile()
            let profile = config.profiles[0]
            let zone = profile.zones[0]
            let bounds = LayoutEngine().zoneFrame(for: zone, in: display, spacing: 16)
            let expected = presentation == .tabs
                ? ZoneTabLayout(zoneFrame: bounds, edge: config.tabEdge, style: zone.tabStyle, borderWidth: zone.tabBorderWidth).windowFrame
                : bounds
            XCTAssertEqual(service.targetFrame(for: assignments[0], profile: profile, snapshot: snapshot)?.frame, expected)
            if presentation == .tabs {
                XCTAssertEqual(service.tabSnapshots().first?.layout.windowFrame, expected)
            }
        }
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }

    func testIconsOnlyTabsKeepAccessibleNamesAndNativeHitTargets() async throws {
        var item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        item.title = "Window title"
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 600, height: 400), edge: .top)
        var model = ZoneTabSnapshot(zoneID: .main, edge: .top, layout: layout, items: [item])
        let panel = ZoneTabController.makePanel()
        defer { panel.close() }
        panel.setFrame(CGRect(origin: .zero, size: model.panelFrame().size), display: false)
        let host = NSHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
        host.sizingOptions = []
        panel.contentView = host
        func buttons(_ view: NSView) -> [ZoneTabNativeButton] {
            if let button = view as? ZoneTabNativeButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        for names in [true, false, true] {
            model.showsNames = names
            host.rootView = ZoneTabStripView(snapshot: model, focus: { _ in })
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let button = try XCTUnwrap(buttons(host).first)
            XCTAssertEqual(button.title, names ? "Window title" : "")
            XCTAssertEqual(button.imagePosition, names ? .imageLeft : .imageOnly)
            XCTAssertNotNil(button.image)
            if !names { XCTAssertEqual(button.bounds.width, 24, accuracy: 0.5) }
            XCTAssertTrue(button.cell is ZoneTabButtonCell)
            XCTAssertTrue(button.accessibilityLabel()?.contains("Window title") == true)
            XCTAssertEqual(button.assignmentID, item.assignmentID)
        }
    }

    func testMoveMenuDoesNotFocusAndKeepsCapturedTargetThroughRedraw() throws {
        var button: ZoneTabNativeButton? = ZoneTabNativeButton()
        let original = UUID()
        button?.assignmentID = original
        button?.zoneID = .main
        button?.destinations = [Zone(id: .main, name: "Main", frame: .full),
                                Zone(id: .left, name: "Left", frame: .full)]
        var focused: [UUID] = []
        var moved: [(UUID, ZoneID)] = []
        button?.focus = { focused.append($0) }
        button?.performAction = { id, action in
            if case .move(let zone) = action { moved.append((id, zone)) }
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(button?.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Move to Left", "", "Close Window"])
        XCTAssertNotNil(menu.items.first?.image)
        XCTAssertTrue(focused.isEmpty)
        XCTAssertTrue(moved.isEmpty)
        button?.assignmentID = UUID()
        button = nil
        menu.performActionForItem(at: 0)
        XCTAssertTrue(focused.isEmpty)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.0, original)
        XCTAssertEqual(moved.first?.1, .left)
    }

    func testSizeMenuActionKeepsOriginalWindowWithoutFocusingOnOpen() throws {
        let button = ZoneTabNativeButton()
        let original = UUID()
        button.assignmentID = original
        var actions: [(UUID, ZoneTabAction)] = []
        button.performAction = { actions.append(($0, $1)) }
        button.focus = { _ in XCTFail("Opening the menu must not focus its window") }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        for action in [ZoneTabAction.fit, .restoreCustom] {
            button.assignmentID = original
            button.sizeAction = action
            let menu = try XCTUnwrap(button.menu(for: event))
            XCTAssertEqual(menu.items.map(\.title), [action == .fit ? "Fit to Zone" : "Restore Custom Size", "", "Close Window"])
            XCTAssertNotNil(menu.items.first?.image)
            button.assignmentID = UUID()
            button.sizeAction = nil
            menu.performActionForItem(at: 0)
            XCTAssertEqual(actions.last?.0, original)
            XCTAssertEqual(actions.last?.1, action)
            menu.performActionForItem(at: 2)
            XCTAssertEqual(actions.last?.0, original)
            XCTAssertEqual(actions.last?.1, .close)
        }
    }

    func testDoubleClickKeepsOriginalTabThroughMRUReordering() {
        let original = UUID(), replacement = UUID()
        var focuses: [UUID] = []
        var actions: [(UUID, ZoneTabAction)] = []
        let interaction = ZoneTabInteractionController(focus: { focuses.append($0) },
            performAction: { actions.append(($0, $1)) }, prepareDrag: { _ in nil }, preview: { _, _ in })
        interaction.press(id: original, point: .zero, timestamp: 1, clickCount: 1, sizeAction: .fit)
        XCTAssertEqual(focuses, [original], "Single-click focus must remain immediate")
        interaction.pointer(.leftMouseUp, at: .zero)
        interaction.press(id: replacement, point: .zero, timestamp: 1 + NSEvent.doubleClickInterval / 2,
                          clickCount: 2, sizeAction: .restoreCustom)
        XCTAssertEqual(focuses, [original])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.0, original)
        XCTAssertEqual(actions.first?.1, .fit)
        interaction.press(id: original, point: .zero, timestamp: 3, clickCount: 1, sizeAction: nil)
        interaction.pointer(.leftMouseUp, at: .zero)
        interaction.press(id: replacement, point: .zero, timestamp: 3 + NSEvent.doubleClickInterval / 2,
                          clickCount: 2, sizeAction: .fit)
        XCTAssertEqual(actions.count, 1, "A fitted window without saved custom size must stay fitted")
        XCTAssertEqual(focuses.last, original)
    }

    func testTabDragCommitsOnlyOnValidDropAndEscapeOrChangedPlanCancels() throws {
        let (store, service, tracker, manager, _, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones[0].frame = NormalizedFrame(x: 0.25, y: 0, width: 0.75, height: 1)
        config.profiles[0].zones.append(Zone(id: .left, name: "Left",
            frame: NormalizedFrame(x: 0, y: 0, width: 0.25, height: 1), windowPresentation: .tabs))
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        service.reconcile()
        let id = assignments[2].id
        var plan = try XCTUnwrap(service.tabDragPlan(assignmentID: id))
        XCTAssertFalse(plan.isFitted)
        XCTAssertEqual(plan.destinations.count, 1)
        XCTAssertEqual(plan.destinations.first?.landingFrame.size, CGSize(width: 1600, height: 944))
        let initialBytes = try Data(contentsOf: store.workspaceURL)
        var actions: [(UUID, ZoneTabAction)] = []
        var preview: ZoneTabDragPlan?
        let interaction = ZoneTabInteractionController(focus: { _ in }, performAction: { actions.append(($0, $1)) },
            prepareDrag: { candidate in candidate == id ? plan : nil }, preview: { preview = $0; _ = $1 })
        let origin = CGPoint(x: 1200, y: 950), drop = CGPoint(x: 100, y: 600)
        interaction.press(id: id, point: origin, timestamp: 1, clickCount: 1, sizeAction: .fit)
        interaction.pointer(.leftMouseDragged, at: CGPoint(x: 1202, y: 950))
        XCTAssertNil(preview)
        interaction.pointer(.leftMouseDragged, at: drop)
        XCTAssertEqual(preview, plan)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), initialBytes, "Preview must be read-only")
        interaction.pointer(.leftMouseUp, at: drop)
        XCTAssertNil(preview)
        XCTAssertEqual(actions.first?.0, id)
        XCTAssertEqual(actions.first?.1, .move(.left))
        for cancel in [true, false] {
            interaction.press(id: id, point: origin, timestamp: 3, clickCount: 1, sizeAction: .fit)
            interaction.pointer(.leftMouseDragged, at: drop)
            if cancel { XCTAssertTrue(interaction.cancel()) } else { plan.profileID = "changed" }
            interaction.pointer(.leftMouseUp, at: drop)
            XCTAssertEqual(actions.count, 1)
            XCTAssertNil(preview)
        }
        interaction.press(id: id, point: origin, timestamp: 5, clickCount: 1, sizeAction: .fit)
        interaction.pointer(.leftMouseDragged, at: drop)
        interaction.pointer(.leftMouseUp, at: CGPoint(x: 1200, y: 950))
        XCTAssertEqual(actions.count, 1, "Dropping outside a destination must cancel")
    }

    func testTabDragOverlappingZonesRequireAnExplicitTarget() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destinations = [ZoneID.left, .right].map { id in
            ZoneTabDragDestination(zone: Zone(id: id, name: id.rawValue, frame: .full), zoneFrame: frame,
                landingFrame: CGRect(x: 200, y: 500, width: 500, height: 300))
        }
        let plan = ZoneTabDragPlan(assignmentID: UUID(), windowID: .quartz(processIdentifier: 42, windowNumber: 1),
            profileID: "test", displays: DisplaySnapshot(displays: []), destinations: destinations, isFitted: false)
        XCTAssertNil(plan.destination(at: CGPoint(x: 500, y: 700)))
        let markers = HotZoneResolver().dropTargets(for: destinations.map { ZoneFrame(zoneID: $0.zone.id, frame: $0.zoneFrame) })
        for marker in markers {
            let point = CGPoint(x: marker.frame.midX, y: marker.frame.midY)
            XCTAssertEqual(plan.destination(at: point), marker.zoneID)
            let targets = plan.overlayTargets(at: point)
            XCTAssertEqual(targets.filter { $0.landingFrame != nil }.count, 1)
            XCTAssertEqual(targets.first { $0.zoneID == marker.zoneID }?.landingFrame, destinations[0].landingFrame)
            XCTAssertTrue(targets.allSatisfy(\.preservesCustomSize))
        }
    }

    func testCloseUsesExactWindowWithoutFocusingIt() async throws {
        let access = TabCloseAccess()
        let controller = WindowController(closeAccess: access)
        let window = managedWindow(cgWindowID: 42, observedOrder: 0)
        let completed = expectation(description: "close request")
        controller.close(window) { accepted in XCTAssertTrue(accepted); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(access.matches(window.element))
    }

    func testNativeTabDragPreviewCompositing() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_TAB_PROTOTYPE_CHECK"] == "1" else {
            throw XCTSkip("Opt-in native preview fixture.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let appKitFrame = CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 60, width: 800, height: 600)
        let quartz = CGRect(x: appKitFrame.minX, y: screen.frame.maxY - appKitFrame.maxY, width: 800, height: 600)
        let backdrop = NSWindow(contentRect: appKitFrame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = .systemGreen
        backdrop.orderFrontRegardless()
        let known = Set(NSApp.windows.map(\.windowNumber))
        let overlay = HotZoneOverlayController()
        defer { overlay.hide(); backdrop.close() }
        let zone = quartz.insetBy(dx: 30, dy: 30)
        let landing = CGRect(x: zone.minX + 140, y: zone.maxY - 200, width: 460, height: 200)
        let target = HotZoneTarget(zoneID: .left, name: "Left", zoneFrame: .full,
            previewFrame: zone, frame: CGRect(x: zone.midX - 140, y: zone.minY + 70, width: 280, height: 84),
            isMaximizeTargetActive: false, isMembershipActive: true, landingFrame: landing, preservesCustomSize: true)
        overlay.show(targets: [target], coordinateDisplayFrame: quartz, windowFrame: appKitFrame)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try XCTUnwrap(NSApp.windows.first { !known.contains($0.windowNumber) && $0.level == .statusBar })
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertTrue(panel.ignoresMouseEvents)
        let host = try XCTUnwrap(panel.contentView)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: bitmap.pixelsWide - 1, y: 0),
                      CGPoint(x: 0, y: bitmap.pixelsHigh - 1), CGPoint(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)] {
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent, 0.01)
        }
        let image = NSImage(size: appKitFrame.size)
        image.lockFocus()
        NSColor.systemGreen.setFill()
        CGRect(origin: .zero, size: appKitFrame.size).fill()
        let capturedImage = NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: appKitFrame.size)
        capturedImage.draw(in: CGRect(origin: .zero, size: appKitFrame.size), from: .zero, operation: .sourceOver, fraction: 1)
        let fillAlpha = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent
        XCTAssertGreaterThan(fillAlpha, 0.01)
        XCTAssertLessThan(fillAlpha, 0.1, "The zone highlight must remain translucent")
        image.unlockFocus()
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/zonal-tab-drag-preview-runtime.png"))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(quartz.minX)),\(Int(quartz.minY)),800,600", "/tmp/zonal-tab-drag-preview-desktop.png"]
        try capture.run()
        capture.waitUntilExit()
    }

    func testMoveMenuKeepsFrameBehindWindowWhileTracking() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_TAB_PROTOTYPE_CHECK"] == "1" else {
            throw XCTSkip("Opt-in native menu ordering fixture.")
        }
        let panel = ZoneTabController.makePanel()
        let native = NSWindow(contentRect: CGRect(x: 100, y: 140, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        native.isReleasedWhenClosed = false
        defer { panel.close(); native.close() }
        panel.setFrame(CGRect(x: 90, y: 90, width: 420, height: 380), display: false)
        let button = ZoneTabNativeButton(frame: CGRect(x: 10, y: 10, width: 180, height: 24))
        button.assignmentID = UUID()
        button.zoneID = .main
        button.destinations = [Zone(id: .main, name: "Main", frame: .full),
                               Zone(id: .left, name: "Left", frame: .full)]
        var focused = false
        button.focus = { _ in focused = true }
        panel.contentView?.addSubview(button)
        native.orderFrontRegardless()
        for controlClick in [false, true] {
            panel.order(.below, relativeTo: native.windowNumber)
            try await Task.sleep(for: .milliseconds(100))
            let observer = ZoneTabMenuTrackingObserver {
                let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] ?? []
                let ids = rows.compactMap { $0[kCGWindowNumber as String] as? Int }
                let frameIndex = try XCTUnwrap(ids.firstIndex(of: panel.windowNumber))
                let nativeIndex = try XCTUnwrap(ids.firstIndex(of: native.windowNumber))
                XCTAssertGreaterThan(frameIndex, nativeIndex, "The open menu must not raise its backing frame")
            }
            NotificationCenter.default.addObserver(observer, selector: #selector(ZoneTabMenuTrackingObserver.began(_:)),
                name: NSMenu.didBeginTrackingNotification, object: nil)
            defer { NotificationCenter.default.removeObserver(observer); observer.timer?.invalidate() }
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: controlClick ? .leftMouseDown : .rightMouseDown,
                location: CGPoint(x: 50, y: 20), modifierFlags: controlClick ? [.control] : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if controlClick { button.mouseDown(with: event) } else { button.rightMouseDown(with: event) }
            XCTAssertTrue(observer.sampled, "Sample the frame during actual menu tracking")
            XCTAssertFalse(focused)
        }
    }

    func testMovingBackgroundTabFitsDestinationAndPreservesSourceActiveWindow() throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones.append(Zone(id: .left, name: "Left", frame: .full, windowPresentation: .tabs))
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        service.reconcile()
        XCTAssertEqual(service.assignWindow(windows[1], to: .left, clearCustomFrame: true), .saved)
        let active = assignments[0].id, moving = assignments[2].id, destination = assignments[1].id
        XCTAssertTrue(store.saveZoneStackState(ZoneStackState(globalRecency: [active, moving],
            activeAssignmentByZone: [.main: active, .left: destination],
            assignmentRecencyByZone: [.main: [active, moving], .left: [destination]])))
        XCTAssertEqual(service.assignWindow(windows[2], to: .left, clearCustomFrame: true), .saved)
        let history = store.loadZoneStackState()
        XCTAssertEqual(history.activeAssignmentByZone[.main], active)
        XCTAssertEqual(history.assignmentRecencyByZone[.main], [active])
        XCTAssertEqual(history.activeAssignmentByZone[.left], moving)
        XCTAssertEqual(history.assignmentRecencyByZone[.left], [moving, destination])
        let moved = try XCTUnwrap(store.loadAssignments().first { $0.id == moving })
        XCTAssertEqual(moved.zoneID, .left)
        XCTAssertTrue(moved.fitsZone(in: config.profiles[0].id))
    }

    func testTabMovePreservesCustomSizeAndMapsAnchorsBetweenUsableZoneFrames() throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones.append(Zone(id: .left, name: "Left",
            frame: NormalizedFrame(x: 0, y: 0, width: 0.25, height: 1), windowPresentation: .tabs))
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        service.reconcile()
        let context = service.currentProfileContext()
        let display = context.snapshot.displays[0].placementFrame
        let source = ZoneTabLayout(zoneFrame: display, edge: store.loadConfiguration().tabEdge).windowFrame
        let destination = ZoneTabLayout(zoneFrame: config.profiles[0].zones[1].frame.rect(in: display), edge: store.loadConfiguration().tabEdge).windowFrame
        for anchor in [CGPoint(x: 0.5, y: 1), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 1, y: 0)] {
            store.saveAssignments(assignments)
            let size = CGSize(width: 300, height: 250)
            let current = CGRect(x: source.minX + anchor.x * (source.width - size.width),
                                 y: source.minY + anchor.y * (source.height - size.height),
                                 width: size.width, height: size.height)
            guard case .fit(.left) = service.tabMoveChange(for: assignments[0], currentFrame: current,
                to: .left, context: context) else { return XCTFail("Fitted tabs must continue fitting") }
            guard case .move(let zone, let target) = service.tabMoveChange(for: assignments[2], currentFrame: current,
                to: .left, context: context) else { return XCTFail("Custom tabs must remain custom") }
            XCTAssertEqual(zone, .left)
            XCTAssertEqual(target.minX, (destination.minX + anchor.x * (destination.width - size.width)).rounded())
            XCTAssertEqual(target.minY, (destination.minY + anchor.y * (destination.height - size.height)).rounded())
            XCTAssertEqual(target.size, current.size)
            XCTAssertTrue(store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [.main: assignments[0].id],
                assignmentRecencyByZone: [.main: [assignments[0].id, assignments[2].id]])))
            XCTAssertEqual(service.assignCustomFrame(windows[2], to: zone, frame: target), .saved)
            let moved = try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[2].id })
            XCTAssertFalse(moved.fitsZone(in: context.profile.id))
            XCTAssertEqual(service.targetFrame(for: moved, profile: context.profile, snapshot: context.snapshot)?.frame, target)
            XCTAssertEqual(store.loadZoneStackState().activeAssignmentByZone[.main], assignments[0].id)
            XCTAssertEqual(store.loadZoneStackState().activeAssignmentByZone[.left], assignments[2].id)
        }
    }

    func testFitRemembersCustomPlacementAcrossReloadAndMoveToAnotherZone() throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones.append(Zone(id: .left, name: "Left",
            frame: NormalizedFrame(x: 0, y: 0, width: 0.5, height: 1), windowPresentation: .tabs))
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        service.reconcile()
        let context = service.currentProfileContext()
        let profileID = context.profile.id
        let fitted = try XCTUnwrap(service.targetFrame(for: assignments[0], profile: context.profile, snapshot: context.snapshot)).frame
        let custom = CGRect(x: (fitted.midX - 250).rounded(), y: fitted.maxY - 300, width: 500, height: 300)
        XCTAssertEqual(service.assignCustomFrame(windows[2], to: .main, frame: custom), .saved)
        func current() throws -> WindowAssignment {
            try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[2].id })
        }
        let saved = try XCTUnwrap(current().savedCustomPlacementsByProfileID[profileID])
        XCTAssertEqual(saved.relativePosition.x, 0.5, accuracy: 0.002)
        XCTAssertEqual(saved.relativePosition.y, 1)
        XCTAssertEqual(saved.size, custom.size)
        XCTAssertEqual(service.assignWindow(windows[2], to: .main, clearCustomFrame: true), .saved)
        XCTAssertTrue(try current().fitsZone(in: profileID))
        XCTAssertEqual(service.assignWindow(windows[2], to: .main, clearCustomFrame: true, customFrameBeforeFit: fitted), .saved)
        XCTAssertEqual(try current().savedCustomPlacementsByProfileID[profileID], saved, "Fitted geometry must not overwrite custom memory")
        XCTAssertEqual(service.tabSnapshots().first?.sizeActions[assignments[2].id], .restoreCustom)
        XCTAssertNil(service.tabSnapshots().first?.sizeActions[assignments[0].id])
        XCTAssertTrue(store.flushPendingWorkspaceWrite())
        let reloaded = try XCTUnwrap(PersistenceStore(supportDirectory: store.supportDirectory).loadAssignments().first { $0.id == assignments[2].id })
        XCTAssertEqual(reloaded.savedCustomPlacementsByProfileID[profileID], saved)
        XCTAssertEqual(service.assignWindow(windows[2], to: .left, clearCustomFrame: true), .saved)
        XCTAssertEqual(try current().savedCustomPlacementsByProfileID[profileID], saved)
        guard case .move(.left, let restored) = service.restoreCustomChange(for: try current(), context: context)
            else { return XCTFail("Custom placement must remain available after fitting and moving") }
        var fittedDestination = assignments[0]
        fittedDestination.zoneID = .left
        fittedDestination.placementsByProfileID[profileID] = .zoneFit(zoneID: .left)
        let target = try XCTUnwrap(service.targetFrame(for: fittedDestination, profile: context.profile, snapshot: context.snapshot)).frame
        XCTAssertEqual(restored.midX, target.midX, accuracy: 1)
        XCTAssertEqual(restored.maxY, target.maxY)
        XCTAssertEqual(restored.size, custom.size)
        XCTAssertEqual(service.assignCustomFrame(windows[2], to: .left, frame: restored), .saved)
        XCTAssertFalse(try current().fitsZone(in: profileID))
        XCTAssertEqual(service.tabSnapshots().first(where: { $0.zoneID == .left })?.sizeActions[assignments[2].id], .fit)
        // Existing workspace files without the optional memory still decode.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded)) as? [String: Any])
        json.removeValue(forKey: "savedCustomPlacementsByProfileID")
        XCTAssertThrowsError(try JSONDecoder().decode(WindowAssignment.self, from: JSONSerialization.data(withJSONObject: json)))
        store.removePlacementState(forProfileID: profileID)
        XCTAssertNil(try current().savedCustomPlacementsByProfileID[profileID])
    }

    func testCustomGeometryKeepsSizeAndClampsOnlyPositionToDisplay() {
        let source = CGRect(x: 100, y: 100, width: 400, height: 400)
        let custom = CGRect(x: 50, y: 300, width: 600, height: 200)
        let relative = ZoneCustomPlacementGeometry.capture(custom, in: source)
        XCTAssertEqual(relative.size, custom.size)
        XCTAssertEqual(relative.relativePosition, CGPoint(x: 0.25, y: 1))
        let destination = CGRect(x: -1000, y: 100, width: 200, height: 400)
        let display = CGRect(x: -1000, y: 0, width: 1000, height: 800)
        let target = ZoneCustomPlacementGeometry.frame(relative, in: destination, display: display)
        XCTAssertEqual(target, CGRect(x: -1000, y: 300, width: 600, height: 200))
        let bottomHalf = CGRect(x: 100, y: 300, width: 400, height: 200)
        let larger = CGRect(x: 600, y: 100, width: 900, height: 600)
        let moved = ZoneCustomPlacementGeometry.frame(ZoneCustomPlacementGeometry.capture(bottomHalf, in: source),
            in: larger, display: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        XCTAssertEqual(moved.size, bottomHalf.size)
        XCTAssertEqual(moved.midX, larger.midX)
        XCTAssertEqual(moved.maxY, larger.maxY)
        let oversized = SavedCustomPlacement(size: CGSize(width: 1200, height: 900), relativePosition: CGPoint(x: 1, y: 1))
        XCTAssertEqual(ZoneCustomPlacementGeometry.frame(oversized, in: destination, display: display).size, oversized.size)
    }

    func testCombinedPresentationChoicesPreserveZoneOptions() throws {
        for style in ZoneTabStyle.allCases {
            let original = Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs,
                                peekWidth: 80, peekDirection: .right,
                                tabStyle: style, tabBorderWidth: 12)
            for option in ZonePresentationOption.allCases {
                var zone = original
                option.apply(to: &zone)
                XCTAssertEqual(ZonePresentationOption(zone: zone), option)
                XCTAssertEqual(zone.peekWidth, original.peekWidth)
                XCTAssertEqual(zone.peekDirection, original.peekDirection)
                XCTAssertEqual(zone.tabBorderWidth, original.tabBorderWidth)
                if option == .overlap || option == .peekStack { XCTAssertEqual(zone.tabStyle, style) }
                XCTAssertEqual(try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(zone)), zone)
            }
        }
    }

    func testTabAppearanceRoundTripsAndSharedOwnerReflowsAllMembers() throws {
        for style in ZoneTabStyle.allCases {
            let zone = Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs,
                            tabStyle: style)
            XCTAssertEqual(try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(zone)), zone)
            var config = ZonalConfiguration.default
            config.profiles[0].zones = [zone, Zone(id: .left, name: "Left", frame: .full)]
            let before = config.profiles[0]
            config.profiles[0].zones[0].tabStyle = style == .frame ? .shelf : .frame
            XCTAssertEqual(ZoneReflowPolicy.changedZones(from: before, to: config.profiles[0]), [.main, .left])
            config.profiles[0] = before
            config.profiles.append(DisplayProfile(id: "new", name: "New", mainZoneID: .left,
                zones: [Zone(id: .left, name: "Left", frame: .full)]))
            XCTAssertEqual(ConfigurationEditor().sanitized(config).profiles.last?.zones.first { $0.id == .main }?.tabStyle, style)
        }
    }

    func testBorderDefaultsClampingAndPersistence() throws {
        var zone = Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs)
        XCTAssertEqual(zone.tabStyle, .frame)
        XCTAssertEqual(zone.tabBorderWidth, 7)
        XCTAssertEqual(ZoneTabStyle.allCases, [.shelf, .frame])
        for width in [0.0, 7, 24] {
            zone.tabBorderWidth = width
            XCTAssertEqual(try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(zone)), zone)
        }
        for (requested, expected) in [(-1.0, 0.0), (100, 24)] {
            zone.tabBorderWidth = requested
            XCTAssertEqual(try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(zone)).tabBorderWidth, expected)
        }
    }

    func testBorderChangeReflowsSharedMembersAndChangesBothDimensions() throws {
        var config = ZonalConfiguration.default
        config.profiles[0].zones = [Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs),
                                   Zone(id: .left, name: "Left", frame: .full)]
        let previous = config.profiles[0]
        config.profiles[0].zones[0].tabBorderWidth = 8
        XCTAssertEqual(ZoneReflowPolicy.changedZones(from: previous, to: config.profiles[0]), [.main, .left])
        XCTAssertTrue(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: {
            var old = config; old.profiles[0] = previous; return old
        }(), current: config))
        for edge in ZoneTabEdge.allCases {
            let zone = CGRect(x: 100, y: 100, width: 1000, height: 800)
            let before = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: 7).windowFrame
            let after = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: 8).windowFrame
            XCTAssertEqual(after.width, before.width - (edge.isVertical ? 3 : 2))
            XCTAssertEqual(after.height, before.height - (edge.isVertical ? 2 : 3))
            XCTAssertTrue(WindowPlacementGeometry().needsResize(from: before.size, to: after.size))
            XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: before, target: after))
        }
        config.profiles.append(DisplayProfile(id: "new", name: "New", mainZoneID: .left,
            zones: [Zone(id: .left, name: "Left", frame: .full)]))
        XCTAssertEqual(ConfigurationEditor().sanitized(config).profiles.last?.zones.first { $0.id == .main }?.tabBorderWidth, 8)
    }

    func testAppearanceSwitchUsesSameGeometryForProjectionAndRestoreWithoutChangingCustomWindows() throws {
        let (store, service, tracker, manager, _, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let display = manager.currentSnapshot()
        for style in ZoneTabStyle.allCases {
            for edge in ZoneTabEdge.allCases {
                for border in [0.0, 7, 24] {
                    var config = store.loadConfiguration()
                    config.profiles[0].zones[0].tabStyle = style
                    config.tabEdge = edge
                    config.profiles[0].zones[0].tabBorderWidth = border
                    XCTAssertTrue(store.saveConfiguration(config))
                    manager.reloadProfiles()
                    service.reconcile()
                    let projection = try XCTUnwrap(service.tabSnapshots().first)
                    XCTAssertEqual(projection.layout.style, style)
                    let target = try XCTUnwrap(service.targetFrame(for: assignments[0], profile: config.profiles[0], snapshot: display))
                    XCTAssertEqual(target.frame, projection.layout.windowFrame)
                    XCTAssertEqual(projection.layout.borderWidth, border)
                    XCTAssertEqual(service.targetFrame(for: assignments[2], profile: config.profiles[0], snapshot: display)?.frame,
                                   display.displays[0].placementFrame)
                }
            }
        }
    }

    func testFrameBackingStaysBehindFittedMemberDuringCustomFocusAndUnrelatedDrag() {
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 700, height: 500), edge: .bottom, style: .frame)
        let fitted = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        let custom = switcherItem(assignmentID: UUID(), windowID: 2, zoneID: .main)
        let fittedKey = OutlineWindowKey(pid: fitted.identity.processIdentifier!, number: 1)
        let customKey = OutlineWindowKey(pid: custom.identity.processIdentifier!, number: 2)
        let unrelatedKey = OutlineWindowKey(pid: 888, number: 3)
        let fittedRow = ZoneTabVisibleWindow(key: fittedKey, frame: layout.windowFrame)
        let customRow = ZoneTabVisibleWindow(key: customKey, frame: CGRect(x: 100, y: 100, width: 100, height: 100))
        let unrelated = ZoneTabVisibleWindow(key: unrelatedKey, frame: customRow.frame)
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout, items: [custom, fitted],
            fittedWindowIDs: [.quartz(processIdentifier: fittedKey.pid, windowNumber: 1)])
        let policy = ZoneTabVisibilityPolicy()
        XCTAssertEqual(policy.backingTarget(for: model, visible: [customRow, fittedRow], target: customKey, dragged: nil), fittedKey)
        XCTAssertEqual(policy.backingTarget(for: model, visible: [unrelated, customRow, fittedRow], target: customKey, dragged: unrelatedKey), fittedKey)
        XCTAssertEqual(policy.backingTarget(for: model, visible: [customRow, fittedRow, unrelated], target: customKey, dragged: unrelatedKey), unrelatedKey)
        XCTAssertEqual(policy.backingTarget(for: model, visible: [customRow, fittedRow], target: customKey, dragged: customKey), fittedKey)
    }

    func testBackingRemainsStableAcrossSameZoneSwitchesButRepairsOcclusion() {
        for style in [ZoneTabStyle.frame, .shelf] {
            let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 700, height: 500), edge: .bottom, style: style)
            let items = [1, 2].map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
            let rows = items.map { ZoneTabVisibleWindow(key: OutlineWindowKey(pid: $0.identity.processIdentifier!,
                number: $0.identity.cgWindowID!), frame: layout.windowFrame) }
            let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout, items: items)
            let panel = ZoneTabVisibleWindow(key: .init(pid: 900, number: 90), frame: model.panelFrame())
            let unrelated = ZoneTabVisibleWindow(key: .init(pid: 800, number: 80), frame: layout.windowFrame)
            let policy = ZoneTabVisibilityPolicy()
            func correct(_ visible: [ZoneTabVisibleWindow], anchor: OutlineWindowKey = rows[0].key) -> Bool {
                policy.backingIsCorrect(for: model, panelID: 90, anchor: anchor, visible: visible, ignoredWindowIDs: [])
            }
            XCTAssertEqual(policy.backingTarget(for: model, visible: [rows[0], panel, rows[1]],
                target: rows[0].key, dragged: nil, ignoredWindowIDs: [90]), rows[1].key)
            XCTAssertEqual(policy.backingTarget(for: model, visible: [rows[0], unrelated, rows[1], panel],
                target: rows[0].key, dragged: nil, ignoredWindowIDs: [90]), rows[0].key)
            XCTAssertTrue(correct([rows[0], panel, rows[1]]))
            XCTAssertTrue(correct([rows[1], rows[0], panel], anchor: rows[1].key))
            XCTAssertTrue(correct([rows[0], rows[1], panel]))
            XCTAssertFalse(correct([panel, rows[0], rows[1]]))
            XCTAssertFalse(correct([rows[0], unrelated, panel, rows[1]]))
            XCTAssertTrue(correct([unrelated, rows[0], rows[1], panel]))
            XCTAssertFalse(correct([rows[0], rows[1]]))
            var wrongLevel = panel
            wrongLevel.level = 1
            XCTAssertFalse(correct([rows[0], wrongLevel]))
            var custom = rows[1]
            custom.frame.size.width /= 2
            XCTAssertEqual(correct([rows[0], custom, panel]), style == .shelf)
        }
    }

    func testAllEdgesReserveOnlyTheirStripAndKeepSharedWindowFrame() {
        let zone = CGRect(x: -600, y: 24, width: 1000, height: 800)
        for edge in ZoneTabEdge.allCases {
            let layout = ZoneTabLayout(zoneFrame: zone, edge: edge, borderWidth: 0)
            XCTAssertEqual(layout.stripFrame.union(layout.windowFrame), zone)
            XCTAssertEqual(area(layout.stripFrame.intersection(layout.windowFrame)), 0)
            XCTAssertEqual(area(layout.stripFrame) + area(layout.windowFrame), area(zone))
            switch edge {
            case .top: XCTAssertEqual(layout.windowFrame.minY, zone.minY + 32)
            case .bottom: XCTAssertEqual(layout.stripFrame.maxY, zone.maxY)
            case .left: XCTAssertEqual(layout.windowFrame.minX, zone.minX + 144)
            case .right: XCTAssertEqual(layout.stripFrame.maxX, zone.maxX)
            }
        }
        for edge in ZoneTabEdge.allCases {
            let small = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 20, height: 20), edge: edge, borderWidth: 0)
            XCTAssertGreaterThanOrEqual(small.windowFrame.width, 1)
            XCTAssertGreaterThanOrEqual(small.windowFrame.height, 1)
        }
    }

    func testTabContinuityRejectsChangedLayoutMembershipAndObservedMovement() {
        let item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom,
            layout: ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 30, width: 1000, height: 800), edge: .bottom), items: [item])
        let key = OutlineWindowKey(pid: item.identity.processIdentifier!, number: 1)
        let policy = ZoneTabContinuityPolicy()
        func retain(_ current: ZoneTabSnapshot, now: TimeInterval = 10.1, visible: [ZoneTabVisibleWindow] = []) -> Bool {
            policy.canRetain(previous: model, current: current, target: key, visible: visible, lastConfirmedAt: 10, now: now)
        }
        XCTAssertTrue(retain(model))
        XCTAssertFalse(retain(model, now: 10.6), "No indefinite ghost bars after a failed read")
        var changed = model
        changed.layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 30, width: 700, height: 500), edge: .bottom)
        XCTAssertFalse(retain(changed), "Never retain ultrawide geometry on the laptop")
        changed = model; changed.edge = .top
        XCTAssertFalse(retain(changed))
        changed = model; changed.items = []
        XCTAssertFalse(retain(changed), "Confirmed removal or minimization invalidates cached membership")
        let moved = ZoneTabVisibleWindow(key: key, frame: CGRect(x: 1200, y: 30, width: 100, height: 100))
        XCTAssertFalse(retain(model, visible: [moved]))
        let occluder = ZoneTabVisibleWindow(key: .init(pid: 99, number: 99), frame: model.layout.stripFrame)
        XCTAssertFalse(retain(model, visible: [occluder]), "Stale backings must not paint over a fresh occluder")
        changed = model; changed.items[0].identity.cgWindowID = 2
        XCTAssertFalse(retain(changed), "An assignment rebound to a new window must not reuse the old generation")
    }

    func testTabPanelSurvivesLockAndBriefNativeReadGapButInvalidatesChangedDisplay() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        item.identity.processIdentifier = 999999
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom,
            layout: ZoneTabLayout(zoneFrame: CGRect(x: 100, y: 100, width: 600, height: 400), edge: .bottom), items: [item])
        var models = [model]
        var native: [ZoneTabVisibleWindow]? = [.init(key: .init(pid: 999999, number: 1), frame: model.layout.windowFrame)]
        var suspended = false
        var now: TimeInterval = 10
        var topology = DisplaySnapshot(displays: [.init(id: 1, frame: screen.frame, visibleFrame: screen.visibleFrame, scale: 1)])
        let controller = ZoneTabController(snapshots: { models }, focus: { _ in }, radiusQuery: { _ in 16 },
            isSuspended: { suspended }, visibleWindowQuery: { native }, uptime: { now }, displaySnapshotQuery: { topology })
        defer { controller.stop() }
        controller.refresh()
        let panel = try XCTUnwrap(controller.panels.first)
        let host = try XCTUnwrap(panel.contentView)
        let frame = panel.frame
        suspended = true
        controller.refresh()
        XCTAssertTrue(controller.panels.first === panel)
        XCTAssertFalse(panel.isVisible)
        now = 100; suspended = false
        controller.refresh()
        XCTAssertTrue(controller.panels.first === panel)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertTrue(panel.isVisible)
        native = nil; now += 0.1
        controller.refresh()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertTrue(panel.contentView === host)
        topology.displays[0].scale = 2
        controller.refresh()
        XCTAssertTrue(controller.panels.isEmpty, "A scale change invalidates stale geometry even inside the grace interval")
        native = [.init(key: .init(pid: 999999, number: 1), frame: model.layout.windowFrame)]
        controller.refresh()
        let replacement = try XCTUnwrap(controller.panels.first)
        native = nil; now += 0.6
        controller.refresh()
        XCTAssertFalse(replacement.isVisible)
        XCTAssertTrue(controller.panels.isEmpty)
        native = [.init(key: .init(pid: 999999, number: 1), frame: model.layout.windowFrame)]
        controller.refresh()
        models = []
        controller.refresh()
        XCTAssertTrue(controller.panels.isEmpty, "Disabling tabs or confirmed empty membership must remove the panel immediately")
    }

    func testUnchangedTabsDoNotRelayoutOrRereadCornerRadii() async throws {
        var item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        item.identity.processIdentifier = 999999
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom,
            layout: ZoneTabLayout(zoneFrame: CGRect(x: 100, y: 100, width: 600, height: 400), edge: .bottom), items: [item])
        var reads = 0
        var now: TimeInterval = 10
        let controller = ZoneTabController(snapshots: { [model] }, focus: { _ in },
            radiusQuery: { _ in reads += 1; return 16 },
            visibleWindowQuery: { [.init(key: .init(pid: 999999, number: 1), frame: model.layout.windowFrame)] },
            uptime: { now })
        defer { controller.stop() }
        controller.refresh()
        let host = try XCTUnwrap(controller.panels.first?.contentView as? ZoneTabHostingView)
        try await Task.sleep(for: .milliseconds(250))
        let passes = host.layoutPassCount
        for _ in 0..<60 { controller.refresh() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.contentUpdateCount, 1)
        XCTAssertEqual(controller.layoutCount, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertLessThanOrEqual(host.layoutPassCount - passes, 2, "An idle hosted tab must settle instead of negotiating layout forever")
        now += 2
        controller.refresh()
        XCTAssertEqual(reads, 2, "A slow fallback still detects native shape changes")
    }

    func testTabCornersRetainKnownRadiusWhileWindowServerShapeIsUnavailable() {
        var reported: CGFloat? = nil
        let controller = ZoneTabController(snapshots: { [] }, focus: { _ in }, radiusQuery: { _ in reported })
        let key = OutlineWindowKey(pid: 42, number: 1)
        XCTAssertEqual(controller.cornerRadius(for: key), 16)
        reported = 12
        XCTAssertEqual(controller.cornerRadius(for: key), 12, "Retry unknown shapes instead of caching the default forever")
        reported = 0
        XCTAssertEqual(controller.cornerRadius(for: key), 12)
        reported = nil
        XCTAssertEqual(controller.cornerRadius(for: key), 12)
        let replacement = OutlineWindowKey(pid: 42, number: 2)
        XCTAssertEqual(controller.cornerRadius(for: replacement, fallback: 12), 12)
        reported = 20
        XCTAssertEqual(controller.cornerRadius(for: replacement, fallback: 12), 20)
        reported = .nan
        XCTAssertEqual(controller.cornerRadius(for: replacement), 20)
    }

    func testLastDraggedMemberKeepsSourceTabBarAliveOutsideZone() {
        let item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        let snapshot = ZoneTabSnapshot(zoneID: .main, edge: .bottom,
            layout: ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), edge: .bottom), items: [item])
        let key = OutlineWindowKey(pid: 42, number: 1)
        let outside = ZoneTabVisibleWindow(key: key, frame: CGRect(x: 1200, y: 20, width: 400, height: 300))
        let dragged = LiveWindowID.quartz(processIdentifier: 42, windowNumber: 1)
        XCTAssertNil(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [outside]))
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [outside], draggedWindowID: dragged), key)
        XCTAssertNil(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [], draggedWindowID: dragged))
        XCTAssertNil(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [outside],
            draggedWindowID: .quartz(processIdentifier: 43, windowNumber: 1)))
    }

    func testTabPresentationRoundTrip() throws {
        var profile = DefaultProfiles.main
        profile.zones = [Zone(id: .left, name: "Notes", frame: .full, windowPresentation: .tabs),
                         Zone(id: .main, name: "Work", frame: .full, windowPresentation: .peekStack),
                         Zone(id: .right, name: "Reference", frame: .full, windowPresentation: .tabs)]
        var configuration = ZonalConfiguration.default
        configuration.profiles = [profile]
        configuration.behavior.outlinePulseMode = .off
        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(ZonalConfiguration.self, from: data), configuration)
        let newProfile = DisplayProfile(id: "new", name: "New", mainZoneID: .main, zones: [profile.zones[1]])
        configuration.profiles.append(newProfile)
        let sanitized = ConfigurationEditor().sanitized(configuration)
    }

    func testOutlinePulseModesRoundTrip() throws {
        for mode in OutlinePulseMode.allCases {
            var behavior = WindowBehaviorSettings()
            behavior.outlinePulseMode = mode
            let data = try JSONEncoder().encode(behavior)
            XCTAssertEqual(try JSONDecoder().decode(WindowBehaviorSettings.self, from: data), behavior)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["animateSwitcherFocus"])
        }

    }

    private final class Inventory {
        var windows: [ManagedWindow] = []
        var focusedWindow: ManagedWindow?
    }

    private func fixture(inventory: Inventory = Inventory()) throws -> (PersistenceStore, WorkspaceStateService, WindowTracker, ProfileManager, [ManagedWindow], [WindowAssignment]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zonal-tabs-\(UUID())")
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
        var config = store.loadConfiguration()
        config.profiles[0].zones = [Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs)]
        config.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        store.saveConfiguration(config)
        let windows = (1...4).map { index -> ManagedWindow in
            var window = managedWindow(cgWindowID: UInt32(index), observedOrder: index)
            window.element = AXUIElementCreateApplication(pid_t(100 + index))
            window.observedFrame = CGRect(x: 0, y: 56, width: 1600, height: 944)
            return window
        }
        var assignments = windows.map { WindowAssignment(id: UUID(), identity: $0.identity, zoneID: .main, updatedAt: Date()) }
        let profileID = config.profiles[0].id
        assignments[2].placementsByProfileID[profileID] = .custom(zoneID: .main, displayRoleID: .workspace,
            normalizedDisplayFrame: .full)
        assignments[3].managementMode = .ignored
        store.saveAssignments(assignments)
        inventory.windows = windows
        let registry = WindowRegistry(inventoryProvider: { complete in complete(inventory.windows, nil) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { inventory.focusedWindow })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker,
            windowController: WindowController(frameProvider: { $0.observedFrame }), store: store)
        service.start()
        return (store, service, tracker, manager, windows, assignments)
    }

    func testProjectionMatchesSwitcherMRUIncludesCustomExcludesIgnoredAndNeverWrites() throws {
        let (store, service, tracker, _, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        store.saveZoneStackState(ZoneStackState(globalRecency: [assignments[1].id, assignments[0].id, assignments[2].id],
            activeAssignmentByZone: [.main: assignments[1].id],
            assignmentRecencyByZone: [.main: [assignments[1].id, assignments[0].id, assignments[2].id]]))
        let bytes = try Data(contentsOf: store.workspaceURL)
        let tabs = try XCTUnwrap(service.tabSnapshots().first)
        let expected = service.switcherSnapshot(mode: .byZone).zones.first?.items
            .filter { [assignments[0].id, assignments[1].id, assignments[2].id].contains($0.assignmentID) }.map(\.assignmentID)
        XCTAssertEqual(tabs.items.map(\.assignmentID), expected)
        XCTAssertEqual(tabs.items.map(\.assignmentID), [assignments[1].id, assignments[0].id, assignments[2].id])
        XCTAssertTrue(tabs.hasFittedWindows)
        XCTAssertEqual(tabs.fittedWindowIDs, Set([windows[0].id, windows[1].id]))
        XCTAssertTrue(tabs.items[0].isActive)
        for _ in 0..<10 { _ = service.tabSnapshots() }
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
        store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [.main: assignments[0].id],
            assignmentRecencyByZone: [.main: [assignments[0].id, assignments[1].id]]))
        XCTAssertEqual(service.tabSnapshots().first?.items.first?.assignmentID, assignments[0].id)
        let beforeRecovery = service.tabSnapshots()
        let recoveryBytes = try Data(contentsOf: store.workspaceURL)
        XCTAssertTrue(service.beginSessionRecovery())
        XCTAssertEqual(service.tabSnapshots(), beforeRecovery, "Rendering need not wait for restore verification")
        XCTAssertTrue(service.isSessionRecoveryActive)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), recoveryBytes)
        service.finishSessionRecovery()
        let generation = service.beginDisplayTransition()
        XCTAssertEqual(service.tabSnapshots(), beforeRecovery)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), recoveryBytes)
        service.finishDisplayTransition(generation: generation)
        XCTAssertEqual(service.tabSnapshots().count, 1)
    }

    func testCustomOnlyZoneKeepsTabsWithoutBackingOverlapOrPlacementChange() throws {
        let inventory = Inventory()
        let (store, service, tracker, manager, _, assignments) = try fixture(inventory: inventory)
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        inventory.windows = [inventory.windows[2]]
        tracker.reconcile()
        let tabs = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(tabs.items.map(\.assignmentID), [assignments[2].id])
        XCTAssertFalse(tabs.hasFittedWindows)
        XCTAssertTrue(tabs.fittedWindowIDs.isEmpty)
        XCTAssertEqual(tabs.panelFrame(), tabs.layout.stripFrame.insetBy(dx: -12, dy: -12))
        XCTAssertEqual(service.targetFrame(for: assignments[2], profile: store.loadConfiguration().profiles[0], snapshot: manager.currentSnapshot())?.frame,
                       manager.currentSnapshot().displays[0].placementFrame)
    }

    func testRestoreTargetsAndReflowUseTabEdgeWithoutChangingCustomPlacement() throws {
        let (store, service, tracker, manager, _, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let snapshot = manager.currentSnapshot()
        var profile = store.loadConfiguration().profiles[0]
        for edge in ZoneTabEdge.allCases {
            var configuration = store.loadConfiguration()
            let old = configuration
            configuration.tabEdge = edge
            XCTAssertTrue(store.saveConfiguration(configuration))
            if old.tabEdge != edge {
                XCTAssertTrue(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: old, current: configuration))
            }
            let frame = try XCTUnwrap(service.targetFrame(for: assignments[0], profile: profile, snapshot: snapshot)).frame
            XCTAssertEqual(frame, ZoneTabLayout(zoneFrame: snapshot.displays[0].placementFrame, edge: edge).windowFrame)
            XCTAssertTrue(ZoneReflowPolicy.includes(assignments[0], zones: [.main], profile: profile))
            XCTAssertFalse(ZoneReflowPolicy.includes(assignments[2], zones: [.main], profile: profile))
            XCTAssertFalse(ZoneReflowPolicy.includes(assignments[3], zones: [.main], profile: profile))
            XCTAssertEqual(service.targetFrame(for: assignments[2], profile: profile, snapshot: snapshot)?.frame,
                           snapshot.displays[0].placementFrame)
        }
    }

    func testInventoryMetadataUpdatesTabsAndReflowsRestoredMinimizedMember() throws {
        let inventory = Inventory()
        let (store, service, tracker, _, _, _) = try fixture(inventory: inventory)
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var reflows: [ZoneID] = []
        service.onZonePresentationNeedsLayout = { reflows.append($0) }
        inventory.windows[0].isMinimized = true
        tracker.reconcile()
        XCTAssertEqual(reflows, [.main])
        reflows.removeAll()
        inventory.windows[0].isMinimized = false
        inventory.windows[0].title = "Restored editor"
        tracker.reconcile()
        XCTAssertEqual(reflows, [.main])
        XCTAssertTrue(service.tabSnapshots().first?.items.contains { $0.title == "Restored editor" } == true)
    }

    func testForemostFittedWindowIgnoresCustomMemberAndDraggedWindow() throws {
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 520, height: 400), edge: .bottom)
        let items = (1...3).map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
        let fittedIDs: Set<LiveWindowID> = [.quartz(processIdentifier: 42, windowNumber: 1),
                                           .quartz(processIdentifier: 42, windowNumber: 2)]
        let snapshot = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout, items: items, fittedWindowIDs: fittedIDs)
        let front = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 1), frame: layout.windowFrame)
        let back = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 2), frame: layout.windowFrame)
        let floating = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 3),
                                           frame: CGRect(x: 20, y: 330, width: 100, height: 70))
        let policy = ZoneTabVisibilityPolicy()
        let visible = [floating, front, back]
        let seam = try XCTUnwrap(policy.foremostFittedWindow(for: snapshot, visible: visible))
        XCTAssertEqual(seam.key, front.key)
        XCTAssertEqual(policy.foremostFittedWindow(for: snapshot, visible: [floating, back, front])?.key, back.key)
        XCTAssertEqual(policy.foremostFittedWindow(for: snapshot, visible: visible, excluding: front.key)?.key, back.key)

    }

    func testVisibilityRequiresExactVisibleMemberInZone() {
        let item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
        let snapshot = ZoneTabSnapshot(zoneID: .main, edge: .top,
            layout: ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), edge: .top), items: [item])
        let wrong = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 43, number: 1), frame: snapshot.layout.windowFrame)
        let offZone = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 1), frame: CGRect(x: -2000, y: 0, width: 100, height: 100))
        let right = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 1), frame: snapshot.layout.windowFrame)
        XCTAssertNil(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [wrong, offZone]))
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: snapshot, visible: [wrong, right]), right.key)
        XCTAssertNil(ZoneTabVisibilityPolicy().target(for: snapshot, visible: []))
        var stack = snapshot
        stack.items.append(switcherItem(assignmentID: UUID(), windowID: 2, zoneID: .main))
        let back = ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 2), frame: snapshot.layout.windowFrame)
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: stack, visible: [right, wrong, back]), right.key)
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: stack, visible: [back, right]), back.key)
    }

    func testMouseDownCommitsExactTabBeforeRecencyReordering() {
        let first = UUID(), second = UUID()
        let button = ZoneTabNativeButton()
        button.assignmentID = first
        var chosen: [UUID] = []
        button.focus = { id in chosen.append(id); button.assignmentID = second }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertTrue(button.acceptsFirstMouse(for: event), "An inactive tab panel must accept the first click")
        button.mouseDown(with: event)
        XCTAssertEqual(chosen, [first])
        XCTAssertFalse(button.acceptsFirstResponder)
    }

    func testTabClickCannotCancelItsOwnFocusRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistenceStore(supportDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ProfileManager(store: store)
        let registry = WindowRegistry()
        let controller = WindowController()
        let workspace = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: WindowTracker(registry: registry),
            windowController: controller, store: store)
        let observer = WindowMovementObserver(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowController: controller, workspaceState: workspace,
            overlayController: HotZoneOverlayController(), store: store)
        var pendingFocus = true
        var cancellations = 0
        observer.onMouseDown = { pendingFocus = false; cancellations += 1 }
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: -100_000, y: -100_000), mouseButton: .left))
        let button = ZoneTabNativeButton()
        button.assignmentID = UUID()
        button.focus = { _ in pendingFocus = true }
        let click = try XCTUnwrap(NSEvent(cgEvent: event))
        _ = observer.handleFromEventTap(type: .leftMouseDown, event: event)
        XCTAssertFalse(pendingFocus, "Cancel the earlier request before AppKit receives this click")
        button.mouseDown(with: click)
        await Task.yield()
        XCTAssertTrue(pendingFocus, "The deferred gesture lookup must not cancel the tab's new request")
        XCTAssertEqual(cancellations, 1)
        _ = observer.handleFromEventTap(type: .leftMouseDown, event: event)
        XCTAssertFalse(pendingFocus, "A later click must still interrupt pending focus")
        await Task.yield()
    }

    func testOutlinePulseStartsAtBasePeaksOnceAndCancelsWithoutChangingGeometry() async throws {
        let view = ActiveWindowOutlineView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let bounds = view.bounds
        view.startPulse()
        XCTAssertEqual(view.pulseStrength, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(view.pulseStrength, 0)
        XCTAssertLessThan(view.pulseStrength, 1)
        view.stopPulse()
        XCTAssertEqual(view.pulseStrength, 0)
        XCTAssertEqual(view.bounds, bounds)
        view.startPulse()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(view.pulseStrength, 0)
        XCTAssertEqual(view.pulseCount, 2)
    }

    func testConfirmationPulseHasOneFastPeakAndSteadyEndpoints() {
        let duration = OutlineConfirmationPulse.duration
        XCTAssertLessThanOrEqual(duration, 0.18)
        XCTAssertEqual(OutlineConfirmationPulse.strength(at: 0), 0)
        XCTAssertEqual(OutlineConfirmationPulse.strength(at: duration / 2), 1, accuracy: 0.001)
        XCTAssertEqual(OutlineConfirmationPulse.strength(at: duration), 0)
        XCTAssertEqual(OutlineConfirmationPulse.strength(at: duration * 2), 0)
        let strengths = (0...20).map { OutlineConfirmationPulse.strength(at: Double($0) * duration / 20) }
        for i in 1...10 { XCTAssertGreaterThan(strengths[i], strengths[i - 1]) }
        for i in 11...20 { XCTAssertLessThan(strengths[i], strengths[i - 1]) }
        let view = ActiveWindowOutlineView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        view.strokeColor = .systemPurple
        view.strokeWidth = 5
        view.startPulse()
        defer { view.stopPulse() }
        XCTAssertEqual(view.strokeColor, .systemPurple)
        XCTAssertEqual(view.strokeWidth, 5)
        XCTAssertEqual(view.alphaValue, 1)
    }

    func testOutlineSettingsProjectToTabsAndSwitcherWithoutChangingWorkspace() throws {
        let (store, service, tracker, _, _, _) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.activeWindowOutlineColor = .purple
        config.activeWindowOutlineWidth = 6
        config.showActiveWindowOutline = false
        store.saveConfiguration(config)
        let bytes = try Data(contentsOf: store.workspaceURL)
        let tabs = try XCTUnwrap(service.tabSnapshots().first)
        let switcher = service.switcherSnapshot(mode: .byZone)
        XCTAssertEqual(tabs.outlineStyle, switcher.outlineStyle)
        XCTAssertEqual(tabs.outlineStyle.color, .purple)
        XCTAssertEqual(switcher.outlineStyle.width, 6)
        XCTAssertEqual(tabs.outlineStyle.zoneWidth, 2)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
        config.activeWindowOutlineWidth = 1
        XCTAssertEqual(WindowOutlineStyle(configuration: config).zoneWidth, 1)
    }

    func testPulseRequiresConfirmedExactTargetAndRespectsSettingsAndReduceMotion() async throws {
        let store = PersistenceStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zonal-pulse-\(UUID())"))
        store.bootstrap()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory) }
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let key = OutlineWindowKey(pid: 42, number: 1)
        let controller = ActiveWindowOutlineController(store: store, radiusQuery: { _ in 10 },
            visibleFramesProvider: { [key: CGRect(x: 100, y: 100, width: 500, height: 400)] }, reduceMotion: { false })
        defer { controller.stop() }
        controller.update(window: window)
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.panel?.isVisible != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(controller.panel?.contentView as? ActiveWindowOutlineView)
        XCTAssertEqual(view.pulseCount, 0) // Ordinary focus never animates.
        controller.pulseAfterSwitcherFocus(managedWindow(cgWindowID: 2, observedOrder: 1))
        XCTAssertEqual(view.pulseCount, 0)
        controller.pulseAfterSwitcherFocus(window)
        XCTAssertEqual(view.pulseCount, 1)
        controller.cancelPulse()
        XCTAssertEqual(view.pulseStrength, 0)
        var configuration = store.loadConfiguration()
        configuration.behavior.outlinePulseMode = .off
        store.saveConfiguration(configuration)
        controller.pulseAfterSwitcherFocus(window)
        XCTAssertEqual(view.pulseCount, 1)
        configuration.behavior.outlinePulseMode = .switcherOnly
        store.saveConfiguration(configuration)
        controller.placementStarted(for: window.id)
        controller.pulseAfterSwitcherFocus(window)
        controller.update(window: nil)
        controller.placementSettled(for: window.id)
        XCTAssertEqual(view.pulseCount, 1) // A stale pending request cannot reappear.
        let reduced = ActiveWindowOutlineController(store: store, radiusQuery: { _ in 10 },
            visibleFramesProvider: { [key: CGRect(x: 100, y: 100, width: 500, height: 400)] }, reduceMotion: { true })
        defer { reduced.stop() }
        reduced.update(window: window)
        let reducedDeadline = ContinuousClock.now + .seconds(3)
        while reduced.panel?.isVisible != true, ContinuousClock.now < reducedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        reduced.pulseAfterSwitcherFocus(window)
        XCTAssertEqual((reduced.panel?.contentView as? ActiveWindowOutlineView)?.pulseCount, 0)
    }

    func testAllFocusedWindowsPulseOncePerFocusChangeWithoutDoubleSwitcherPulse() async throws {
        let store = PersistenceStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zonal-all-pulse-\(UUID())"))
        store.bootstrap()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory) }
        var configuration = store.loadConfiguration()
        configuration.behavior.outlinePulseMode = .allFocusedWindows
        store.saveConfiguration(configuration)
        let first = managedWindow(cgWindowID: 1, observedOrder: 0)
        let second = managedWindow(cgWindowID: 2, observedOrder: 1)
        let controller = ActiveWindowOutlineController(store: store, radiusQuery: { _ in 10 },
            visibleFramesProvider: {
                [OutlineWindowKey(pid: 42, number: 1): CGRect(x: 100, y: 100, width: 500, height: 400),
                 OutlineWindowKey(pid: 42, number: 2): CGRect(x: 200, y: 100, width: 500, height: 400)]
            }, reduceMotion: { false })
        defer { controller.stop() }
        func waitForPulse(_ count: Int) async throws -> ActiveWindowOutlineView {
            let deadline = ContinuousClock.now + .seconds(3)
            while (controller.panel?.contentView as? ActiveWindowOutlineView)?.pulseCount != count,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let view = try XCTUnwrap(controller.panel?.contentView as? ActiveWindowOutlineView)
            XCTAssertEqual(view.pulseCount, count)
            return view
        }
        controller.update(window: first)
        controller.placementStarted(for: first.id)
        controller.windowServerEvent(.moved(1))
        controller.placementVerified(for: first.id, frame: CGRect(x: 100, y: 100, width: 500, height: 400))
        controller.placementSettled(for: first.id)
        let view = try await waitForPulse(1)
        controller.update(window: first)
        controller.pulseAfterSwitcherFocus(first)
        XCTAssertEqual(view.pulseCount, 1)
        controller.update(window: second)
        _ = try await waitForPulse(2)
        controller.pulseAfterSwitcherFocus(second)
        XCTAssertEqual(view.pulseCount, 2)
        controller.update(window: nil)
        controller.update(window: first)
        _ = try await waitForPulse(3)
    }

    func testChangingPulseModeRejectsPendingOrdinaryFocusPulse() async throws {
        let store = PersistenceStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zonal-pending-pulse-\(UUID())"))
        store.bootstrap()
        defer { try? FileManager.default.removeItem(at: store.supportDirectory) }
        var configuration = store.loadConfiguration()
        configuration.behavior.outlinePulseMode = .allFocusedWindows
        store.saveConfiguration(configuration)
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let controller = ActiveWindowOutlineController(store: store, radiusQuery: { _ in 10 },
            visibleFramesProvider: { [OutlineWindowKey(pid: 42, number: 1): CGRect(x: 100, y: 100, width: 500, height: 400)] }, reduceMotion: { false })
        defer { controller.stop() }
        controller.update(window: window)
        configuration.behavior.outlinePulseMode = .switcherOnly
        store.saveConfiguration(configuration)
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.panel?.isVisible != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try XCTUnwrap(controller.panel?.contentView as? ActiveWindowOutlineView)
        XCTAssertEqual(view.pulseCount, 0)
        controller.pulseAfterSwitcherFocus(window)
        XCTAssertEqual(view.pulseCount, 1)
    }

    func testStripPanelIsTransparentAndCannotTakeKeyboardFocus() {
        let panel = ZoneTabController.makePanel()
        defer { panel.orderOut(nil) }
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testSharedTabSettingsAndOwnerRules() throws {
        var profile = DefaultProfiles.main
        let main = Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs)
        let left = Zone(id: .left, name: "Left", frame: .full)
        let right = Zone(id: .right, name: "Right", frame: .full, windowPresentation: .tabs)
        profile.zones = [left, right, main]
        XCTAssertEqual(ZoneTabGroupPolicy.owner(for: left, profile: profile)?.id, .main)
        XCTAssertEqual(ZoneTabGroupPolicy.owner(for: right, profile: profile)?.id, .main)
        let decoded = try JSONDecoder().decode(Zone.self, from: JSONEncoder().encode(main))
        XCTAssertEqual(decoded, main)

    }

    func testSharedProjectionUsesOneMRUTabPerOtherZoneAndKeepsEmptyOwner() throws {
        let inventory = Inventory()
        let (store, service, tracker, manager, _, original) = try fixture(inventory: inventory)
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones = [Zone(id: .left, name: "Left", frame: .full),
            Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs),
            Zone(id: .right, name: "Right", frame: .full)]
        store.saveConfiguration(config)
        var assignments = original
        assignments[1].zoneID = .left
        assignments[2].zoneID = .left
        assignments[2].placementsByProfileID[config.profiles[0].id] = .custom(zoneID: .left,
            displayRoleID: .workspace, normalizedDisplayFrame: .full)
        assignments[3].zoneID = .right
        assignments[3].managementMode = .managed
        store.saveAssignments(assignments)
        service.reconcile()
        store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [.left: assignments[2].id],
            assignmentRecencyByZone: [.left: [assignments[2].id, assignments[1].id]]))
        let bytes = try Data(contentsOf: store.workspaceURL)
        let tabs = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(service.tabSnapshots().count, 1)
        XCTAssertEqual(tabs.items.map(\.assignmentID), [assignments[0].id])
        XCTAssertEqual(tabs.otherZoneItems.map(\.assignmentID), [assignments[2].id, assignments[3].id])
        XCTAssertEqual(Set(tabs.orderingItems.map(\.assignmentID)), Set(assignments.map(\.id)))
        XCTAssertFalse((tabs.items + tabs.otherZoneItems).contains(where: \.isActive))
        for assignment in [assignments[0], assignments[1], assignments[3]] {
            XCTAssertEqual(service.targetFrame(for: assignment, profile: config.profiles[0], snapshot: manager.currentSnapshot())?.frame,
                           tabs.layout.windowFrame)
        }
        XCTAssertEqual(service.targetFrame(for: assignments[2], profile: config.profiles[0], snapshot: manager.currentSnapshot())?.frame,
                       manager.currentSnapshot().displays[0].placementFrame)
        for _ in 0..<10 { _ = service.tabSnapshots() }
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
        let orderedRows = [1, 3, 4, 2].map {
            ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: UInt32($0)), frame: tabs.layout.windowFrame)
        }
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: tabs, visible: orderedRows)?.number, 1)
        inventory.focusedWindow = inventory.windows[2]
        _ = tracker.captureFocusedWindow(origin: "shared-tab-test")
        let focusedTabs = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual((focusedTabs.items + focusedTabs.otherZoneItems).filter(\.isActive).map(\.assignmentID), [assignments[2].id])
        XCTAssertEqual(focusedTabs.items.map(\.assignmentID), [assignments[2].id, assignments[1].id])
        XCTAssertEqual(focusedTabs.otherZoneItems.map(\.assignmentID), [assignments[0].id, assignments[3].id])
        XCTAssertEqual(focusedTabs.zoneID, tabs.zoneID, "Keep the same panel identity when the primary zone changes")
        XCTAssertEqual(focusedTabs.layout, tabs.layout)
        inventory.focusedWindow = inventory.windows[3]
        _ = tracker.captureFocusedWindow(origin: "shared-tab-test")
        let rightTabs = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(rightTabs.items.map(\.assignmentID), [assignments[3].id])
        XCTAssertEqual(rightTabs.otherZoneItems.map(\.assignmentID), [assignments[2].id, assignments[0].id])
        inventory.focusedWindow = nil
        _ = tracker.captureFocusedWindow(origin: "shared-tab-test")
        let outsideFocus = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(outsideFocus.items.map(\.assignmentID), [assignments[3].id])
        let afterFocusBytes = try Data(contentsOf: store.workspaceURL)
        for _ in 0..<10 { _ = service.tabSnapshots() }
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), afterFocusBytes)
        inventory.windows.removeFirst()
        inventory.windows[1].isMinimized = true
        inventory.windows[2].isFullScreen = true
        tracker.reconcile()
        let emptyOwner = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(emptyOwner.items.map(\.assignmentID), [assignments[1].id])
        XCTAssertTrue(emptyOwner.otherZoneItems.isEmpty)
        XCTAssertTrue(emptyOwner.hasFittedWindows)
        let visible = [ZoneTabVisibleWindow(key: OutlineWindowKey(pid: 42, number: 2), frame: tabs.layout.windowFrame)]
        XCTAssertEqual(ZoneTabVisibilityPolicy().target(for: emptyOwner, visible: visible)?.number, 2)
    }

    func testSharedTabModesUseGlobalHistoryWithoutChangingAssignmentsOrPlacement() throws {
        let inventory = Inventory()
        let (store, service, tracker, _, _, original) = try fixture(inventory: inventory)
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        config.profiles[0].zones = [
            Zone(id: .main, name: "Main", frame: .full, windowPresentation: .tabs),
            Zone(id: .left, name: "Left", frame: .full),
            Zone(id: .right, name: "Right", frame: NormalizedFrame(x: 0, y: 0, width: 0.5, height: 1))
        ]
        store.saveConfiguration(config)
        var assignments = original
        assignments[1].zoneID = .left
        assignments[2].zoneID = .left
        assignments[3].zoneID = .right
        assignments[3].managementMode = .managed
        store.saveAssignments(assignments)
        service.reconcile()
        let ids = assignments.map(\.id)
        store.saveZoneStackState(ZoneStackState(globalRecency: [ids[3], ids[2], ids[0], ids[1]],
            activeAssignmentByZone: [.left: ids[2]],
            assignmentRecencyByZone: [.main: [ids[0]], .left: [ids[2], ids[1]]]))
        let workspace = try Data(contentsOf: store.workspaceURL)
        let originalTabs = try XCTUnwrap(service.tabSnapshots().first)
        for mode in OverlappingZoneTabs.allCases {
            config.overlappingZoneTabs = mode
            XCTAssertTrue(store.saveConfiguration(config))
            let tabs = try XCTUnwrap(service.tabSnapshots().first)
            XCTAssertEqual(tabs.zoneID, originalTabs.zoneID)
            XCTAssertEqual(tabs.layout, originalTabs.layout)
            XCTAssertEqual(tabs.fittedWindowIDs, originalTabs.fittedWindowIDs)
            XCTAssertEqual(Set(tabs.orderingItems.map(\.assignmentID)), Set(ids.prefix(3)))
            switch mode {
            case .currentZoneOnly:
                XCTAssertEqual(tabs.items.map(\.assignmentID), [ids[2], ids[1]])
                XCTAssertTrue(tabs.otherZoneItems.isEmpty)
            case .zoneShortcuts:
                XCTAssertEqual(tabs.items.map(\.assignmentID), [ids[2], ids[1]])
                XCTAssertEqual(tabs.otherZoneItems.map(\.assignmentID), [ids[0]])
            case .allWindows:
                XCTAssertEqual(tabs.items.map(\.assignmentID), [ids[2], ids[0], ids[1]])
                XCTAssertEqual(tabs.items.first?.zoneID, .left)
                XCTAssertTrue(tabs.otherZoneItems.isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: store.workspaceURL), workspace)
        }
        for index in [1, 2, 0] {
            inventory.focusedWindow = inventory.windows[index]
            _ = tracker.captureFocusedWindow(origin: "merged-tab-test")
        }
        let focused = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertEqual(focused.items.map(\.assignmentID), [ids[0], ids[2], ids[1]])
        XCTAssertEqual(focused.items.first?.zoneID, .main)
        XCTAssertEqual(focused.items.filter(\.isActive).map(\.assignmentID), [ids[0]])

        // Windows absent from history remain visible; other groups stay excluded.
        XCTAssertTrue(store.saveZoneStackState(ZoneStackState(globalRecency: [ids[3], ids[2]])))
        XCTAssertEqual(service.tabSnapshots().first?.items.map(\.assignmentID), [ids[0], ids[2], ids[1]])
        inventory.windows[1].isMinimized = true
        inventory.windows[2].isFullScreen = true
        tracker.reconcile()
        XCTAssertEqual(service.tabSnapshots().first?.items.map(\.assignmentID), [ids[0]])
    }

    func testTabHitTargetsFollowRecencyReordering() async throws {
        for fitted in [true, false] {
            let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 30, width: 700, height: 600), edge: .bottom)
            let original = (1...3).map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
            var model = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout, items: original,
                                        hasFittedWindows: fitted)
            let panel = ZoneTabController.makePanel()
            defer { panel.close() }
            panel.isReleasedWhenClosed = false
            panel.setFrame(CGRect(origin: CGPoint(x: 50, y: 50), size: model.panelFrame().size), display: false)
            let host = NSHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
            host.sizingOptions = []
            panel.contentView = host
            panel.orderFrontRegardless()
            func buttons(_ view: NSView) -> [ZoneTabNativeButton] {
                if let button = view as? ZoneTabNativeButton { return [button] }
                return view.subviews.flatMap(buttons)
            }
            for order in [[0, 1, 2], [1, 0, 2], [0, 1, 2], [1, 0, 2]] {
                model.items = order.map { original[$0] }
                host.rootView = ZoneTabStripView(snapshot: model, focus: { _ in })
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.clear.cgColor
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                for button in buttons(host) {
                    let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
                    let hit = host.hitTest(point)
                    // Global WindowServer hit regions need an isolated native run;
                    // parallel test windows can reorder between its two queries.
                    if ProcessInfo.processInfo.environment["ZONAL_LIVE_TAB_PROTOTYPE_CHECK"] == "1" {
                        let screenPoint = panel.convertPoint(toScreen: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
                        let rows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]])
                        let ids = rows.compactMap { $0[kCGWindowNumber as String] as? Int }
                        let index = try XCTUnwrap(ids.firstIndex(of: panel.windowNumber))
                        // Ignore unrelated windows above the fixture, including a locked test host.
                        let above = index > 0 ? ids[index - 1] : 0
                        XCTAssertEqual(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: above), panel.windowNumber,
                            "WindowServer must route the whole tab to its panel")
                    }
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                        "fitted=\(fitted) order=\(order) frame=\(button.convert(button.bounds, to: host)) hit=\(String(describing: hit))")
                }
                XCTAssertEqual(buttons(host).count, 3)
            }
        }
    }

    func testSharedStripPinsFixedWidthShortcutsAtFarEndOnAllEdges() throws {
        for edge in ZoneTabEdge.allCases {
            let size = edge.isVertical ? CGSize(width: 1000, height: 500) : CGSize(width: 700, height: 800)
            var own = (1...6).map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
            own[0].title = "Zonal — Main window"
            let others = [ZoneID.left, .right].enumerated().map { index, zone -> SwitcherItem in
                var item = switcherItem(assignmentID: UUID(), windowID: UInt32(index + 7), zoneID: zone)
                item.zoneName = index == 0 ? "Left" : "Right"
                item.title = "Reference window"
                return item
            }
            let layout = ZoneTabLayout(zoneFrame: CGRect(origin: .zero, size: size), edge: edge)
            let model = ZoneTabSnapshot(zoneID: .main, edge: edge, layout: layout, items: own,
                                       otherZoneItems: others, stackItems: own + others)
            let panel = ZoneTabController.makePanel()
            defer { panel.orderOut(nil) }
            panel.setFrame(CGRect(origin: .zero, size: layout.panelFrame(edge: edge).size), display: false)
            let host = NSHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
            host.sizingOptions = []
            panel.contentView = host
            host.frame = CGRect(origin: .zero, size: panel.frame.size)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            func buttons(_ view: NSView) -> [ZoneTabNativeButton] {
                if let button = view as? ZoneTabNativeButton { return [button] }
                return view.subviews.flatMap(buttons)
            }
            let right = try XCTUnwrap(buttons(host).first { $0.title.hasPrefix("Right ·") })
            let bounds = right.convert(right.bounds, to: host)
            XCTAssertEqual(bounds.height, 24, accuracy: 1, "The entire tab row must be clickable")
            let footprint = model.panelFrame()
            let strip = layout.stripFrame.offsetBy(dx: -footprint.minX, dy: -footprint.minY)
            if edge.isVertical {
                XCTAssertEqual(host.isFlipped ? bounds.maxY : bounds.minY,
                    host.isFlipped ? strip.maxY - layout.tabPadding : host.bounds.height - strip.maxY + layout.tabPadding, accuracy: 1)
            } else {
                XCTAssertEqual(bounds.maxX, strip.maxX - layout.tabPadding, accuracy: 1)
                XCTAssertEqual(bounds.width, 132, accuracy: 1)
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/zonal-overlap-tabs-\(edge.rawValue).png"))
        }
    }

}

@MainActor
private final class ZoneTabMenuTrackingObserver: NSObject {
    var sampled = false
    var timer: Timer?
    private var menu: NSMenu?
    private let check: () throws -> Void

    init(check: @escaping () throws -> Void) { self.check = check }

    @objc func began(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        self.menu = menu
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(sample), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func sample() {
        sampled = true
        do { try check() } catch { XCTFail("Menu ordering sample failed: \(error)") }
        menu?.cancelTracking()
        menu = nil
    }
}

private final class TabCloseAccess: AXCloseAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var element: AXUIElement?
    func close(_ request: AXCloseRequest) -> Bool {
        lock.withLock { element = request.element }
        return true
    }
    func matches(_ candidate: AXUIElement) -> Bool {
        lock.withLock { element.map { CFEqual($0, candidate) } ?? false }
    }
}
