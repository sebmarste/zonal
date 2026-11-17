import AppKit
import CoreWLAN
import IOBluetooth
import IOKit
import IOKit.ps
import OSLog
import ObjectiveC
import SwiftUI
import SystemConfiguration

struct SystemNetworkState: Equatable, Sendable {
    var interface = ""
    var connection = "Checking connection…"
    var addresses: [String] = []
    var wifiPower: Bool?
    var ssid: String?
    var signal: Int?
    var rate: Int?
}

struct SystemBluetoothDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var connected: Bool
    var battery: Int?
    var symbol = "wave.3.right"
    var batteryLeft: Int? = nil
    var batteryRight: Int? = nil
    var batteryCase: Int? = nil

    var batteryLevel: Int? { [batteryLeft, batteryRight].compactMap { $0 }.min() ?? battery ?? batteryCase }
    var batteryText: String? {
        if let left = batteryLeft, let right = batteryRight { return "\(left)/\(right)%" }
        if let percent = battery ?? batteryLeft ?? batteryRight { return "\(percent)%" }
        return batteryCase.map { "Case \($0)%" }
    }
    var batteryHelp: String {
        var parts: [String] = []
        if let battery { parts.append("Battery \(battery)%") }
        if let batteryLeft { parts.append("Left \(batteryLeft)%") }
        if let batteryRight { parts.append("Right \(batteryRight)%") }
        if let batteryCase { parts.append("Case \(batteryCase)%") }
        return parts.isEmpty ? "Battery level unavailable" : parts.joined(separator: " · ")
    }

    static func symbol(major: UInt32, minor: UInt32) -> String {
        switch major {
        case 1: return minor == 3 ? "laptopcomputer" : "desktopcomputer"
        case 2: return "iphone"
        case 4:
            switch minor {
            case 1, 2, 6: return "headphones"
            case 4: return "mic"
            case 5, 7, 10: return "speaker.wave.2"
            default: break
            }
        case 5:
            switch minor & 0x30 {
            case 0x10, 0x30: return "keyboard"
            case 0x20: return "computermouse"
            default:
                if [1, 2].contains(minor & 0x0f) { return "gamecontroller" }
            }
        default: break
        }
        return "wave.3.right"
    }
}

struct SystemControlSnapshot: Equatable, Sendable {
    var network = SystemNetworkState()
    var outputs: [SystemAudioOutput] = []
    var outputID: UInt32 = 0
    var volume: Float?
    var muted = false
    var canSetVolume = false
    var canSetMute = false
    var battery: SystemBattery?
    var lowPower = false
    var bluetoothPower: Bool?
    var canSetBluetoothPower = false
    var bluetoothDevices: [SystemBluetoothDevice] = []
}

enum SystemControlAction: Sendable {
    case wifi(Bool)
    case bluetoothPower(Bool)
    case bluetooth(SystemBluetoothDevice)
    case output(SystemAudioOutput)
    case mute(SystemAudioOutput, Bool)
    case volume(SystemAudioOutput, Float)
}

// All device discovery and potentially blocking actions run on the model's serial worker.
enum SystemControlHardware {
    static func snapshot(for item: SystemControlItem) -> SystemControlSnapshot {
        var result = SystemControlSnapshot()
        switch item {
        case .network: result.network = networkState()
        case .volume:
            result.outputs = SystemAudio.outputs()
            result.outputID = SystemAudio.output
            result.volume = SystemAudio.volume(result.outputID)
            result.muted = SystemAudio.muted(result.outputID)
            result.canSetVolume = SystemAudio.canSetVolume(result.outputID)
            result.canSetMute = SystemAudio.canSetMute(result.outputID)
        case .battery:
            result.battery = SystemControlMonitor.readBattery()
            result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        case .bluetooth:
            return bluetoothState()
        }
        return result
    }

    private static func networkState() -> SystemNetworkState {
        var result = SystemNetworkState()
        let wifi = CWWiFiClient.shared().interface()
        let store = SCDynamicStoreCreate(nil, "Zonal system controls" as CFString, nil, nil)
        let global = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
            ?? SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString)) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String ?? ""
        result.interface = primary
        result.addresses = addresses(for: primary)
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let type = interfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == primary }
            .flatMap { SCNetworkInterfaceGetInterfaceType($0) as String? }
        result.connection = primary.isEmpty ? "No active connection"
            : primary == wifi?.interfaceName ? "Wi-Fi connected"
            : type == (kSCNetworkInterfaceTypeEthernet as String) ? "Ethernet connected" : "Network connected"
        result.wifiPower = wifi?.powerOn()
        if wifi?.powerOn() == true {
            result.ssid = wifi?.ssid()
            if let signal = wifi?.rssiValue(), signal < 0 { result.signal = signal }
            if let rate = wifi?.transmitRate(), rate.isFinite, rate > 0, rate < Double(Int.max) { result.rate = Int(rate) }
        }
        return result
    }

    private static func bluetoothState() -> SystemControlSnapshot {
        var result = SystemControlSnapshot()
        if let controller = IOBluetoothHostController.default() { result.bluetoothPower = SystemBluetoothPower.state(controller) }
        result.canSetBluetoothPower = SystemBluetoothPower.isAvailable
        let batteries = bluetoothBatteries()
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let grouped = Dictionary(grouping: devices, by: { $0.addressString ?? "" })
        let names = Dictionary(grouping: devices, by: { $0.name ?? "Bluetooth device" })
        result.bluetoothDevices = grouped.compactMap { address, matches in
            guard !address.isEmpty, matches.count == 1, let device = matches.first else { return nil }
            let name = device.name ?? "Bluetooth device"
            return SystemBluetoothDevice(id: address, name: name, connected: device.isConnected(),
                                         battery: device.isConnected() ? SystemBluetoothBatteryReading.percent(in: batteries, address: address, name: name, uniqueName: names[name]?.count == 1)
                                            ?? bluetoothPercent(device, selector: "batteryPercentSingle") : nil,
                                         symbol: SystemBluetoothDevice.symbol(major: device.deviceClassMajor, minor: device.deviceClassMinor),
                                         batteryLeft: device.isConnected() ? bluetoothPercent(device, selector: "batteryPercentLeft") : nil,
                                         batteryRight: device.isConnected() ? bluetoothPercent(device, selector: "batteryPercentRight") : nil,
                                         batteryCase: device.isConnected() ? bluetoothPercent(device, selector: "batteryPercentCase") : nil)
        }.sorted {
            if $0.connected != $1.connected { return $0.connected }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return result
    }

    static func perform(_ action: SystemControlAction) -> String? {
        switch action {
        case .wifi(let enabled):
            guard let wifi = CWWiFiClient.shared().interface() else { return "Wi-Fi is unavailable on this Mac." }
            do { try wifi.setPower(enabled) }
            catch { return "Couldn’t change Wi-Fi. \(error.localizedDescription)" }
            return wifi.powerOn() == enabled ? nil : "macOS hasn’t confirmed the Wi-Fi change. Check Network Settings."
        case .bluetoothPower(let enabled):
            return SystemBluetoothPower.set(enabled)
        case .bluetooth(let target):
            guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
                return "Bluetooth is off or unavailable. Check Bluetooth Settings."
            }
            let matches = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.addressString == target.id }
            guard matches.count == 1, let device = matches.first, device.isConnected() == target.connected else {
                return "This device’s connection changed. The list has been refreshed."
            }
            let status = target.connected ? device.closeConnection() : device.openConnection()
            guard status == kIOReturnSuccess else { return "Couldn’t \(target.connected ? "disconnect" : "connect") \(target.name). Try Bluetooth Settings." }
            return device.isConnected() != target.connected ? nil : "The device hasn’t confirmed the connection change."
        case .output(let output):
            guard SystemAudio.select(output) else { return "Couldn’t switch audio output. It may have disconnected." }
            for _ in 0..<10 {
                if currentOutputMatches(output) { return nil }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return "macOS hasn’t confirmed the output change. The device list has been refreshed."
        case .mute(let output, let muted):
            guard currentOutputMatches(output) else { return "The audio output changed. Try again on the current device." }
            return SystemAudio.setMuted(muted, device: output.id) ? nil : "This output doesn’t support muting from your Mac."
        case .volume(let output, let value):
            guard currentOutputMatches(output) else { return "The audio output changed. Try again on the current device." }
            guard SystemAudio.setVolume(value, device: output.id) else { return "This output controls its own volume." }
            if SystemAudio.canSetMute(output.id) { _ = SystemAudio.setMuted(false, device: output.id) }
            return nil
        }
    }

    private static func currentOutputMatches(_ output: SystemAudioOutput) -> Bool {
        guard SystemAudio.output == output.id else { return false }
        return SystemAudio.outputs().contains { $0.matchesIdentity(of: output) }
    }

    private static func addresses(for interface: String) -> [String] {
        guard !interface.isEmpty else { return [] }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [String] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: host)
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
    }

    // Private getters are optional; verify their unsigned-char ABI before calling them.
    static func bluetoothPercent(_ device: NSObject, selector name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard let cls = object_getClass(device), let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let type = method_copyReturnType(method)
        defer { free(type) }
        guard String(cString: type) == "C" else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let value = Int(unsafeBitCast(method_getImplementation(method), to: Getter.self)(device, selector))
        // These getters also use zero for unavailable, so only trust positive readings.
        return (1...100).contains(value) ? value : nil
    }

    private static func bluetoothBatteries() -> [SystemBluetoothBatteryReading] {
        var readings: [SystemBluetoothBatteryReading] = []
        for cls in ["AppleDeviceManagementHIDEventService", "AppleHSBluetoothDevice", "IOBluetoothDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let values = properties?.takeRetainedValue() as? [String: Any],
                      let percent = values["BatteryPercent"] as? Int, (0...100).contains(percent) else { continue }
                let address = ["DeviceAddress", "BluetoothDeviceAddress", "BD_ADDR"]
                    .compactMap { values[$0] as? String }.compactMap(SystemBluetoothBatteryReading.address).first
                readings.append(.init(address: address, name: values["Product"] as? String ?? values["Bluetooth Product Name"] as? String ?? "", percent: percent))
            }
        }
        return readings
    }
}

struct SystemBluetoothBatteryReading: Equatable, Sendable {
    var address: String?
    var name: String
    var percent: Int

    static func address(_ value: String) -> String? {
        let compact = value.lowercased().filter { !":- ".contains($0) }
        return compact.utf8.count == 12 && compact.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? compact : nil
    }
    static func percent(in readings: [Self], address value: String, name: String, uniqueName: Bool) -> Int? {
        guard let target = address(value) else { return nil }
        let exact = readings.filter { $0.address.flatMap(address) == target }
        if !exact.isEmpty {
            let values = Set(exact.map(\.percent))
            return values.count == 1 ? values.first : nil
        }
        let matches = readings.filter { $0.address == nil && $0.name == name }
        return uniqueName && matches.count == 1 ? matches[0].percent : nil
    }
}

// macOS has no public Bluetooth power setter. Resolve the optional blueutil-compatible SPI at runtime.
enum SystemBluetoothPower {
    private static func library() -> UnsafeMutableRawPointer? {
        dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY | RTLD_LOCAL)
    }
    static var isAvailable: Bool {
        guard let library = library() else { return false }
        defer { dlclose(library) }
        return dlsym(library, "IOBluetoothPreferenceSetControllerPowerState") != nil
    }
    static func state(_ controller: IOBluetoothHostController) -> Bool? {
        switch controller.powerState {
        case kBluetoothHCIPowerStateON: true
        case kBluetoothHCIPowerStateOFF: false
        default: nil
        }
    }
    static func set(_ enabled: Bool) -> String? {
        guard let controller = IOBluetoothHostController.default(), let library = library() else { return "Bluetooth power control is unavailable. Use Bluetooth Settings." }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "IOBluetoothPreferenceSetControllerPowerState") else { return "Bluetooth power control is unavailable. Use Bluetooth Settings." }
        if state(controller) == enabled { return nil }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(enabled ? 1 : 0)
        for _ in 0..<30 {
            if state(controller) == enabled { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return "macOS hasn’t confirmed the Bluetooth power change. Check Bluetooth Settings."
    }
}

@MainActor
final class SystemControlPanelModel: ObservableObject {
    @Published var snapshot = SystemControlSnapshot()
    @Published var selected: SystemControlItem = .network
    @Published private(set) var refreshing = false
    @Published private(set) var pending = false
    @Published private(set) var pendingBluetoothID: String?
    @Published private(set) var error: String?
    @Published private(set) var loadedKinds: Set<SystemControlItem> = []
    @Published var volumeDraft: Double = 0
    var adjustingVolume = false
    private var volumePending = false
    private var refreshAgain = false
    private var desiredWiFi: Bool?
    private var desiredBluetoothPower: Bool?
    private var desiredMute: Bool?
    private let queue = DispatchQueue(label: "com.sebmarste.zonal.system-control-hardware", qos: .userInitiated)
    private let read: @Sendable (SystemControlItem) -> SystemControlSnapshot
    private let perform: @Sendable (SystemControlAction) -> String?
    private var volumeWork: DispatchWorkItem?
    private var volumeGeneration = UUID()
    private var timer: Timer?

    init(read: @escaping @Sendable (SystemControlItem) -> SystemControlSnapshot = SystemControlHardware.snapshot,
         perform: @escaping @Sendable (SystemControlAction) -> String? = SystemControlHardware.perform) {
        self.read = read; self.perform = perform
    }

    func start() {
        error = nil
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; adjustingVolume = false; refreshAgain = false }
    func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let item = selected
        let read = read
        queue.async {
            let result = read(item)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch item {
                case .network:
                    self.snapshot.network = result.network
                    if let desiredWiFi = self.desiredWiFi { self.snapshot.network.wifiPower = desiredWiFi }
                case .volume:
                    self.snapshot.outputs = result.outputs
                    self.snapshot.outputID = result.outputID
                    self.snapshot.volume = result.volume
                    self.snapshot.muted = self.desiredMute ?? result.muted
                    self.snapshot.canSetVolume = result.canSetVolume
                    self.snapshot.canSetMute = result.canSetMute
                    if !self.adjustingVolume && !self.volumePending { self.volumeDraft = Double(result.volume ?? 0) }
                case .battery:
                    self.snapshot.battery = result.battery
                    self.snapshot.lowPower = result.lowPower
                case .bluetooth:
                    self.snapshot.bluetoothPower = self.desiredBluetoothPower ?? result.bluetoothPower
                    self.snapshot.canSetBluetoothPower = result.canSetBluetoothPower
                    self.snapshot.bluetoothDevices = result.bluetoothDevices
                }
                self.loadedKinds.insert(item)
                self.refreshing = false
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    func act(_ action: SystemControlAction) {
        guard !pending else { return }
        error = nil; pending = true
        if case .wifi(let enabled) = action { desiredWiFi = enabled; snapshot.network.wifiPower = enabled }
        if case .bluetoothPower(let enabled) = action { desiredBluetoothPower = enabled; snapshot.bluetoothPower = enabled }
        if case .mute(_, let muted) = action { desiredMute = muted; snapshot.muted = muted }
        if case .bluetooth(let device) = action { pendingBluetoothID = device.id }
        let perform = perform
        queue.async {
            let error = perform(action)
            DispatchQueue.main.async { [weak self] in
                self?.desiredWiFi = nil; self?.desiredMute = nil; self?.desiredBluetoothPower = nil
                self?.pending = false; self?.pendingBluetoothID = nil; self?.error = error; self?.refresh()
            }
        }
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let value = min(1, max(0, value))
        volumeDraft = value
        guard let output = snapshot.outputs.first(where: { $0.id == snapshot.outputID }) else { return }
        volumePending = true
        volumeWork?.cancel()
        let generation = UUID(); volumeGeneration = generation
        let perform = perform
        let work = DispatchWorkItem { @Sendable [weak self] in
            let error = perform(.volume(output, Float(value)))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.volumeGeneration == generation else { return }
                self.error = error
                self.volumePending = false
                self.refresh()
            }
        }
        volumeWork = work
        queue.asyncAfter(deadline: .now() + 0.025, execute: work)
    }
}

struct SystemControlPanelGeometry {
    static let outset: CGFloat = 40
    static func frame(anchor: CGRect, surfaceSize: CGSize, visible: CGRect) -> CGRect {
        let size = CGSize(width: min(visible.width, surfaceSize.width + outset * 2),
                          height: min(visible.height, surfaceSize.height + outset * 2))
        let below = anchor.minY - 8 - surfaceSize.height - outset
        let preferredY = below >= visible.minY ? below : anchor.maxY + 8 - outset
        return CGRect(x: min(max(visible.minX, anchor.maxX - surfaceSize.width - outset), visible.maxX - size.width),
                      y: min(max(visible.minY, preferredY), visible.maxY - size.height), width: size.width, height: size.height)
    }
}

final class SystemControlPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

@MainActor
final class SystemControlPanels {
    static let shared = SystemControlPanels()
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "SystemControls")
    let model: SystemControlPanelModel
    private(set) var panel: SystemControlPanel?
    private var anchor = CGRect.zero
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var lastCloseReason = "none"
    private var resizeWork: DispatchWorkItem?
    var diagnostic: String {
        "visible=\(panel?.isVisible == true) selected=\(model.selected.rawValue) loaded=\(model.loadedKinds.map(\.rawValue).sorted().joined(separator: ",")) closeReason=\(lastCloseReason) refreshing=\(model.refreshing) pending=\(model.pending) error=\(model.error != nil) outputs=\(model.snapshot.outputs.count) ipAddresses=\(model.snapshot.network.addresses.count) bluetoothDevices=\(model.snapshot.bluetoothDevices.count) bluetoothPower=\(model.snapshot.bluetoothPower.map(String.init) ?? "unknown") battery=\(model.snapshot.battery != nil) bluetoothPowerControl=\(model.snapshot.canSetBluetoothPower) bluetoothBatteryReadings=\(model.snapshot.bluetoothDevices.filter { $0.batteryLevel != nil }.count) surfaceHeight=\(Int((panel?.frame.height ?? 80) - 80))"
    }

    init(model: SystemControlPanelModel = SystemControlPanelModel()) { self.model = model }

    func toggle(items: [SystemControlItem], selected: SystemControlItem, anchor: CGRect) {
        if panel?.isVisible == true, self.anchor == anchor, model.selected == selected { close(reason: "anchor-click"); return }
        close(reason: "replaced")
        guard items.contains(selected), let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else { return }
        self.anchor = anchor; model.selected = selected
        let width: CGFloat = items.contains(.bluetooth) ? 360 : 320
        let size = CGSize(width: min(width, max(180, screen.visibleFrame.width - 80)),
                          height: max(100, screen.visibleFrame.height - 80))
        let panel = SystemControlPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu; panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        panel.onClose = { [weak self] in self?.close(reason: "escape") }
        self.panel = panel
        let host = NSHostingView(rootView: SystemControlPanelView(model: model, items: items, maxSize: size,
            close: { [weak self] in self?.close(reason: "settings") },
            onSize: { [weak self, weak panel] surface in
                guard let self, let panel else { return }
                self.resize(panel, surface: surface, anchor: anchor, visible: screen.visibleFrame)
            }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(SystemControlPanelGeometry.frame(anchor: anchor, surfaceSize: size, visible: screen.visibleFrame), display: false)
        lastCloseReason = "none"
        host.layoutSubtreeIfNeeded()
        Self.logger.info("System panel opened control=\(selected.rawValue, privacy: .public)")
        model.start()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfOutside() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { self?.close(reason: "escape"); return nil }
            if event.type != .keyDown {
                self?.closeIfOutside(at: event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
            }
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let openingPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            if pid != openingPID, pid != ProcessInfo.processInfo.processIdentifier { MainActor.assumeIsolated { self?.close(reason: "app-change") } }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close(reason: "space-or-session-change") }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "focus-change") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "display-change") }
        })
    }

    private func resize(_ panel: SystemControlPanel, surface: CGSize, anchor: CGRect, visible: CGRect) {
        guard self.panel === panel, surface.width.isFinite, surface.height.isFinite, surface.height > 0 else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            panel.setFrame(SystemControlPanelGeometry.frame(anchor: anchor, surfaceSize: surface, visible: visible), display: true)
            if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }
        resizeWork = work
        DispatchQueue.main.async(execute: work)
    }

    private func closeIfOutside(at point: NSPoint = NSEvent.mouseLocation) {
        guard let panel else { return }
        if !panel.frame.insetBy(dx: SystemControlPanelGeometry.outset, dy: SystemControlPanelGeometry.outset).contains(point), !anchor.contains(point) { close(reason: "outside-click") }
    }

    func close(reason: String = "requested") {
        resizeWork?.cancel(); resizeWork = nil
        let closing = panel
        panel = nil
        if closing != nil {
            lastCloseReason = reason
            Self.logger.info("System panel closed reason=\(reason, privacy: .public)")
        }
        closing?.orderOut(nil)
        model.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

struct SystemControlPanelView: View {
    @ObservedObject var model: SystemControlPanelModel
    var items: [SystemControlItem]
    var maxSize: CGSize
    var close: () -> Void
    var onSize: (CGSize) -> Void
    @State private var contentHeight: CGFloat = 1

    private var chromeHeight: CGFloat { 76 + (items.count > 1 ? 36 : 0) }
    private var availableHeight: CGFloat { max(1, maxSize.height - chromeHeight) }

    private var state: SystemControlSnapshot { model.snapshot }
    private var output: SystemAudioOutput? { state.outputs.first { $0.id == state.outputID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if model.selected == .bluetooth {
                        Image(nsImage: SystemControlImages.bluetoothHeader)
                    } else { Image(systemName: model.selected.symbol).font(.system(size: 18, weight: .medium)) }
                }
                    .frame(width: 36, height: 36).foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                Text(model.selected.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                if model.selected == .bluetooth {
                    Toggle("Bluetooth", isOn: Binding(get: { state.bluetoothPower ?? false }, set: { model.act(.bluetoothPower($0)) }))
                        .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).fixedSize()
                        .disabled(state.bluetoothPower == nil || !state.canSetBluetoothPower || model.pending)
                        .help(state.canSetBluetoothPower ? "Turn Bluetooth on or off" : "Bluetooth power control is unavailable; use Bluetooth Settings")
                }
                if model.pending || (model.refreshing && !model.loadedKinds.contains(model.selected)) { ProgressView().controlSize(.small) }
                SystemPanelIconButton(image: Image(systemName: "gearshape"), label: "Open \(model.selected.settingsTitle)",
                                      help: model.selected.settingsHelp, action: openSettings)
            }.frame(height: 36)
            if items.count > 1 {
                Picker("Control", selection: $model.selected) {
                    ForEach(items) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(height: 24)
            }
            ScrollView {
                panelContent.frame(maxWidth: .infinity, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollDisabled(contentHeight <= availableHeight)
            .scrollIndicators(.automatic)
            .frame(height: min(contentHeight, availableHeight))
            .id(model.selected)
        }
        .padding(14).frame(width: maxSize.width)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.24), radius: 18, y: 9)
        }
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75) }
        .padding(SystemControlPanelGeometry.outset)
        .environment(\.controlActiveState, .key)
        .onChange(of: model.selected) { _, _ in model.refresh() }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.selected {
            case .network: network
            case .volume: volume
            case .battery: battery
            case .bluetooth: bluetooth
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11))
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(1)
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 8) {
            Panel(padding: 10, maxHeight: false) {
                HStack {
                    Text("Wi-Fi")
                    Spacer()
                    Toggle("Wi-Fi", isOn: Binding(get: { state.network.wifiPower ?? false }, set: { model.act(.wifi($0)) }))
                        .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .disabled(state.network.wifiPower == nil || model.pending)
                }
                if state.network.wifiPower == nil { detail("Wi-Fi is unavailable") }
                else if state.network.wifiPower == true {
                    HStack(spacing: 8) {
                        Text(state.network.ssid ?? (state.network.connection == "Wi-Fi connected" ? "Network name unavailable" : "Not connected"))
                            .lineLimit(1).truncationMode(.middle).help(state.network.ssid ?? "Network name unavailable")
                        Spacer(minLength: 0)
                        if let signal = state.network.signal {
                            Text("\(signal) dBm" + (state.network.rate.map { " · \($0) Mbps" } ?? "")).fixedSize()
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Panel(padding: 10, maxHeight: false) {
                HStack {
                    Text(state.network.connection).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    if !state.network.interface.isEmpty { detail(state.network.interface) }
                }
                ForEach(state.network.addresses, id: \.self) { address in
                    HStack {
                        Text(address).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        SystemPanelIconButton(image: Image(systemName: "doc.on.doc"), label: "Copy IP address \(address)", help: "Copy IP address") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
                        }
                    }
                }
                if state.network.addresses.isEmpty { detail("No IP address reported") }
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 8) {
            Panel(padding: 10, maxHeight: false) {
                HStack(spacing: 8) {
                    SystemPanelIconButton(image: Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
                                          label: state.muted ? "Unmute output" : "Mute output", selected: state.muted) {
                        if let output { model.act(.mute(output, !state.muted)) }
                    }.disabled(!state.canSetMute || model.pending || output?.uid == nil)
                    Slider(value: Binding(get: { model.volumeDraft }, set: { model.setVolume($0) }), in: 0...1,
                           onEditingChanged: { model.adjustingVolume = $0 }).disabled(!state.canSetVolume || output?.uid == nil)
                        .accessibilityLabel("Output volume")
                    Text(state.volume == nil ? "—" : "\(Int((model.volumeDraft * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().frame(minWidth: 32, alignment: .trailing)
                }
                if !state.canSetVolume { detail("This output controls its own volume.") }
            }
            ForEach(state.outputs) { device in
                Button { model.act(.output(device)) } label: {
                    SystemPanelDeviceRow(symbol: device.symbol, title: device.name, highlighted: device.id == state.outputID) {
                        if device.id == state.outputID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }.buttonStyle(.plain).disabled(model.pending || device.uid == nil)
            }
            if state.outputs.isEmpty { detail(!model.loadedKinds.contains(.volume) ? "Finding audio outputs…" : "No audio outputs available") }
        }
    }

    private var battery: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let battery = state.battery {
                Panel(padding: 10, maxHeight: false) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(battery.percent)%").font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit()
                        Spacer(minLength: 0)
                        Text(battery.status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    if battery.charging, let minutes = battery.minutesToFull {
                        HStack { Text("Until full"); Spacer(); detail("About \(minutes >= 60 ? "\(minutes / 60)h " : "")\(minutes % 60)m") }
                    }
                }
                Panel(padding: 10, maxHeight: false) {
                    HStack { Text("Power source"); Spacer(); Text(battery.powerSource).foregroundStyle(.secondary) }
                    HStack { Text("Low Power Mode"); Spacer(); Text(state.lowPower ? "On" : "Off").foregroundStyle(.secondary) }
                }
            } else { detail(!model.loadedKinds.contains(.battery) ? "Checking battery…" : "No internal battery is available on this Mac.") }
        }
    }

    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.bluetoothDevices) { device in
                if device.connected {
                    bluetoothRow(device)
                } else {
                    Button { model.act(.bluetooth(device)) } label: { bluetoothRow(device) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connect \(device.name)")
                        .help("Connect \(device.name)")
                        .disabled(model.pending || state.bluetoothPower != true)
                }
            }
            if state.bluetoothDevices.isEmpty { detail(!model.loadedKinds.contains(.bluetooth) ? "Finding paired devices…" : "No paired devices reported. Check Bluetooth Settings and Zonal’s Bluetooth access.") }
        }
    }

    private func bluetoothRow(_ device: SystemBluetoothDevice) -> some View {
        SystemPanelDeviceRow(symbol: device.symbol, title: device.name, highlighted: device.connected && state.bluetoothPower == true) {
            HStack(spacing: 6) {
                if let text = device.batteryText, let level = device.batteryLevel {
                    HStack(spacing: 3) {
                        Image(systemName: SystemBattery(percent: level, charging: false).symbol)
                            .foregroundStyle(level <= 20 ? Color.red : .secondary)
                        Text(text).monospacedDigit()
                    }.font(.system(size: 11)).fixedSize().help("Latest reported · \(device.batteryHelp)").accessibilityLabel(device.batteryHelp)
                }
                if model.pendingBluetoothID == device.id {
                    ProgressView().controlSize(.mini).frame(width: 28, height: 28)
                } else if device.connected {
                    SystemPanelIconButton(image: Image(nsImage: SystemControlImages.disconnect), label: "Disconnect \(device.name)") { model.act(.bluetooth(device)) }
                        .disabled(model.pending || state.bluetoothPower != true)
                }
            }
        }.accessibilityValue(device.connected ? "Connected, \(device.batteryHelp)" : "Not connected")
            .help(device.connected ? "\(device.name) · \(device.batteryHelp)" : device.name)
    }

    private func detail(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func openSettings() {
        close()
        NSWorkspace.shared.open(model.selected.settingsURL)
    }
}

private struct SystemPanelDeviceRow<Trailing: View>: View {
    var symbol: String
    var title: String
    var highlighted = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 28, height: 28)
                .foregroundStyle(highlighted ? Color.white : .secondary)
                .background(highlighted ? Color.blue : Color.primary.opacity(0.08), in: Circle())
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail).help(title)
            Spacer(minLength: 4)
            trailing
        }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SystemPanelIconButton: View {
    var image: Image
    var label: String
    var help: String? = nil
    var selected = false
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            image.font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .background(Color.primary.opacity(selected ? 0.10 : hovered && enabled ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8)).opacity(enabled ? 1 : 0.4)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help(help ?? label).accessibilityLabel(label)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
