import AppKit
import SwiftUI
import XCTest
@testable import Zonal

@MainActor
final class ZoneTabTests: XCTestCase {
    func testTabStripBackgroundMenuCoversBlankSpaceAndZoneIconButNotControls() throws {
        for edge in ZoneTabEdge.allCases {
            let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 800, height: 500), edge: edge, style: .shelf)
            let item = switcherItem(assignmentID: UUID(), windowID: 1, zoneID: .main)
            let model = ZoneTabSnapshot(zoneID: .main, edge: edge, layout: layout, items: [item])
            let panel = try XCTUnwrap(ZoneTabController.makePanel() as? ZoneTabPanel)
            panel.isReleasedWhenClosed = false
            defer { panel.close() }
            let menu = NSMenu(title: "Zonal")
            var menuRequests = 0
            panel.makeBackgroundMenu = { menuRequests += 1; return menu }
            let host = ZoneTabHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
            host.sizingOptions = []
            panel.contentView = host
            panel.setFrame(CGRect(origin: .zero, size: model.panelFrame().size), display: false)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let footprint = model.panelFrame()
            let strip = layout.stripFrame.offsetBy(dx: -footprint.minX, dy: -footprint.minY)
            // A point in strip padding cannot belong to a window or system control.
            let blank = CGPoint(x: strip.minX + 1, y: strip.midY)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(blank, from: host) ?? blank))
            XCTAssertTrue(hit is ZoneTabInputView)
            XCTAssertTrue(hit.shouldDelayWindowOrdering(for: event))
            XCTAssertTrue(panel.backgroundMenu(at: host.convert(blank, to: nil)) === menu)
            // The own-zone icon is at the leading end, ahead of the first window tab.
            let icon = CGPoint(x: strip.minX + layout.tabPadding + (edge.isVertical ? 50 : 12),
                               y: edge.isVertical ? strip.minY + layout.tabPadding + 12 : strip.midY)
            XCTAssertTrue(panel.backgroundMenu(at: host.convert(icon, to: nil)) === menu)
            XCTAssertTrue(host.hitTest(host.superview?.convert(icon, from: host) ?? icon) is ZoneTabInputView)
            XCTAssertNil(panel.backgroundMenu(at: host.convert(.zero, to: nil)), "Transparent effect outset must not open menus")
            func tabButtons(_ view: NSView) -> [ZoneTabNativeButton] {
                if let button = view as? ZoneTabNativeButton { return [button] }
                return view.subviews.flatMap(tabButtons)
            }
            let tab = try XCTUnwrap(tabButtons(host).first)
            let tabCenter = CGPoint(x: tab.bounds.midX, y: tab.bounds.midY)
            XCTAssertNil(panel.backgroundMenu(at: tab.convert(tabCenter, to: nil)))
            var withClock = model
            withClock.showsClock = true
            host.rootView = ZoneTabStripView(snapshot: withClock, focus: { _ in })
            host.layoutSubtreeIfNeeded()
            func clocks(_ view: NSView) -> [ZoneTabClockField] {
                if let field = view as? ZoneTabClockField { return [field] }
                return view.subviews.flatMap(clocks)
            }
            let clock = try XCTUnwrap(clocks(host).first)
            XCTAssertNil(panel.backgroundMenu(at: clock.convert(CGPoint(x: clock.bounds.midX, y: clock.bounds.midY), to: nil)))
            XCTAssertEqual(menuRequests, 2)
        }
    }

    func testSystemControlProfilesRoundTripAndOldAppearanceRemainsOptedOut() throws {
        let old = Data(#"{"edge":"top","showsNames":true,"overlappingTabs":"zoneShortcuts","showsClock":true}"#.utf8)
        let appearance = try JSONDecoder().decode(ProfileTabAppearance.self, from: old)
        XCTAssertNil(appearance.systemControls)
        var config = ZonalConfiguration.default
        var enabled = appearance
        enabled.systemControls = .init(isEnabled: true, items: [.network, .volume])
        config.profiles[0].tabAppearance = enabled
        var other = config.profiles[0]
        other.id = "native-bar-profile"
        other.tabAppearance = appearance
        config.profiles.append(other)
        let saved = try JSONDecoder().decode(ZonalConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(saved, config)
        XCTAssertNil(saved.profiles[1].tabAppearance?.systemControls)
        XCTAssertEqual(saved.profiles[0].tabAppearance?.systemControls?.visibleItems(hasBattery: true), [.volume, .network])
    }

    func testSystemControlOverflowKeepsEverySelectedItemAndHidesDesktopBattery() {
        let settings = SystemControlSettings(isEnabled: true, items: [.bluetooth, .volume, .network, .battery, .volume])
        let desktop = settings.visibleItems(hasBattery: false)
        XCTAssertEqual(desktop, [.volume, .bluetooth, .network])
        XCTAssertTrue(SystemControlSettings().visibleItems(hasBattery: true).isEmpty)
        for width: CGFloat in [0, 24, 52, 78, 130, 1000, .nan, .infinity] {
            let layout = SystemControlLayout(items: desktop, availableWidth: width, vertical: false)
            XCTAssertEqual(layout.direct + layout.overflow, desktop)
            XCTAssertLessThanOrEqual(layout.direct.count, 4)
        }
        XCTAssertEqual(SystemControlLayout(items: desktop, availableWidth: 62, vertical: false).direct, [.volume])
        let vertical = SystemControlLayout(items: desktop, availableWidth: 500, vertical: true)
        XCTAssertTrue(vertical.direct.isEmpty)
        XCTAssertEqual(vertical.overflow, desktop)
    }

    func testSystemControlsUseActualWidthsAndNeedNoRedundantZonalButton() {
        let items = SystemControlItem.allCases
        XCTAssertEqual(items, [.volume, .bluetooth, .network, .battery])
        let roomy = SystemControlLayout(items: items, availableWidth: 200, vertical: false)
        XCTAssertEqual(roomy.direct, items)
        XCTAssertTrue(roomy.overflow.isEmpty)
        let narrow = SystemControlLayout(items: items, availableWidth: 90, vertical: false)
        XCTAssertEqual(narrow.direct, [.volume, .bluetooth])
        XCTAssertEqual(narrow.overflow, [.network, .battery])
        XCTAssertGreaterThan(SystemControlItem.battery.controlWidth, SystemControlItem.network.controlWidth)
        let empty = SystemControlLayout(items: [], availableWidth: 200, vertical: false)
        XCTAssertTrue(empty.direct.isEmpty && empty.overflow.isEmpty)
    }

    func testSystemPanelPlacementKeepsFullFootprintOnDisplay() {
        let display = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        let size = CGSize(width: 320, height: 430)
        let top = CGRect(x: -800, y: 950, width: 28, height: 24)
        let below = SystemControlPanelGeometry.frame(anchor: top, surfaceSize: size, visible: display)
        XCTAssertTrue(display.contains(below))
        XCTAssertEqual(below.insetBy(dx: 40, dy: 40).maxY, top.minY - 8)
        let bottom = CGRect(x: -1590, y: 20, width: 28, height: 24)
        let above = SystemControlPanelGeometry.frame(anchor: bottom, surfaceSize: size, visible: display)
        XCTAssertTrue(display.contains(above))
        XCTAssertEqual(above.insetBy(dx: 40, dy: 40).minY, bottom.maxY + 8)
        let small = CGRect(x: 0, y: 0, width: 480, height: 300)
        XCTAssertTrue(small.contains(SystemControlPanelGeometry.frame(anchor: .zero, surfaceSize: size, visible: small)))
        XCTAssertEqual(LocalAutomationCommand(name: "system-controls-status", arguments: []), .systemControlsStatus)
        XCTAssertEqual(LocalAutomationCommand(name: "open-system-control", arguments: ["bluetooth"]), .openSystemControl(.bluetooth))
        if case .invalid = LocalAutomationCommand(name: "open-system-control", arguments: []) {} else { XCTFail("Require an explicit control") }
    }

    func testAudioIdentityRejectsReusedDeviceIDsAndMissingUIDs() {
        let target = SystemAudioOutput(id: 10, name: "Headphones", uid: "stable-uid")
        XCTAssertTrue(target.matchesIdentity(of: target))
        XCTAssertFalse(target.matchesIdentity(of: .init(id: 10, name: "Headphones", uid: "different-uid")))
        XCTAssertFalse(target.matchesIdentity(of: .init(id: 11, name: "Headphones", uid: "stable-uid")))
        XCTAssertFalse(SystemAudioOutput(id: 10, name: "Headphones").matchesIdentity(of: target))
        XCTAssertFalse(SystemAudioOutput(id: 10, name: "Headphones", uid: "").matchesIdentity(of: .init(id: 10, name: "Headphones", uid: "")))
    }

    func testBatteryDistinguishesExternalPowerAndChargedStates() {
        XCTAssertEqual(SystemBattery(percent: 70, charging: false, source: "Battery Power").status, "On battery")
        XCTAssertEqual(SystemBattery(percent: 80, charging: false, source: "AC Power").status, "Plugged in · Not charging")
        XCTAssertEqual(SystemBattery(percent: 100, charging: false, source: "AC Power").status, "Fully charged")
        XCTAssertEqual(SystemBattery(percent: 95, charging: false, source: "AC Power", fullyCharged: true).status, "Fully charged")
        XCTAssertEqual(SystemBattery(percent: 80, charging: true, source: "AC Power").status, "Charging")
        XCTAssertEqual(SystemBattery(percent: 80, charging: false).status, "Power source unavailable")
    }

    func testCustomPanelModelOpensCachedAndRefreshesBluetoothWithoutMainThreadWork() async throws {
        let probe = SystemPanelHardwareProbe()
        let model = SystemControlPanelModel(read: probe.read, perform: probe.perform)
        model.snapshot.network.connection = "Cached connection"
        model.start()
        defer { model.stop() }
        XCTAssertEqual(model.snapshot.network.connection, "Cached connection")
        XCTAssertTrue(model.refreshing)
        model.selected = .bluetooth
        model.refresh()
        for _ in 0..<100 where model.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.refreshing)
        XCTAssertEqual(probe.reads, [.network, .bluetooth])
        XCTAssertEqual(model.loadedKinds, [.network, .bluetooth])
        XCTAssertTrue(model.snapshot.outputs.isEmpty, "A Bluetooth read must not populate unrelated audio data")
        XCTAssertFalse(probe.usedMainThread)
        XCTAssertEqual(model.snapshot.network.connection, "Ethernet connected")
    }

    func testPanelRefreshKeepsOtherCachedControlsAndOnlyLoadsSelectedKind() async throws {
        let probe = SystemPanelHardwareProbe()
        let model = SystemControlPanelModel(read: probe.read, perform: probe.perform)
        model.snapshot = Self.systemPanelSample
        model.volumeDraft = 0.45
        for item in [SystemControlItem.battery, .volume, .network, .bluetooth] {
            let before = model.snapshot
            model.selected = item
            model.refresh()
            for _ in 0..<100 where model.refreshing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.refreshing)
            if item != .network { XCTAssertEqual(model.snapshot.network, before.network) }
            if item != .volume {
                XCTAssertEqual(model.snapshot.outputs, before.outputs)
                XCTAssertEqual(model.snapshot.outputID, before.outputID)
                XCTAssertEqual(model.snapshot.volume, before.volume)
            }
            if item != .battery { XCTAssertEqual(model.snapshot.battery, before.battery) }
            if item != .bluetooth { XCTAssertEqual(model.snapshot.bluetoothDevices, before.bluetoothDevices) }
        }
        XCTAssertEqual(model.snapshot.battery?.percent, 90)
        XCTAssertEqual(model.snapshot.volume, 0.6)
        XCTAssertEqual(model.volumeDraft, Double(Float(0.6)))
        XCTAssertEqual(model.snapshot.bluetoothDevices.first?.id, "mouse")
        XCTAssertEqual(probe.reads, [.battery, .volume, .network, .bluetooth])
        XCTAssertEqual(model.loadedKinds, Set(SystemControlItem.allCases))
        model.stop()
    }

    func testBluetoothSymbolsUseReportedDeviceClassAndFallbackForUnknownDevices() throws {
        for (major, minor, symbol): (UInt32, UInt32, String) in [
            (5, 0x10, "keyboard"), (5, 0x20, "computermouse"), (5, 0x30, "keyboard"),
            (5, 2, "gamecontroller"), (4, 6, "headphones"), (4, 5, "speaker.wave.2"),
            (4, 4, "mic"), (2, 0, "iphone"), (1, 3, "laptopcomputer"),
            (0, 0, "wave.3.right"), (31, 0, "wave.3.right")
        ] {
            XCTAssertEqual(SystemBluetoothDevice.symbol(major: major, minor: minor), symbol)
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil))
        }
    }

    func testBluetoothBatteryIdentityRejectsConflictingAndAmbiguousReadings() {
        typealias Reading = SystemBluetoothBatteryReading
        let address = "AA:BB:CC:DD:EE:01"
        let other = "aa-bb-cc-dd-ee-02"
        let exact = Reading(address: "aabbccddee01", name: "Mouse", percent: 0)
        let otherDevice = Reading(address: other, name: "Mouse", percent: 80)
        XCTAssertEqual(Reading.percent(in: [exact, otherDevice], address: address, name: "Mouse", uniqueName: false), 0)
        XCTAssertNil(Reading.percent(in: [otherDevice], address: address, name: "Mouse", uniqueName: true))
        let unnamed = Reading(address: nil, name: "Mouse", percent: 72)
        XCTAssertEqual(Reading.percent(in: [unnamed], address: address, name: "Mouse", uniqueName: true), 72)
        XCTAssertNil(Reading.percent(in: [unnamed], address: address, name: "Mouse", uniqueName: false))
        XCTAssertNil(Reading.percent(in: [unnamed, unnamed], address: address, name: "Mouse", uniqueName: true))
        XCTAssertNil(Reading.percent(in: [exact, .init(address: address, name: "Mouse", percent: 10)], address: address, name: "Mouse", uniqueName: true))
        XCTAssertNil(Reading.percent(in: [unnamed], address: "invalid", name: "Mouse", uniqueName: true))
        XCTAssertNil(Reading.address("AA:BB:CC:DD:EE:GG"))
    }

    func testBluetoothBatteryGettersCheckABIAndOmitUnknownPrivateValues() {
        let device = BluetoothBatteryProbe()
        XCTAssertEqual(SystemControlHardware.bluetoothPercent(device, selector: "batteryPercentLeft"), 72)
        XCTAssertNil(SystemControlHardware.bluetoothPercent(device, selector: "batteryPercentRight"), "Do not invoke a getter whose ABI changed")
        XCTAssertNil(SystemControlHardware.bluetoothPercent(device, selector: "missingBatteryGetter"))
        XCTAssertNil(SystemControlHardware.bluetoothPercent(device, selector: "batteryPercentSingle"), "Zero is ambiguous in the private getter")
        device.batteryPercentSingle = 255
        XCTAssertNil(SystemControlHardware.bluetoothPercent(device, selector: "batteryPercentSingle"))
        device.batteryPercentSingle = 100
        XCTAssertEqual(SystemControlHardware.bluetoothPercent(device, selector: "batteryPercentSingle"), 100)
        let earbuds = SystemBluetoothDevice(id: "earbuds", name: "Earbuds", connected: true, battery: nil,
                                           batteryLeft: 72, batteryRight: 18, batteryCase: 90)
        XCTAssertEqual(earbuds.batteryText, "72/18%")
        XCTAssertEqual(earbuds.batteryLevel, 18)
        XCTAssertEqual(earbuds.batteryHelp, "Left 72% · Right 18% · Case 90%")
    }

    func testBluetoothPowerActionShowsPendingStateAndRestoresReadbackOnFailure() async throws {
        let probe = SystemPanelHardwareProbe(error: "Power change unavailable")
        let model = SystemControlPanelModel(read: probe.read, perform: probe.perform)
        model.selected = .bluetooth
        model.snapshot.bluetoothPower = true
        model.act(.bluetoothPower(false)); model.act(.bluetoothPower(true))
        XCTAssertEqual(model.snapshot.bluetoothPower, false)
        XCTAssertTrue(model.pending)
        for _ in 0..<100 where model.pending || model.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.actionCount, 1)
        XCTAssertEqual(model.snapshot.bluetoothPower, true)
        XCTAssertEqual(model.error, "Power change unavailable")
        model.stop()
    }

    func testCustomPanelActionsDoNotDuplicateAndShowErrors() async throws {
        let probe = SystemPanelHardwareProbe(error: "Device is unavailable")
        let model = SystemControlPanelModel(read: probe.read, perform: probe.perform)
        model.act(.wifi(false)); model.act(.wifi(false))
        XCTAssertTrue(model.pending)
        for _ in 0..<100 where model.pending { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.actionCount, 1)
        XCTAssertEqual(model.error, "Device is unavailable")
        XCTAssertFalse(probe.usedMainThread)
        model.stop()
    }

    func testVolumeChangesCoalesceAndKeepLatestValue() async throws {
        let probe = SystemPanelHardwareProbe()
        let model = SystemControlPanelModel(read: probe.read, perform: probe.perform)
        model.snapshot = Self.systemPanelSample
        model.setVolume(0.2); model.setVolume(0.5); model.setVolume(0.8)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(probe.lastVolume, 0.8)
        XCTAssertEqual(probe.actionCount, 1)
        XCTAssertFalse(probe.usedMainThread)
        model.stop()
    }

    private static var systemPanelSample: SystemControlSnapshot {
        var state = SystemControlSnapshot()
        state.network = .init(interface: "en7", connection: "Ethernet connected", addresses: ["192.168.1.20", "fe80::20:abcd:ef01:2345%en7"],
                              wifiPower: true, ssid: "Home network", signal: -52, rate: 866)
        state.outputs = [.init(id: 1, name: "MacBook Pro Speakers", uid: "builtin", symbol: "laptopcomputer"),
                         .init(id: 2, name: "Headphones", uid: "headphones", symbol: "headphones"),
                         .init(id: 3, name: "External Display", uid: "display", symbol: "display"),
                         .init(id: 4, name: "USB Audio", uid: "usb", symbol: "speaker.wave.2")]
        state.outputID = 1; state.volume = 0.45; state.canSetVolume = true; state.canSetMute = true
        state.battery = .init(percent: 82, charging: false, source: "AC Power")
        state.bluetoothPower = true; state.canSetBluetoothPower = true
        state.bluetoothDevices = [.init(id: "paired-mouse", name: "Magic Mouse", connected: true, battery: 72, symbol: "computermouse"),
                                  .init(id: "paired-keyboard", name: "Magic Keyboard", connected: true, battery: 90, symbol: "keyboard"),
                                  .init(id: "paired-headphones", name: "Headphones", connected: false, symbol: "headphones"),
                                  .init(id: "paired-speaker", name: "Desk Speaker", connected: false, symbol: "speaker.wave.2"),
                                  .init(id: "paired-travel", name: "Travel Headphones", connected: false, symbol: "headphones")]
        return state
    }

    func testLiveSystemControlPanelDesignAndCompositing() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else { throw XCTSkip("Opt-in custom panel rendering fixture") }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let backdrop = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 350, y: screen.visibleFrame.midY - 300, width: 700, height: 650),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false; backdrop.backgroundColor = .systemOrange; backdrop.orderFrontRegardless()
        defer { backdrop.close() }
        let directory = URL(fileURLWithPath: "/private/tmp/zonal-system-panels")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = Self.systemPanelSample
        var many = sample
        many.bluetoothDevices = (1...80).map { .init(id: "device-\($0)", name: "Bluetooth device \($0)", connected: $0 < 3) }
        var charging = sample
        charging.battery = .init(percent: 64, charging: true, source: "AC Power", minutesToFull: 93)
        var earbuds = sample
        earbuds.bluetoothDevices = [.init(id: "earbuds", name: "AirPods", connected: true, battery: nil, symbol: "headphones", batteryLeft: 72, batteryRight: 18, batteryCase: 90)]
        let cases = SystemControlItem.allCases.map { ($0.rawValue, [$0], $0, sample) } + [
            ("bluetooth-many", [.bluetooth], .bluetooth, many),
            ("overflow", SystemControlItem.allCases, .bluetooth, sample),
            ("battery-charging", [.battery], .battery, charging),
            ("earbuds", [.bluetooth], .bluetooth, earbuds)
        ]
        func overflowingScrollViews(_ view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { scroll in
                scroll.documentView.map { $0.bounds.height > scroll.contentSize.height + 1 } == true ? [scroll] : []
            } ?? []
            return own + view.subviews.flatMap(overflowingScrollViews)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, items, item, state) in cases {
                let model = SystemControlPanelModel(read: { _ in state }, perform: { _ in nil })
                model.snapshot = state
                let controller = SystemControlPanels(model: model)
                controller.toggle(items: items, selected: item,
                                  anchor: CGRect(x: screen.visibleFrame.midX + 150, y: screen.visibleFrame.midY + 260, width: 28, height: 24))
                let panel = try XCTUnwrap(controller.panel)
                panel.appearance = NSAppearance(named: appearance)
                XCTAssertFalse(panel.isOpaque); XCTAssertFalse(panel.hasShadow); XCTAssertEqual(panel.backgroundColor, .clear)
                try await Task.sleep(for: .milliseconds(150))
                let host = try XCTUnwrap(panel.contentView)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
                XCTAssertEqual(overflowingScrollViews(host).isEmpty, name != "bluetooth-many", "Only long lists should need scrolling: \(name)")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                panel.cancelOperation(nil)
                XCTAssertNil(controller.panel)
            }
        }
    }

    func testLiveSystemPanelResizesAsContentChangesWithoutReopening() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else { throw XCTSkip("Opt-in content-sized panel fixture") }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var sample = Self.systemPanelSample
        sample.bluetoothDevices = Array(sample.bluetoothDevices.prefix(1))
        let initial = sample
        let model = SystemControlPanelModel(read: { _ in initial }, perform: { _ in nil })
        model.snapshot = initial
        let controller = SystemControlPanels(model: model)
        controller.toggle(items: [.bluetooth], selected: .bluetooth, anchor: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 20, width: 28, height: 20))
        defer { controller.close() }
        let panel = try XCTUnwrap(controller.panel)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.isVisible)
        let small = panel.frame.height
        model.snapshot.bluetoothDevices = Self.systemPanelSample.bluetoothDevices
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(panel.frame.height, small + 80)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        model.snapshot.bluetoothDevices = initial.bluetoothDevices
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(panel.frame.height, small, accuracy: 1)
        XCTAssertTrue(controller.panel === panel)
        controller.close()
        model.snapshot.bluetoothDevices = Self.systemPanelSample.bluetoothDevices
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible, "A late layout update must not reopen a dismissed panel")
        XCTAssertNil(controller.panel)
    }

    func testLiveBluetoothRowConnectsButOnlyDisconnectIconDisconnects() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else { throw XCTSkip("Opt-in Bluetooth hit-target fixture") }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var sample = Self.systemPanelSample
        sample.bluetoothDevices = [sample.bluetoothDevices[0], sample.bluetoothDevices[2]]
        let state = sample
        let probe = SystemPanelHardwareProbe()
        let model = SystemControlPanelModel(read: { _ in state }, perform: probe.perform)
        model.snapshot = state
        let controller = SystemControlPanels(model: model)
        controller.toggle(items: [.bluetooth], selected: .bluetooth, anchor: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 20, width: 28, height: 20))
        defer { controller.close() }
        let panel = try XCTUnwrap(controller.panel)
        try await Task.sleep(for: .milliseconds(200))
        func click(x: CGFloat, top: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: panel.frame.height - top),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.sendEvent(event)
            }
        }
        func settled() async throws {
            try await Task.sleep(for: .milliseconds(80))
            for _ in 0..<100 where model.pending || model.refreshing { try await Task.sleep(for: .milliseconds(10)) }
        }
        // Surface outset 40 + inset 14 + header 36 + gap 12 + content inset 1 + half-row 21.
        try click(x: 150, top: 124); try click(x: 78, top: 124)
        XCTAssertEqual(probe.actionCount, 0, "Connected names/icons stay passive")
        try click(x: 220, top: 174); try click(x: 220, top: 174)
        try await settled()
        XCTAssertEqual(probe.actionCount, 1, "The disconnected row connects once while pending")
        XCTAssertEqual(probe.lastBluetoothConnectedState, false)
        try click(x: 78, top: 174)
        try await settled()
        XCTAssertEqual(probe.actionCount, 2, "The disconnected icon also connects")
        try click(x: panel.frame.width - 79, top: 124)
        try await settled()
        XCTAssertEqual(probe.actionCount, 3)
        XCTAssertEqual(probe.lastBluetoothConnectedState, true, "Only the trailing icon disconnects")
    }

    func testSystemControlButtonsAlignFractionalFramesToBackingPixels() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: CGRect(x: 0.5, y: 0.5, width: 180, height: 36))
        try XCTUnwrap(window.contentView).addSubview(parent)
        let button = SystemControlNativeButton(frame: CGRect(x: 12.25, y: 5.25, width: 34, height: 24))
        parent.addSubview(button)
        for origin in [button.frame.origin, CGPoint(x: 18.75, y: 6.75)] {
            button.setFrameOrigin(origin)
            let backing = window.convertToBacking(button.convert(button.bounds, to: nil))
            XCTAssertEqual(backing.minX, backing.minX.rounded(), accuracy: 0.001)
            XCTAssertEqual(backing.minY, backing.minY.rounded(), accuracy: 0.001)
            XCTAssertEqual(button.frame.size, CGSize(width: 34, height: 24))
        }
    }

    func testSystemControlImagesShareTextBaselineAndFitHitTargets() throws {
        var images: [(NSImage, CGFloat)] = []
        for name in ["ethernet", "network", "wifi", "speaker.wave.1", "speaker.wave.2", "speaker.wave.3", "speaker.slash", "ellipsis"] {
            let width = ["ethernet", "network", "wifi"].contains(name) ? SystemControlItem.network.controlWidth
                : name == "ellipsis" ? 26 : SystemControlItem.volume.controlWidth
            images.append((try XCTUnwrap(SystemControlImages.symbol(name)), width))
        }
        images.append((SystemControlImages.bluetooth, SystemControlItem.bluetooth.controlWidth))
        images.append((SystemControlImages.disconnect, 28))
        let outline = try XCTUnwrap(NSImage(systemSymbolName: "battery.0percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: SystemControlImages.font.pointSize, weight: .regular, scale: .large)))
        for percent in [0, 8, 50, 100] {
            for charging in [false, true] {
                let image = SystemControlImages.battery(.init(percent: percent, charging: charging))
                XCTAssertEqual(image.size, CGSize(width: outline.size.width, height: outline.size.height + 2))
                XCTAssertEqual(image.alignmentRect, outline.alignmentRect.offsetBy(dx: 0, dy: 1))
                images.append((image, SystemControlItem.battery.controlWidth))
            }
        }
        for (image, width) in images {
            let cell = SystemControlButtonCell()
            cell.image = image
            let rect = cell.imageRect(forBounds: CGRect(x: 0, y: 0, width: width, height: 24))
            XCTAssertEqual(rect.midX, width / 2)
            XCTAssertEqual(rect.midY, 12, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxY, 24)
            XCTAssertGreaterThanOrEqual(width - image.size.width, 12, "Keep visible gaps without shrinking click targets")
            XCTAssertTrue(image.isTemplate)
            XCTAssertNotNil(image.tiffRepresentation)
        }
        if ProcessInfo.processInfo.environment["ZONAL_RENDER_SYSTEM_IMAGES"] == "1" { try renderSystemControlSamples() }
    }

    func testNetworkGlyphDistinguishesEthernetFromWiFiAndGenericConnections() {
        XCTAssertEqual(SystemControlMonitor.networkSymbol(connection: "Ethernet connected"), "ethernet")
        XCTAssertEqual(SystemControlMonitor.networkSymbol(connection: "Wi-Fi connected"), "wifi")
        XCTAssertEqual(SystemControlMonitor.networkSymbol(connection: "No network connection"), "wifi.slash")
        XCTAssertEqual(SystemControlMonitor.networkSymbol(connection: "Connected"), "network")
    }

    func testFullBatteryDoesNotShowChargingBolt() throws {
        let full = SystemControlImages.battery(.init(percent: 100, charging: false))
        let chargingFull = SystemControlImages.battery(.init(percent: 100, charging: true))
        XCTAssertEqual(try XCTUnwrap(full.tiffRepresentation), try XCTUnwrap(chargingFull.tiffRepresentation))
        let charging = SystemControlImages.battery(.init(percent: 64, charging: true))
        let idle = SystemControlImages.battery(.init(percent: 64, charging: false))
        XCTAssertNotEqual(try XCTUnwrap(charging.tiffRepresentation), try XCTUnwrap(idle.tiffRepresentation))
    }

    private func renderSystemControlSamples() throws {
        let output = URL(fileURLWithPath: "/private/tmp/zonal-icons")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rows: [(String, NSAppearance.Name, String, Int, Bool)] = [
            ("light", .aqua, "ethernet", 100, false), ("wifi-low", .aqua, "wifi", 8, false),
            ("charging", .aqua, "network", 64, true), ("dark", .darkAqua, "ethernet", 100, false),
            ("half", .aqua, "network", 50, false), ("charging-dark", .darkAqua, "network", 64, true),
            ("half-dark", .darkAqua, "network", 50, false),
            ("fractional", .aqua, "ethernet", 100, false), ("fractional-dark", .darkAqua, "ethernet", 100, false)
        ]
        for (name, appearance, network, percent, charging) in rows {
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 330, height: 34))
            let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = root
            root.wantsLayer = true
            window.appearance?.performAsCurrentDrawingAppearance { root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            let images = [try XCTUnwrap(SystemControlImages.symbol("speaker.wave.2")), SystemControlImages.bluetooth,
                          try XCTUnwrap(SystemControlImages.symbol(network)), SystemControlImages.battery(.init(percent: percent, charging: charging))]
            let offset: CGFloat = name.hasPrefix("fractional") ? 0.5 : 0
            var x: CGFloat = 12 + offset
            for (item, image) in zip(SystemControlItem.allCases, images) {
                let button = SystemControlNativeButton(frame: CGRect(x: x, y: 5 + offset, width: item.controlWidth, height: 24))
                button.cell = SystemControlButtonCell(); button.isBordered = false; button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone; button.font = SystemControlImages.font; button.contentTintColor = .labelColor
                button.image = image; root.addSubview(button); x += item.controlWidth
            }
            let clock = ZoneTabClockField(labelWithString: "Tue 17. Nov  11:00")
            clock.font = SystemControlImages.font; clock.sizeToFit()
            clock.setFrameOrigin(CGPoint(x: x + 9, y: (34 - clock.frame.height) / 2 + offset))
            root.addSubview(clock); root.layoutSubtreeIfNeeded()
            for scale in [1, 2, 4] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 330 * scale, pixelsHigh: 34 * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = root.bounds.size
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("\(name)-\(scale)x.png"))
            }
            window.close()
        }
    }

    func testDynamicBatteryAndVolumeIndicators() {
        XCTAssertEqual(SystemBattery(percent: 0, charging: false).symbol, "battery.0percent")
        XCTAssertEqual(SystemBattery(percent: 24, charging: false).symbol, "battery.25percent")
        XCTAssertEqual(SystemBattery(percent: 50, charging: false).symbol, "battery.50percent")
        XCTAssertEqual(SystemBattery(percent: 74, charging: false).symbol, "battery.75percent")
        XCTAssertEqual(SystemBattery(percent: 100, charging: false).symbol, "battery.100percent")
        XCTAssertEqual(SystemBattery(percent: 30, charging: true).symbol, "battery.100percent.bolt")
        XCTAssertEqual(SystemControlMonitor.volumeSymbol(level: 0.8, muted: true), "speaker.slash")
        XCTAssertEqual(SystemControlMonitor.volumeSymbol(level: 0, muted: false), "speaker.slash")
        XCTAssertEqual(SystemControlMonitor.volumeSymbol(level: 0.2, muted: false), "speaker.wave.1")
        XCTAssertEqual(SystemControlMonitor.volumeSymbol(level: 0.5, muted: false), "speaker.wave.2")
        XCTAssertEqual(SystemControlMonitor.volumeSymbol(level: 0.9, muted: false), "speaker.wave.3")
        XCTAssertTrue(SystemControlImages.bluetooth.isTemplate)
        XCTAssertEqual(SystemControlImages.bluetooth.size, CGSize(width: 9, height: 16))
    }

    func testSystemControlsFollowMainSharedStripWithoutWritingWorkspaceOrReflowingWindows() throws {
        let (store, service, tracker, manager, _, _) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let baseline = store.loadConfiguration()
        let before = service.tabSnapshots()
        let assignments = store.loadAssignments()
        var updated = baseline
        var appearance = updated.tabAppearance(for: updated.profiles[0])
        appearance.systemControls = .init(isEnabled: true, items: [.network, .bluetooth])
        updated.profiles[0].tabAppearance = appearance
        XCTAssertFalse(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: baseline, current: updated))
        XCTAssertTrue(store.saveConfiguration(updated))
        manager.reloadProfiles()
        let snapshots = service.tabSnapshots()
        XCTAssertEqual(snapshots.map(\.layout), before.map(\.layout))
        XCTAssertEqual(snapshots.first { $0.systemControls != nil }?.systemControls, appearance.systemControls)
        XCTAssertEqual(store.loadAssignments(), assignments)
        appearance.systemControls?.isEnabled = false
        updated.profiles[0].tabAppearance = appearance
        XCTAssertTrue(store.saveConfiguration(updated))
        XCTAssertFalse(service.tabSnapshots().contains { $0.systemControls?.isEnabled == true })
    }

    func testSystemBatteryPercentagesAndPassiveControlInput() {
        XCTAssertNil(SystemBattery.percentage(current: 10, maximum: 0))
        XCTAssertNil(SystemBattery.percentage(current: -1, maximum: 100))
        XCTAssertEqual(SystemBattery.percentage(current: 55, maximum: 110), 50)
        XCTAssertEqual(SystemBattery.percentage(current: 150, maximum: 100), 100)
        let button = SystemControlNativeButton()
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(button.needsPanelToBecomeKey)
        XCTAssertFalse(button.mouseDownCanMoveWindow)
        XCTAssertFalse(button.accessibilityPerformPress())
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let compact = ZoneTabClockLabel.text(for: date, compact: true, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertFalse(compact.contains("Nov"))
        XCTAssertFalse(compact.contains("\n"))
    }

    private static func nativeWindowOrder() -> [Int] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    @MainActor private final class MenuTrackingProbe: NSObject, NSMenuDelegate {
        var opened = false
        var sampled = false
        func menuWillOpen(_ menu: NSMenu) { opened = true }
    }

    @MainActor private final class ScrollProbeView: NSView {
        var receivedEvents: [NSEvent] = []
        override func scrollWheel(with event: NSEvent) { receivedEvents.append(event) }
    }

    func testPassiveTabInputPreservesScrollDelivery() throws {
        let input = ZoneTabInputView()
        let target = ScrollProbeView()
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: 16, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        input.scrollTarget = target
        input.scrollWheel(with: event)
        XCTAssertEqual(target.receivedEvents.count, 1)
        XCTAssertTrue(target.receivedEvents.first === event)
    }

    func testLiveSystemPopupKeepsBackingBelowWindowAndWhitespaceReceivesInput() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else {
            throw XCTSkip("Opt-in native system menu/input fixture")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let origin = CGPoint(x: screen.visibleFrame.midX - 380, y: screen.visibleFrame.midY - 190)
        let native = NSWindow(contentRect: CGRect(x: origin.x + 20, y: origin.y + 45, width: 720, height: 290),
                              styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        native.backgroundColor = .systemTeal
        native.orderFrontRegardless()
        defer { native.close() }
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 740, height: 360), edge: .bottom)
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout,
            items: [switcherItem(assignmentID: UUID(), windowID: UInt32(native.windowNumber), zoneID: .main)],
            systemControls: .init(isEnabled: true))
        let panel = ZoneTabController.makePanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = ZoneTabHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(CGRect(origin: origin, size: model.panelFrame().size), display: false)
        panel.order(.below, relativeTo: native.windowNumber)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        guard Self.nativeWindowOrder().contains(panel.windowNumber), Self.nativeWindowOrder().contains(native.windowNumber) else {
            throw XCTSkip("Native Window Server fixture is unavailable")
        }
        let footprint = model.panelFrame()
        let strip = layout.stripFrame.offsetBy(dx: -footprint.minX, dy: -footprint.minY)
        let blank = CGPoint(x: strip.midX, y: strip.midY)
        let screenPoint = panel.convertPoint(toScreen: host.convert(blank, to: nil))
        let orderBefore = Self.nativeWindowOrder()
        let panelIndex = try XCTUnwrap(orderBefore.firstIndex(of: panel.windowNumber))
        // Ignore unrelated windows above this isolated fixture, including a locked signing host.
        let above = panelIndex > 0 ? orderBefore[panelIndex - 1] : 0
        XCTAssertEqual(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: above), panel.windowNumber,
            "Whitespace must reach the panel instead of the desktop")
        func controls(_ view: NSView) -> [SystemControlNativeButton] {
            if let button = view as? SystemControlNativeButton { return [button] }
            return view.subviews.flatMap(controls)
        }
        let button = try XCTUnwrap(controls(host).first { $0.toolTip == "Volume" })
        XCTAssertEqual(button.items, [.volume])
        XCTAssertTrue(button.accessibilityPerformPress())
        defer { SystemControlPanels.shared.close() }
        let controlPanel = try XCTUnwrap(SystemControlPanels.shared.panel)
        XCTAssertFalse(controlPanel.isOpaque)
        XCTAssertFalse(controlPanel.hasShadow)
        try await Task.sleep(for: .milliseconds(200))
        let order = Self.nativeWindowOrder()
        let backingIndex = try XCTUnwrap(order.firstIndex(of: panel.windowNumber))
        let nativeIndex = try XCTUnwrap(order.firstIndex(of: native.windowNumber))
        let controlIndex = try XCTUnwrap(order.firstIndex(of: controlPanel.windowNumber))
        XCTAssertGreaterThan(backingIndex, nativeIndex, "Only the small control panel may rise above the current window")
        XCTAssertLessThan(controlIndex, nativeIndex)
        controlPanel.cancelOperation(nil)
        XCTAssertNil(SystemControlPanels.shared.panel)
    }

    func testLiveLeftClicksNeverRaiseTabBacking() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else {
            throw XCTSkip("Opt-in AppKit mouse dispatch/window ordering fixture")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let native = NSWindow(contentRect: CGRect(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.midY - 100,
                                                  width: 580, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        defer { native.close() }
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 600, height: 320), edge: .bottom)
        let model = ZoneTabSnapshot(zoneID: .main, edge: .bottom, layout: layout,
            items: [switcherItem(assignmentID: UUID(), windowID: UInt32(native.windowNumber), zoneID: .main)], showsClock: true)
        let panel = ZoneTabController.makePanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = ZoneTabHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(CGRect(x: screen.visibleFrame.midX - 310, y: screen.visibleFrame.midY - 140,
                              width: model.panelFrame().width, height: model.panelFrame().height), display: false)
        native.orderFrontRegardless()
        panel.order(.below, relativeTo: native.windowNumber)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let footprint = model.panelFrame()
        let strip = layout.stripFrame.offsetBy(dx: -footprint.minX, dy: -footprint.minY)
        for point in [CGPoint(x: strip.minX + 1, y: strip.midY),
                      CGPoint(x: strip.minX + layout.tabPadding + 12, y: strip.midY),
                      CGPoint(x: strip.midX, y: strip.midY)] {
            native.orderFrontRegardless()
            panel.order(.below, relativeTo: native.windowNumber)
            let location = host.convert(point, to: nil)
            let hit = try XCTUnwrap(host.hitTest(host.superview?.convert(location, from: nil) ?? location))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            XCTAssertTrue(hit.shouldDelayWindowOrdering(for: event), "Hit view \(type(of: hit)) must suppress implicit raising")
            for eventType: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let click = try XCTUnwrap(NSEvent.mouseEvent(with: eventType, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                NSApp.sendEvent(click)
                let order = Self.nativeWindowOrder()
                let backingIndex = try XCTUnwrap(order.firstIndex(of: panel.windowNumber))
                let nativeIndex = try XCTUnwrap(order.firstIndex(of: native.windowNumber))
                XCTAssertGreaterThan(backingIndex, nativeIndex, "Backing rose after \(eventType) on \(type(of: hit))")
            }
        }
    }

    func testLiveSystemControlsOverContrastingBackground() async throws {
        guard ProcessInfo.processInfo.environment["ZONAL_LIVE_SYSTEM_CONTROLS"] == "1" else {
            throw XCTSkip("Opt-in system-control runtime fixture; use TEST_RUNNER_ZONAL_LIVE_SYSTEM_CONTROLS=1.")
        }
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let origin = CGPoint(x: screen.visibleFrame.midX - 450, y: screen.visibleFrame.midY - 170)
        let background = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 900, height: 340)),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        background.isReleasedWhenClosed = false
        background.backgroundColor = NSColor(calibratedRed: 0.2, green: 0.65, blue: 0.6, alpha: 1)
        background.orderFrontRegardless()
        defer { background.close() }
        let width: CGFloat = 860
        let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: width, height: 260), edge: .top, style: .shelf)
        let items = (1...5).map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
        let snapshot = ZoneTabSnapshot(zoneID: .main, edge: .top, layout: layout, items: items,
            showsClock: true, systemControls: .init(isEnabled: true))
        let panel = ZoneTabController.makePanel()
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: ZoneTabStripView(snapshot: snapshot, focus: { _ in }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(CGRect(origin: CGPoint(x: origin.x + 8, y: origin.y + 210), size: snapshot.panelFrame().size), display: false)
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        func buttons(_ view: NSView) -> [SystemControlNativeButton] {
            if let button = view as? SystemControlNativeButton { return [button] }
            return view.subviews.flatMap(buttons)
        }
        let controls = buttons(host)
        XCTAssertGreaterThanOrEqual(controls.count, 3)
        for button in controls {
            let bounds = button.convert(button.bounds, to: host)
            XCTAssertTrue(host.bounds.contains(bounds))
            XCTAssertGreaterThan(bounds.width, 20)
        }
        // Preserve the actual AppKit-hosted rendering even on a host without desktop capture.
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.lockFocus()
        NSColor(calibratedRed: 0.2, green: 0.65, blue: 0.6, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: image.size)
            .draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/private/tmp/zonal-system-controls-rendered.png"))
        for edge in ZoneTabEdge.allCases {
            let compactLayout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: 300, height: 280), edge: edge, style: .shelf)
            let compact = ZoneTabSnapshot(zoneID: .main, edge: edge, layout: compactLayout, items: items,
                showsClock: true, systemControls: .init(isEnabled: true))
            panel.setFrame(CGRect(origin: panel.frame.origin, size: compact.panelFrame().size), display: false)
            host.rootView = ZoneTabStripView(snapshot: compact, focus: { _ in })
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(buttons(host).isEmpty)
            for button in buttons(host) {
                XCTAssertTrue(host.bounds.contains(button.convert(button.bounds, to: host)), "Controls escaped \(edge)")
            }
        }
        panel.setFrame(CGRect(origin: CGPoint(x: origin.x + 8, y: origin.y + 210), size: snapshot.panelFrame().size), display: false)
        host.rootView = ZoneTabStripView(snapshot: snapshot, focus: { _ in })
        host.layoutSubtreeIfNeeded()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(origin.x)),\(Int(screen.frame.maxY - origin.y - 340)),900,340", "/private/tmp/zonal-system-controls-live.png"]
        try capture.run(); capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw XCTSkip("Desktop capture unavailable") }
    }

    func testProfileSwitchRestoresSpacingTabsAndClockWithoutChangingOtherProfile() throws {
        let (store, service, tracker, manager, _, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var config = store.loadConfiguration()
        let baseline = config.profiles[0]
        var alternate = baseline
        alternate.id = "alternate"
        alternate.zoneSpacing = 6
        alternate.tabAppearance = .init(edge: .left, showsNames: false, overlappingTabs: .allWindows, showsClock: true)
        config.profiles.append(alternate)
        for id in [alternate.id, baseline.id, alternate.id] {
            config.activeProfileID = id
            XCTAssertTrue(store.saveConfiguration(config))
            manager.reloadProfiles(); service.reconcile()
            let current = manager.selectedProfile(for: manager.currentSnapshot())
            let appearance = config.tabAppearance(for: current)
            let bounds = LayoutEngine().zoneFrame(for: current.zones[0], in: manager.currentSnapshot().displays[0].placementFrame, spacing: current.zoneSpacing)
            let expected = ZoneTabLayout(zoneFrame: bounds, edge: appearance.edge, style: current.zones[0].tabStyle).windowFrame
            let tabs = try XCTUnwrap(service.tabSnapshots().first)
            XCTAssertEqual(tabs.edge, appearance.edge)
            XCTAssertEqual(tabs.showsNames, appearance.showsNames)
            XCTAssertEqual(tabs.showsClock, appearance.showsClock)
            XCTAssertEqual(tabs.layout.windowFrame, expected)
            XCTAssertEqual(service.targetFrame(for: assignments[0], profile: current, snapshot: manager.currentSnapshot())?.frame, expected)
        }
        XCTAssertEqual(store.loadConfiguration().profiles[0], baseline)
    }

    func testRedundantFittedFrameNotificationPreservesSpacingIntentButRealResizeIsCustom() throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let profile = manager.selectedProfile(for: manager.currentSnapshot())
        let target = try XCTUnwrap(service.targetFrame(for: assignments[0], profile: profile, snapshot: manager.currentSnapshot()))
        XCTAssertEqual(service.recordCustomFrame(for: windows[0], frame: target.frame), .saved)
        let fitted = try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[0].id })
        XCTAssertTrue(fitted.fitsZone(in: profile.id))
        let custom = target.frame.insetBy(dx: 100, dy: 100)
        XCTAssertEqual(service.recordCustomFrame(for: windows[0], frame: custom), .saved)
        XCTAssertFalse(try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[0].id }).fitsZone(in: profile.id))
    }

    func testDelayedFrameCaptureCannotWriteOldGeometryIntoNewProfile() async throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        tracker.onWindowFrameChanged?(windows[0])
        var config = store.loadConfiguration()
        var alternate = config.profiles[0]
        alternate.id = "alternate"
        alternate.zoneSpacing = 16
        config.profiles.append(alternate)
        config.activeProfileID = alternate.id
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles(); service.reconcile()
        try await Task.sleep(for: .milliseconds(650))
        let saved = try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[0].id })
        XCTAssertNil(saved.placementsByProfileID[alternate.id])
        XCTAssertTrue(saved.fitsZone(in: alternate.id))
    }

    func testProfileAppearanceFallsBackToExistingGlobalSettings() throws {
        var configuration = ZonalConfiguration.default
        configuration.tabEdge = .bottom
        configuration.tabShowsNames = false
        configuration.behavior.showMainStackClock = true
        let profile = configuration.profiles[0]
        let saved = try JSONDecoder().decode(ZonalConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertNil(saved.profiles[0].tabAppearance)
        XCTAssertEqual(saved.tabAppearance(for: profile), .init(edge: .bottom, showsNames: false, overlappingTabs: .zoneShortcuts, showsClock: true))
        var customized = profile
        customized.tabAppearance = .init(edge: .right, showsNames: true, overlappingTabs: .currentZoneOnly, showsClock: false)
        XCTAssertEqual(configuration.tabAppearance(for: customized), customized.tabAppearance)
        XCTAssertTrue(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: configuration, current: {
            var updated = configuration; updated.profiles[0] = customized; return updated
        }()))
        // Appearance-only changes do not alter zone geometry; the container compares effective tab edges.
        XCTAssertTrue(ZoneReflowPolicy.changedZones(from: profile, to: customized).isEmpty)
    }

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
        XCTAssertTrue(controller.visibilityState.contains("reason=session-suspended"))
        now = 100; suspended = false
        controller.refresh()
        XCTAssertTrue(controller.panels.first === panel)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.visibilityState.contains("reason=presented"))
        let transitionCount = controller.detailedDiagnosticLines().filter { $0.hasPrefix("tab.visibility ") }.count
        controller.refresh()
        XCTAssertEqual(controller.detailedDiagnosticLines().filter { $0.hasPrefix("tab.visibility ") }.count, transitionCount,
                       "Unchanged refreshes must not spam the visibility log")
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
        XCTAssertTrue(controller.visibilityState.contains("reason=no-models"))
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

    private func fixture(inventory: Inventory = Inventory(), reportsFocus: Bool = false) throws -> (PersistenceStore, WorkspaceStateService, WindowTracker, ProfileManager, [ManagedWindow], [WindowAssignment]) {
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
        let registry = WindowRegistry(inventoryProvider: { complete in
            complete(inventory.windows, reportsFocus ? inventory.focusedWindow?.element : nil)
        })
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

    func testTabVisibilityRecoversWhenSameFocusedWindowLeavesFullScreenDuringWakeScan() throws {
        let inventory = Inventory()
        let (store, service, tracker, _, _, _) = try fixture(inventory: inventory, reportsFocus: true)
        defer { service.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        inventory.windows[0].isFullScreen = true
        inventory.focusedWindow = inventory.windows[0]
        tracker.reconcile()
        _ = tracker.captureFocusedWindow(origin: "before-sleep")
        XCTAssertTrue(service.tabSnapshots().isEmpty)
        XCTAssertTrue(service.tabSnapshotDiagnostic.contains("reason=focused-full-screen"))
        let focusedID = tracker.focusedWindowID
        var focusEvents = 0
        let onFocusChanged = tracker.onFocusChanged
        tracker.onFocusChanged = { window in focusEvents += 1; onFocusChanged?(window) }
        XCTAssertTrue(service.beginSessionRecovery())
        inventory.windows[0].isFullScreen = false
        inventory.focusedWindow = inventory.windows[0]
        tracker.reconcile()
        service.finishSessionRecovery()
        XCTAssertEqual(tracker.focusedWindowID, focusedID)
        XCTAssertEqual(focusEvents, 0, "Wake can update presentation without another focus event")
        XCTAssertFalse(service.tabSnapshots().isEmpty, "Tabs must return without switching apps")
        XCTAssertTrue(service.tabSnapshotDiagnostic.contains("reason=ready"))
        inventory.windows[0].isFullScreen = true
        inventory.focusedWindow = inventory.windows[0]
        tracker.reconcile()
        XCTAssertTrue(service.tabSnapshots().isEmpty, "Actual full-screen windows must still hide tabs")
    }

    func testFocusCallbackSeesCurrentFullScreenState() throws {
        let inventory = Inventory()
        let (store, service, tracker, _, _, _) = try fixture(inventory: inventory)
        defer { service.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        inventory.windows[1].isFullScreen = true
        tracker.reconcile()
        var snapshotsAtFocus: [ZoneTabSnapshot] = []
        service.onFocusedWindowChanged = { _ in snapshotsAtFocus = service.tabSnapshots() }
        inventory.focusedWindow = inventory.windows[1]
        _ = tracker.captureFocusedWindow(origin: "enter-full-screen")
        XCTAssertTrue(snapshotsAtFocus.isEmpty, "Refresh callbacks must not render the previous focus state")
        inventory.focusedWindow = inventory.windows[0]
        _ = tracker.captureFocusedWindow(origin: "leave-full-screen")
        XCTAssertFalse(snapshotsAtFocus.isEmpty)
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
        config.behavior.showMainStackClock = true
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
        XCTAssertTrue(tabs.showsClock)
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
        XCTAssertTrue(focusedTabs.showsClock)
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

    func testProfileClockRefreshReadsLatestAppearanceWithoutReconciliation() throws {
        let (store, service, tracker, _, _, _) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let original = try XCTUnwrap(service.tabSnapshots().first)
        var config = store.loadConfiguration()
        let baseline = config
        config.profiles[0].tabAppearance = config.tabAppearance(for: config.profiles[0])
        config.profiles[0].tabAppearance?.showsClock = true
        XCTAssertFalse(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: baseline, current: config))
        XCTAssertTrue(store.saveConfiguration(config))
        let visible = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertTrue(visible.showsClock)
        XCTAssertEqual(visible.layout, original.layout)
        XCTAssertEqual(visible.fittedWindowIDs, original.fittedWindowIDs)
        config.profiles[0].tabAppearance?.showsClock = false
        XCTAssertTrue(store.saveConfiguration(config))
        XCTAssertFalse(try XCTUnwrap(service.tabSnapshots().first).showsClock)
    }

    func testClockOnlyAppearsInMainGroupAndTogglesWithoutChangingPlacement() throws {
        let (store, service, tracker, _, _, _) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let original = try XCTUnwrap(service.tabSnapshots().first)
        XCTAssertFalse(original.showsClock)
        var config = store.loadConfiguration()
        config.behavior.showMainStackClock = true
        store.saveConfiguration(config)
        XCTAssertTrue(try XCTUnwrap(service.tabSnapshots().first).showsClock)
        XCTAssertEqual(service.tabSnapshots().first?.layout, original.layout)
        config.profiles[0].mainZoneID = .left
        config.profiles[0].zones.append(Zone(id: .left, name: "Main elsewhere",
            frame: NormalizedFrame(x: 0, y: 0, width: 0.5, height: 1)))
        store.saveConfiguration(config)
        service.reconcile()
        XCTAssertFalse(try XCTUnwrap(service.tabSnapshots().first).showsClock)
        config.profiles[0].mainZoneID = .main
        config.behavior.showMainStackClock = false
        store.saveConfiguration(config)
        service.reconcile()
        XCTAssertFalse(try XCTUnwrap(service.tabSnapshots().first).showsClock)
    }

    func testClockIncludesLocalizedDateTimeAndRollsOverAtMidnight() throws {
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US_POSIX")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T23:59:00Z"))
        let before = ZoneTabClockLabel.text(for: date, locale: locale, timeZone: utc)
        XCTAssertTrue(before.contains("Thu"))
        XCTAssertTrue(before.contains("Nov"))
        XCTAssertTrue(before.contains("5"))
        XCTAssertTrue(before.contains(":59"))
        let after = ZoneTabClockLabel.text(for: date.addingTimeInterval(60), locale: locale, timeZone: utc)
        XCTAssertTrue(after.contains("Fri"))
        XCTAssertTrue(after.contains("6"))
        XCTAssertTrue(after.contains(":00"))
        let vertical = ZoneTabClockLabel.text(for: date, stacked: true, locale: locale, timeZone: utc)
        XCTAssertEqual(vertical.components(separatedBy: "\n").count, 2)
        let german = ZoneTabClockLabel.text(for: date, locale: Locale(identifier: "de_DE"), timeZone: utc)
        XCTAssertTrue(german.contains("23:59"))
        XCTAssertNotEqual(german, before)
    }

    func testClockFitsInsideNarrowAndWideStripsOnEveryEdge() throws {
        func labels(in view: NSView) -> [NSTextField] {
            if let label = view as? NSTextField, label.accessibilityIdentifier() == "main-stack-clock" { return [label] }
            return view.subviews.flatMap { labels(in: $0) }
        }
        for edge in ZoneTabEdge.allCases {
            for width: CGFloat in [240, 700] {
                let layout = ZoneTabLayout(zoneFrame: CGRect(x: 0, y: 0, width: width, height: 400), edge: edge)
                let own = (1...6).map { switcherItem(assignmentID: UUID(), windowID: UInt32($0), zoneID: .main) }
                let peer = switcherItem(assignmentID: UUID(), windowID: 7, zoneID: .left)
                let model = ZoneTabSnapshot(zoneID: .main, edge: edge, layout: layout, items: own,
                    otherZoneItems: [peer], showsClock: true)
                let panel = ZoneTabController.makePanel()
                defer { panel.orderOut(nil) }
                panel.setFrame(CGRect(origin: .zero, size: layout.panelFrame(edge: edge).size), display: false)
                let host = NSHostingView(rootView: ZoneTabStripView(snapshot: model, focus: { _ in }))
                host.sizingOptions = []
                panel.contentView = host
                host.frame = CGRect(origin: .zero, size: panel.frame.size)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let label = try XCTUnwrap(labels(in: host).first)
                let passive = try XCTUnwrap(label as? ZoneTabClockField)
                XCTAssertFalse(passive.acceptsFirstResponder)
                XCTAssertFalse(passive.needsPanelToBecomeKey)
                XCTAssertFalse(passive.mouseDownCanMoveWindow)
                XCTAssertFalse(passive.isSelectable)
                XCTAssertFalse(passive.isEditable)
                let responder = panel.firstResponder
                for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
                    XCTAssertTrue(passive.acceptsFirstMouse(for: event))
                    XCTAssertTrue(passive.shouldDelayWindowOrdering(for: event))
                    switch type {
                    case .leftMouseDown: passive.mouseDown(with: event)
                    case .rightMouseDown: passive.rightMouseDown(with: event)
                    default: passive.otherMouseDown(with: event)
                    }
                }
                XCTAssertTrue(panel.firstResponder === responder)
                XCTAssertFalse(panel.isKeyWindow)
                XCTAssertEqual(labels(in: host).count, 1)
                XCTAssertFalse(label.stringValue.isEmpty)
                XCTAssertEqual(label.stringValue.contains("\n"), edge.isVertical)
                XCTAssertFalse(panel.canBecomeKey)
                let clockBounds = label.convert(label.bounds, to: host)
                XCTAssertGreaterThan(clockBounds.width, 20)
                XCTAssertGreaterThanOrEqual(clockBounds.minX, 0)
                XCTAssertLessThanOrEqual(clockBounds.maxX, host.bounds.maxX)
                let trailingEdge = layout.stripFrame.maxX - layout.panelFrame(edge: edge).minX - layout.tabPadding
                XCTAssertLessThanOrEqual(clockBounds.maxX, trailingEdge)
                XCTAssertGreaterThanOrEqual(clockBounds.maxX, trailingEdge - 12)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: "/tmp/zonal-clock-\(edge.rawValue)-\(Int(width)).png"))
                host.rootView = ZoneTabStripView(snapshot: ZoneTabSnapshot(zoneID: .main, edge: edge,
                    layout: layout, items: own), focus: { _ in })
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(labels(in: host).isEmpty)
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


extension ZoneTabTests {
    func testLayoutEditDiscardsPendingManualFrameCapture() async throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var window = windows[0]
        window.observedFrame = CGRect(x: 90, y: 100, width: 800, height: 600)
        tracker.onWindowFrameChanged?(window)
        var config = store.loadConfiguration()
        config.profiles[0].zoneSpacing = 16
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        try await Task.sleep(for: .milliseconds(650))
        let saved = try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[0].id })
        XCTAssertTrue(saved.fitsZone(in: config.profiles[0].id))
    }

    func testTabActionDeclinesUnavailableWindowsAndRecoveryWithoutSaving() throws {
        let inventory = Inventory()
        let (store, service, tracker, manager, _, assignments) = try fixture(inventory: inventory)
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        let engine = RestoreEngine(profileManager: manager, windowRegistry: WindowRegistry(),
            windowTracker: tracker, windowController: WindowController(frameProvider: { $0.observedFrame }),
            workspaceState: service, store: store)
        let bytes = try Data(contentsOf: store.workspaceURL)
        XCTAssertFalse(engine.isTabPresentationSuspended)
        XCTAssertNotNil(service.currentProfileContext().assignments.first { $0.id == assignments[0].id })
        inventory.windows[0].isMinimized = true
        tracker.reconcile()
        XCTAssertFalse(engine.performTabAction(assignmentID: assignments[0].id, action: .fit))
        inventory.windows[0].isMinimized = false
        inventory.windows[0].isFullScreen = true
        tracker.reconcile()
        XCTAssertFalse(engine.performTabAction(assignmentID: assignments[0].id, action: .fit))
        inventory.windows[0].isFullScreen = false
        tracker.reconcile()
        XCTAssertTrue(service.beginSessionRecovery())
        XCTAssertFalse(engine.performTabAction(assignmentID: assignments[0].id, action: .fit))
        XCTAssertFalse(engine.performTabAction(assignmentID: UUID(), action: .fit))
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testCosmeticProfileEditDoesNotDiscardPendingManualFrameCapture() async throws {
        let (store, service, tracker, manager, windows, assignments) = try fixture()
        defer { service.stop(); tracker.stop(); try? FileManager.default.removeItem(at: store.supportDirectory) }
        var window = windows[0]
        window.observedFrame = CGRect(x: 90, y: 100, width: 800, height: 600)
        tracker.onWindowFrameChanged?(window)
        var config = store.loadConfiguration()
        config.profiles[0].name = "Renamed while dragging"
        var appearance = config.tabAppearance(for: config.profiles[0]); appearance.showsClock.toggle()
        config.profiles[0].tabAppearance = appearance
        XCTAssertTrue(store.saveConfiguration(config))
        manager.reloadProfiles()
        try await Task.sleep(for: .milliseconds(650))
        let saved = try XCTUnwrap(store.loadAssignments().first { $0.id == assignments[0].id })
        XCTAssertFalse(saved.fitsZone(in: config.profiles[0].id))
    }
}

private final class SystemPanelHardwareProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readRequests: [SystemControlItem] = []
    private var actions = 0
    private var onMain = false
    private var volume: Float?
    private var bluetoothConnectedState: Bool?
    private let failure: String?
    init(error: String? = nil) { failure = error }
    var reads: [SystemControlItem] { lock.withLock { readRequests } }
    var actionCount: Int { lock.withLock { actions } }
    var usedMainThread: Bool { lock.withLock { onMain } }
    var lastVolume: Float? { lock.withLock { volume } }
    var lastBluetoothConnectedState: Bool? { lock.withLock { bluetoothConnectedState } }
    func read(_ item: SystemControlItem) -> SystemControlSnapshot {
        lock.withLock { readRequests.append(item); onMain = onMain || Thread.isMainThread }
        Thread.sleep(forTimeInterval: 0.03)
        var value = SystemControlSnapshot()
        value.network.connection = "Ethernet connected"
        value.outputs = [.init(id: 1, name: "Speakers", uid: "builtin")]
        value.outputID = 1; value.volume = 0.6
        value.battery = .init(percent: 90, charging: true, source: "AC Power")
        value.bluetoothPower = true
        value.bluetoothDevices = [.init(id: "mouse", name: "Mouse", connected: true)]
        return value
    }
    func perform(_ action: SystemControlAction) -> String? {
        lock.withLock {
            actions += 1; onMain = onMain || Thread.isMainThread
            if case .volume(_, let value) = action { volume = value }
            if case .bluetooth(let device) = action { bluetoothConnectedState = device.connected }
        }
        Thread.sleep(forTimeInterval: 0.03)
        return failure
    }
}

private final class BluetoothBatteryProbe: NSObject {
    @objc var batteryPercentSingle: UInt8 = 0
    @objc var batteryPercentLeft: UInt8 = 72
    @objc var batteryPercentRight: Int32 = 88
}
