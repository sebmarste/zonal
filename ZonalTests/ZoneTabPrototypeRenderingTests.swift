import AppKit
import SwiftUI
import XCTest
@testable import Zonal

@MainActor
final class ZoneTabPrototypeRenderingTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/tmp/zonal-tab-prototypes-rendering", isDirectory: true)
    private var exportsImages: Bool { ProcessInfo.processInfo.environment["ZONAL_TAB_SCREENSHOTS"] == "1" }

    func testAllStylesRenderWithClearCornersAndUnclippedShadows() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for style in ZoneTabStyle.allCases {
                for edge in ZoneTabEdge.allCases {
                    let model = snapshot(style: style, edge: edge)
                    let panel = model.panelFrame()
                    let bitmap = try render(ZoneTabStripView(snapshot: model, focus: { _ in }),
                                            size: panel.size, appearance: appearance)
                    let name = "\(style.rawValue)-\(edge.rawValue)-\(appearance == .darkAqua ? "dark" : "light")"
                    if exportsImages { try save(bitmap, name: name) }
                    func alpha(_ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
                        let px = min(bitmap.pixelsWide - 1, max(0, Int(x / panel.width * CGFloat(bitmap.pixelsWide))))
                        let py = min(bitmap.pixelsHigh - 1, max(0, Int(y / panel.height * CGFloat(bitmap.pixelsHigh))))
                        return try XCTUnwrap(bitmap.colorAt(x: px, y: py), name).alphaComponent
                    }
                    let strip = model.layout.stripFrame.offsetBy(dx: -panel.minX, dy: -panel.minY)
                    XCTAssertGreaterThan(try alpha(strip.midX, strip.midY), 0.99, name)
                    let surface = style == .shelf ? strip
                        : ZoneTabFrameGeometry(zoneFrame: model.layout.zoneFrame, edge: edge).localSurfaceFrame
                    for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: panel.width - 0.5, y: 0.5),
                                  CGPoint(x: 0.5, y: panel.height - 0.5),
                                  CGPoint(x: panel.width - 0.5, y: panel.height - 0.5),
                                  CGPoint(x: surface.midX, y: 0.5),
                                  CGPoint(x: surface.midX, y: panel.height - 0.5),
                                  CGPoint(x: 0.5, y: surface.midY),
                                  CGPoint(x: panel.width - 0.5, y: surface.midY)] {
                        XCTAssertLessThan(try alpha(point.x, point.y), 0.01, "Shadow must fade before panel boundary: \(name)")
                    }
                    let shadow = try alpha(surface.midX, surface.maxY + 2)
                    XCTAssertGreaterThan(shadow, 0.005, "Shadow must render outside the rounded surface: \(name)")
                    XCTAssertLessThan(shadow, 0.3, name)
                }
            }
        }
    }

    func testWriteSideBySideIllustrations() throws {
        guard exportsImages else { throw XCTSkip("Opt-in illustrations: TEST_RUNNER_ZONAL_TAB_SCREENSHOTS=1.") }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let models = ZoneTabStyle.allCases.map { snapshot(style: $0, edge: .bottom) }
            let preview = HStack(alignment: .top, spacing: 24) {
                ForEach(models, id: \.layout.style) { model in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.layout.style.title).font(.headline)
                        ZoneTabPrototypeIllustration(snapshot: model)
                    }
                }
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            let bitmap = try render(preview, size: CGSize(width: 1112, height: 424), appearance: appearance)
            try save(bitmap, name: "comparison-\(appearance == .darkAqua ? "dark" : "light")-illustration")
        }
    }

    func testLivePrototypeOrdering() async throws {
        try await runLivePrototypeFixtures(capture: false)
    }

    func testCaptureLivePrototypeCorners() async throws {
        guard exportsImages else { throw XCTSkip("Opt-in screenshots: TEST_RUNNER_ZONAL_TAB_SCREENSHOTS=1.") }
        try await runLivePrototypeFixtures(capture: true)
    }

    private func runLivePrototypeFixtures(capture: Bool) async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_TAB_PROTOTYPE_CHECK"] == "1" else {
            throw XCTSkip("Opt-in native fixtures: TEST_RUNNER_ZONAL_LIVE_TAB_PROTOTYPE_CHECK=1.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let backdropFrame = CGRect(x: screen.frame.minX + 30, y: screen.frame.minY + 60,
                                   width: min(1500, screen.frame.width - 60), height: min(620, screen.frame.height - 120))
        let backdrop = NSWindow(contentRect: backdropFrame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.6, blue: 0.57, alpha: 1)
        backdrop.orderFrontRegardless()
        var windows: [NSWindow] = []
        var models: [ZoneTabSnapshot] = []
        let cellWidth = (backdropFrame.width - 45) / 2
        for (index, style) in ZoneTabStyle.allCases.enumerated() {
            let appKitZone = CGRect(x: backdropFrame.minX + 15 + CGFloat(index) * (cellWidth + 15),
                                   y: backdropFrame.minY + 20, width: cellWidth, height: backdropFrame.height - 40)
            let zone = CGRect(x: appKitZone.minX, y: screen.frame.maxY - appKitZone.maxY,
                              width: appKitZone.width, height: appKitZone.height)
            let layout = ZoneTabLayout(zoneFrame: zone, edge: .bottom, style: style)
            let native = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            native.isReleasedWhenClosed = false
            native.title = style.title
            native.setFrame(WindowOutlineCoordinatePolicy().appKitFrame(for: layout.windowFrame, mainScreenFrame: screen.frame), display: false)
            native.contentView = NSHostingView(rootView: Text("Native window fixture").font(.title2)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            native.orderFrontRegardless()
            windows.append(native)
            let zoneID = ZoneID(rawValue: "prototype-\(index)")
            var item = switcherItem(assignmentID: UUID(), windowID: UInt32(native.windowNumber), zoneID: zoneID)
            item.identity.processIdentifier = ProcessInfo.processInfo.processIdentifier
            item.title = style.title
            item.isActive = true
            models.append(ZoneTabSnapshot(zoneID: zoneID, edge: .bottom, layout: layout, items: [item],
                fittedWindowIDs: [.quartz(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                          windowNumber: UInt32(native.windowNumber))]))
        }
        let controller = ZoneTabController(snapshots: { models }, focus: { _ in }, radiusQuery: { _ in 16 })
        defer { controller.stop(); windows.forEach { $0.close() }; backdrop.close() }
        controller.start()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.panels.count, ZoneTabStyle.allCases.count)
        func assertOrdering(dragged: NSWindow? = nil) throws {
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let visible = ZoneTabController.visibleWindows(rows)
            for panel in controller.panels {
                let host = try XCTUnwrap(panel.contentView as? NSHostingView<ZoneTabStripView>)
                let model = host.rootView.snapshot
                let panelIndex = try XCTUnwrap(visible.firstIndex { $0.key.number == UInt32(panel.windowNumber) })
                let memberIndex = try XCTUnwrap(visible.firstIndex { $0.key.number == model.items[0].identity.cgWindowID })
                XCTAssertGreaterThan(panelIndex, memberIndex, "\(model.layout.style): backing must stay beneath its fitted native member")
                if let dragged {
                    XCTAssertGreaterThan(panelIndex, try XCTUnwrap(visible.firstIndex { $0.key.number == UInt32(dragged.windowNumber) }), "\(model.layout.style): native drag must cover backing")
                }
                XCTAssertFalse(panel.isOpaque)
                XCTAssertFalse(panel.hasShadow)
            }
        }
        try assertOrdering()
        // A second fitted native member exercises real WindowServer restacking.
        let originalWindows = windows
        for index in models.indices {
            let alternate = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            alternate.isReleasedWhenClosed = false
            alternate.title = "Alternate member"
            alternate.setFrame(originalWindows[index].frame, display: false)
            var item = models[index].items[0]
            item.assignmentID = UUID()
            item.identity.cgWindowID = UInt32(alternate.windowNumber)
            models[index].items.append(item)
            models[index].fittedWindowIDs.insert(.quartz(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                                         windowNumber: UInt32(alternate.windowNumber)))
            alternate.orderFrontRegardless()
            windows.append(alternate)
        }
        // Let newly created native windows finish presentation before measuring switches.
        try await Task.sleep(for: .milliseconds(250))
        controller.refresh()
        for pass in 0..<6 {
            for index in models.indices {
                windows[index + (pass.isMultiple(of: 2) ? models.count : 0)].orderFrontRegardless()
            }
            try await Task.sleep(for: .milliseconds(30))
            controller.refresh()
            try await Task.sleep(for: .milliseconds(30))
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            let visible = ZoneTabController.visibleWindows(rows)
            for panel in controller.panels {
                let model = try XCTUnwrap(panel.contentView as? NSHostingView<ZoneTabStripView>).rootView.snapshot
                let panelIndex = try XCTUnwrap(visible.firstIndex { $0.key.number == UInt32(panel.windowNumber) })
                for item in model.items {
                    XCTAssertGreaterThan(panelIndex, try XCTUnwrap(visible.firstIndex { $0.key.number == item.identity.cgWindowID }),
                        "\(model.layout.style), pass \(pass): switching must leave backing beneath both members, without restacking between shadows")
                }
            }
        }
        let floating = NSWindow(contentRect: CGRect(x: backdropFrame.midX - 100, y: backdropFrame.midY - 80, width: 200, height: 160),
                                styleMask: [.titled], backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false
        floating.title = "Drag fixture"
        floating.orderFrontRegardless()
        defer { floating.close() }
        try await Task.sleep(for: .milliseconds(80))
        controller.windowDragChanged(.quartz(processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                            windowNumber: UInt32(floating.windowNumber)))
        // AppKit flushes panel ordering when control returns to the run loop.
        try await Task.sleep(for: .milliseconds(30))
        try assertOrdering(dragged: floating)
        floating.orderOut(nil)
        controller.windowDragChanged(nil)
        try await Task.sleep(for: .milliseconds(100))
        try assertOrdering()
        guard capture else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let rect = CGRect(x: backdropFrame.minX, y: screen.frame.maxY - backdropFrame.maxY,
                          width: backdropFrame.width, height: backdropFrame.height)
        capture.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))",
                             output.appendingPathComponent("native-fixtures.png").path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus != 0 { throw XCTSkip("Desktop capture is unavailable.") }
    }

    private func snapshot(style: ZoneTabStyle, edge: ZoneTabEdge) -> ZoneTabSnapshot {
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 520, height: 340), edge: edge, style: style)
        let items = (0..<3).map { index -> SwitcherItem in
            var item = switcherItem(assignmentID: UUID(), windowID: UInt32(index + 1), zoneID: .main)
            item.appName = ["Xcode", "Terminal", "Safari"][index]
            item.title = ["Zonal", "Tests", "Research"][index]
            item.icon = NSImage(systemSymbolName: ["hammer", "terminal", "globe"][index], accessibilityDescription: nil)
            item.isActive = index == 0
            return item
        }
        return ZoneTabSnapshot(zoneID: .main, edge: edge, layout: layout, items: items)
    }

    private func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let panel = ZoneTabController.makePanel()
        defer { panel.orderOut(nil) }
        panel.appearance = NSAppearance(named: appearance)
        panel.setFrame(CGRect(origin: .zero, size: size), display: false)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        host.sizingOptions = []
        panel.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}

// Illustration only: this does not validate foreign-window shadows or Window Server ordering.
private struct ZoneTabPrototypeIllustration: View {
    var snapshot: ZoneTabSnapshot

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.13, green: 0.6, blue: 0.57)
            tabs
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 7) {
                            ForEach([Color.red, .yellow, .green].indices, id: \.self) { index in
                                Circle().fill([Color.red, .yellow, .green][index]).frame(width: 10, height: 10)
                            }
                            Text("Native window illustration").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("A calmer workspace").font(.title2)
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.12))
                                .frame(width: CGFloat(240 - index * 35), height: 7)
                        }
                    }
                    .padding(18)
                }
                .shadow(color: .black.opacity(0.25), radius: 9, y: 3)
                .frame(width: snapshot.layout.windowFrame.width, height: snapshot.layout.windowFrame.height)
                .offset(x: snapshot.layout.windowFrame.minX, y: snapshot.layout.windowFrame.minY)
        }
        .frame(width: snapshot.layout.zoneFrame.width, height: snapshot.layout.zoneFrame.height, alignment: .topLeading)
    }

    private var tabs: some View {
        let panel = snapshot.panelFrame()
        return ZoneTabStripView(snapshot: snapshot, focus: { _ in })
            .frame(width: panel.width, height: panel.height)
            .offset(x: panel.minX, y: panel.minY)
    }
}
