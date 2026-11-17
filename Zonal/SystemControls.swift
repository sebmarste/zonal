import AppKit
import AudioToolbox
import IOBluetooth
import IOKit
import IOKit.ps
import Network
import CoreWLAN
import SwiftUI

// Optional profile data keeps existing profiles and their clock behavior unchanged.
struct SystemControlSettings: Codable, Equatable {
    var isEnabled = false
    var items: [SystemControlItem] = SystemControlItem.allCases

    func visibleItems(hasBattery: Bool) -> [SystemControlItem] {
        guard isEnabled else { return [] }
        return SystemControlItem.allCases.filter { items.contains($0) && ($0 != .battery || hasBattery) }
    }
}

enum SystemControlItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case volume, bluetooth, network, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .network: "Network"
        case .volume: "Volume"
        case .battery: "Battery"
        case .bluetooth: "Bluetooth"
        }
    }
    var controlWidth: CGFloat {
        switch self {
        case .network: 29
        case .volume: 34
        case .battery: 40
        case .bluetooth: 24
        }
    }
    var symbol: String {
        switch self {
        case .network: "network"
        case .volume: "speaker.wave.2"
        case .battery: "battery.100percent"
        case .bluetooth: "bluetooth"
        }
    }

    var settingsTitle: String { self == .volume ? "Sound Settings" : "\(title) Settings" }
    var settingsHelp: String {
        switch self {
        case .network: "Open Network Settings to choose or join networks"
        case .volume: "Open Sound Settings"
        case .battery: "Open Battery Settings for energy modes, charging and battery health"
        case .bluetooth: "Open Bluetooth Settings to pair devices or change Bluetooth power"
        }
    }
    var settingsURL: URL {
        let pane = switch self {
        case .network: "com.apple.Network-Settings.extension"
        case .volume: "com.apple.Sound-Settings.extension"
        case .battery: "com.apple.Battery-Settings.extension"
        case .bluetooth: "com.apple.BluetoothSettings"
        }
        return URL(string: "x-apple.systempreferences:" + pane)!
    }

}

struct SystemControlLayout: Equatable {
    var direct: [SystemControlItem]
    var overflow: [SystemControlItem]

    init(items: [SystemControlItem], availableWidth: CGFloat, vertical: Bool) {
        direct = []; overflow = items
        guard !items.isEmpty, !vertical else { return }
        let budget = availableWidth.isFinite ? max(0, availableWidth) : 0
        func width(_ items: [SystemControlItem]) -> CGFloat {
            items.reduce(0) { $0 + $1.controlWidth }
        }
        if width(items) <= budget { direct = items; overflow = []; return }
        // Reserve only an overflow button; there is no separate Zonal button.
        for item in items {
            let next = direct + [item]
            guard width(next) + 26 <= budget else { break }
            direct = next
        }
        overflow = Array(items.dropFirst(direct.count))
    }

}

struct SystemBattery: Equatable, Sendable {
    var percent: Int
    var charging: Bool
    var source: String? = nil
    var fullyCharged = false
    var minutesToFull: Int? = nil

    var status: String {
        if charging { return "Charging" }
        if source == kIOPSACPowerValue { return fullyCharged || percent == 100 ? "Fully charged" : "Plugged in · Not charging" }
        return source == kIOPSBatteryPowerValue ? "On battery" : "Power source unavailable"
    }

    var powerSource: String {
        source == kIOPSACPowerValue ? "Power adapter" : source == kIOPSBatteryPowerValue ? "Battery" : "Unknown"
    }

    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        let step = min(4, max(0, Int((Double(percent) / 25).rounded()))) * 25
        return "battery.\(step)percent"
    }

    static func percentage(current: Int, maximum: Int) -> Int? {
        guard current >= 0, maximum > 0 else { return nil }
        return Int(min(100, max(0, Double(current) / Double(maximum) * 100)).rounded())
    }
}

struct SystemAudioOutput: Identifiable, Equatable, Sendable {
    var id: AudioDeviceID
    var name: String
    var uid: String? = nil
    var symbol = "speaker.wave.2"

    func matchesIdentity(of other: SystemAudioOutput) -> Bool {
        guard let uid, !uid.isEmpty else { return false }
        return id == other.id && uid == other.uid
    }
}

// CoreAudio property access is also used by the serial system-controls worker.
enum SystemAudio {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }

    static var output: AudioDeviceID {
        var id = AudioDeviceID(0)
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    static func volumeProperties(_ device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let main = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(device, [main]) { return [main] }
        return [1, 2].map { address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0) }
            .filter { AudioObjectHasProperty(device, [$0]) }
    }

    static func volume(_ device: AudioDeviceID) -> Float? {
        var values: [Float] = []
        for var property in volumeProperties(device) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            if AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr, value.isFinite {
                values.append(min(1, max(0, value)))
            }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    static func canSetVolume(_ device: AudioDeviceID) -> Bool {
        let properties = volumeProperties(device)
        return !properties.isEmpty && properties.allSatisfy { property in
            var property = property
            var settable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
        }
    }

    static func setVolume(_ value: Float, device: AudioDeviceID) -> Bool {
        guard value.isFinite, output == device, canSetVolume(device) else { return false }
        var value = min(1, max(0, value))
        var success = true
        for var property in volumeProperties(device) {
            if AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) != noErr { success = false }
        }
        return success
    }

    static func muted(_ device: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr && value != 0
    }

    static func canSetMute(_ device: AudioDeviceID) -> Bool {
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
    }

    static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        guard output == device, canSetMute(device) else { return false }
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }

    static func outputs() -> [SystemAudioOutput] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return [] }
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return devices.compactMap { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameProperty = address(kAudioObjectPropertyName)
            var name: CFString = "Audio output" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(device, &nameProperty, 0, nil, &nameSize, &name) == noErr else { return nil }
            var uidProperty = address(kAudioDevicePropertyDeviceUID)
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidResult = AudioObjectGetPropertyData(device, &uidProperty, 0, nil, &uidSize, &uid)
            var transportProperty = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device, &transportProperty, 0, nil, &transportSize, &transport)
            let symbol = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport)
                ? "headphones" : [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort].contains(transport)
                    ? "display" : transport == kAudioDeviceTransportTypeBuiltIn ? "laptopcomputer" : "speaker.wave.2"
            return .init(id: device, name: name as String, uid: uidResult == noErr ? uid as String : nil, symbol: symbol)
        }
    }

    static func select(_ target: SystemAudioOutput) -> Bool {
        guard outputs().contains(where: { $0.matchesIdentity(of: target) }) else { return false }
        var device = target.id
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                         UInt32(MemoryLayout.size(ofValue: device)), &device) == noErr
    }
}

@MainActor
final class SystemControlMonitor: ObservableObject {
    static let shared = SystemControlMonitor()
    @Published private(set) var battery: SystemBattery?
    @Published private(set) var network = "Checking connection…"
    @Published private(set) var volume: Float?
    @Published private(set) var muted = false
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var clients = 0
    private var powerSource: CFRunLoopSource?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var audioProperties: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var observedOutput: AudioDeviceID?

    // Nothing starts until a visible, enabled cluster subscribes; deterministic tests don't touch hardware.
    func start() {
        clients += 1
        guard clients == 1 else { return }
        refresh()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemControlMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in monitor.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status == .satisfied
                ? (path.usesInterfaceType(.wiredEthernet) ? "Ethernet connected" : path.usesInterfaceType(.wifi) ? "Wi-Fi connected" : "Connected")
                : "No network connection"
            Task { @MainActor [weak self] in self?.network = status }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
        // Polling is a fallback; power and audio notifications update visible indicators immediately.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        timer?.invalidate(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        powerSource = nil
        stopAudioObservation()
    }

    func refresh() {
        battery = Self.readBattery()
        let device = SystemAudio.output
        volume = SystemAudio.volume(device)
        muted = SystemAudio.muted(device)
        if clients > 0, observedOutput != device { observeAudio(device) }
    }

    private func stopAudioObservation() {
        if let listener = audioListener {
            for (id, var property) in audioProperties {
                AudioObjectRemovePropertyListenerBlock(id, &property, .main, listener)
            }
        }
        audioProperties = []; audioListener = nil; observedOutput = nil
    }

    private func observeAudio(_ device: AudioDeviceID) {
        stopAudioObservation()
        observedOutput = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        audioListener = listener
        let properties = [(AudioObjectID(kAudioObjectSystemObject), SystemAudio.address(kAudioHardwarePropertyDefaultOutputDevice))]
            + SystemAudio.volumeProperties(device).map { (device, $0) }
            + [(device, SystemAudio.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput))]
        for (id, var property) in properties {
            if AudioObjectAddPropertyListenerBlock(id, &property, .main, listener) == noErr { audioProperties.append((id, property)) }
        }
    }

    nonisolated static func readBattery() -> SystemBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int,
                  let percent = SystemBattery.percentage(current: current, maximum: maximum) else { continue }
            return .init(percent: percent, charging: values[kIOPSIsChargingKey] as? Bool ?? false,
                         source: values[kIOPSPowerSourceStateKey] as? String,
                         fullyCharged: values[kIOPSIsChargedKey] as? Bool ?? false,
                         minutesToFull: (values[kIOPSTimeToFullChargeKey] as? Int).flatMap { $0 > 0 ? $0 : nil })
        }
        return nil
    }

    static func volumeSymbol(level: Float?, muted: Bool) -> String {
        if muted || level == 0 { return "speaker.slash" }
        guard let level else { return "speaker.wave.2" }
        return level < 0.33 ? "speaker.wave.1" : level < 0.66 ? "speaker.wave.2" : "speaker.wave.3"
    }

    static func networkSymbol(connection: String) -> String {
        switch connection {
        case "Ethernet connected": "ethernet"
        case "Wi-Fi connected": "wifi"
        case "No network connection": "wifi.slash"
        default: "network"
        }
    }

    func symbol(for item: SystemControlItem) -> String {
        switch item {
        case .network: Self.networkSymbol(connection: network)
        case .volume: Self.volumeSymbol(level: volume, muted: muted)
        case .battery: battery?.symbol ?? "battery.100percent"
        case .bluetooth: item.symbol
        }
    }
}

@MainActor
enum NativeMenuBarAccess {
    static func reveal() {
        // Use the user's native menu-focus shortcut without changing global auto-hide preferences.
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 120, keyDown: down)
            event?.flags = .maskControl
            event?.post(tap: .cghidEventTap)
        }
    }
}

struct SystemControlStrip: View {
    var settings: SystemControlSettings
    var availableWidth: CGFloat
    var vertical: Bool
    @ObservedObject private var monitor = SystemControlMonitor.shared

    var body: some View {
        let layout = SystemControlLayout(items: settings.visibleItems(hasBattery: monitor.battery != nil), availableWidth: availableWidth, vertical: vertical)
        HStack(spacing: 0) {
            ForEach(layout.direct) { item in
                SystemControlButton(symbol: monitor.symbol(for: item), label: item.title,
                    battery: item == .battery ? monitor.battery : nil, width: item.controlWidth,
                    tooltip: item == .network ? monitor.network : item == .battery ? "Battery \(monitor.battery?.percent ?? 0)%" : item.title,
                    items: [item])
            }
            if !layout.overflow.isEmpty {
                SystemControlButton(symbol: "ellipsis", label: "More system controls", battery: nil, width: 26,
                                    tooltip: "More system controls", items: layout.overflow)
            }
        }
        .fixedSize()
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

private struct SystemControlButton: NSViewRepresentable {
    var symbol: String
    var label: String
    var battery: SystemBattery?
    var width: CGFloat
    var tooltip: String
    var items: [SystemControlItem]

    func makeNSView(context: Context) -> SystemControlNativeButton {
        let button = SystemControlNativeButton()
        button.cell = SystemControlButtonCell()
        button.isBordered = false
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleNone
        button.font = SystemControlImages.font
        button.contentTintColor = .labelColor
        button.bezelStyle = .regularSquare
        return button
    }
    func updateNSView(_ button: SystemControlNativeButton, context: Context) {
        if let battery { button.image = SystemControlImages.battery(battery) }
        else {
            button.image = symbol == "bluetooth" ? SystemControlImages.bluetooth : SystemControlImages.symbol(symbol)
        }
        button.title = ""
        button.imagePosition = .imageOnly
        button.setAccessibilityValue(battery.map { "\($0.percent)%" } ?? "")
        button.items = items
        button.toolTip = tooltip
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("main-stack-control-" + label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SystemControlNativeButton, context: Context) -> CGSize? {
        CGSize(width: width, height: 24)
    }
}

final class SystemControlNativeButton: NSButton {
    // Fractional native view origins soften the entire layer, even when its glyph drawing is pixel-aligned.
    override var frame: NSRect {
        get { super.frame }
        set { super.frame = pixelAlignedFrame(newValue) }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(pixelAlignedFrame(NSRect(origin: newOrigin, size: frame.size)).origin)
    }
    private func pixelAlignedFrame(_ rect: NSRect) -> NSRect {
        guard let window, let parent = superview else { return rect }
        var backing = window.convertToBacking(parent.convert(rect, to: nil))
        backing.origin.x = floor(backing.origin.x)
        backing.origin.y = floor(backing.origin.y)
        return parent.convert(window.convertFromBacking(backing), from: nil)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frame = frame
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        frame = frame
    }
    var items: [SystemControlItem] = []
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    @discardableResult
    func openPanel(selected: SystemControlItem? = nil) -> Bool {
        NSApp.preventWindowOrdering()
        guard let window, !items.isEmpty, selected.map({ items.contains($0) }) ?? true else { return false }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        SystemControlPanels.shared.toggle(items: items, selected: selected ?? items[0], anchor: anchor)
        return true
    }
    override func mouseDown(with event: NSEvent) { _ = openPanel() }
    override func rightMouseDown(with event: NSEvent) { _ = openPanel() }
    override func accessibilityPerformPress() -> Bool { openPanel() }
}

@MainActor
enum SystemControlImages {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    static func symbol(_ name: String) -> NSImage? {
        if name == "ethernet" { return ethernet }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular, scale: .medium))
    }

    // Adapted from Lucide's unlink-2 and ethernet-port (ISC). See ThirdPartyNotices.txt.
    private static func vector(size: CGFloat, draw: @escaping (NSBezierPath) -> Void) -> NSImage {
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: 0, yBy: size); transform.scaleX(by: size / 24, yBy: -size / 24); transform.concat()
            let path = NSBezierPath(); path.lineWidth = 1.65; path.lineCapStyle = .round; path.lineJoinStyle = .round
            draw(path); NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.isTemplate = true
        image.alignmentRect = CGRect(x: 0, y: (size - font.capHeight) / 2, width: size, height: font.capHeight)
        return image
    }

    static let disconnect = vector(size: 14) { path in
        path.move(to: CGPoint(x: 15, y: 7)); path.line(to: CGPoint(x: 17, y: 7))
        path.curve(to: CGPoint(x: 17, y: 17), controlPoint1: CGPoint(x: 23.667, y: 7), controlPoint2: CGPoint(x: 23.667, y: 17))
        path.line(to: CGPoint(x: 15, y: 17))
        path.move(to: CGPoint(x: 9, y: 17)); path.line(to: CGPoint(x: 7, y: 17))
        path.curve(to: CGPoint(x: 7, y: 7), controlPoint1: CGPoint(x: 0.333, y: 17), controlPoint2: CGPoint(x: 0.333, y: 7))
        path.line(to: CGPoint(x: 9, y: 7))
    }

    static let ethernet = vector(size: 16) { path in
        path.move(to: CGPoint(x: 4, y: 4)); path.line(to: CGPoint(x: 20, y: 4))
        path.curve(to: CGPoint(x: 22, y: 6), controlPoint1: CGPoint(x: 21.105, y: 4), controlPoint2: CGPoint(x: 22, y: 4.895))
        path.line(to: CGPoint(x: 22, y: 15))
        path.curve(to: CGPoint(x: 20, y: 17), controlPoint1: CGPoint(x: 22, y: 16.105), controlPoint2: CGPoint(x: 21.105, y: 17))
        path.line(to: CGPoint(x: 19, y: 17))
        path.curve(to: CGPoint(x: 17.235, y: 18.059), controlPoint1: CGPoint(x: 18.27, y: 17), controlPoint2: CGPoint(x: 17.59, y: 17.405))
        path.line(to: CGPoint(x: 16.765, y: 18.941))
        path.curve(to: CGPoint(x: 15, y: 20), controlPoint1: CGPoint(x: 16.42, y: 19.595), controlPoint2: CGPoint(x: 15.73, y: 20))
        path.line(to: CGPoint(x: 9, y: 20))
        path.curve(to: CGPoint(x: 7.235, y: 18.941), controlPoint1: CGPoint(x: 8.27, y: 20), controlPoint2: CGPoint(x: 7.59, y: 19.595))
        path.line(to: CGPoint(x: 6.765, y: 18.059))
        path.curve(to: CGPoint(x: 5, y: 17), controlPoint1: CGPoint(x: 6.42, y: 17.405), controlPoint2: CGPoint(x: 5.73, y: 17))
        path.line(to: CGPoint(x: 4, y: 17))
        path.curve(to: CGPoint(x: 2, y: 15), controlPoint1: CGPoint(x: 2.895, y: 17), controlPoint2: CGPoint(x: 2, y: 16.105))
        path.line(to: CGPoint(x: 2, y: 6))
        path.curve(to: CGPoint(x: 4, y: 4), controlPoint1: CGPoint(x: 2, y: 4.895), controlPoint2: CGPoint(x: 2.895, y: 4))
        path.close()
        for x: CGFloat in [6, 10, 14, 18] {
            path.move(to: CGPoint(x: x, y: 8)); path.line(to: CGPoint(x: x, y: 9))
        }
    }

    static func battery(_ state: SystemBattery) -> NSImage {
        let outline = NSImage(systemSymbolName: "battery.0percent", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular, scale: .large))!
        let solid = NSImage(systemSymbolName: "battery.100percent", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular, scale: .large))!
        let size = CGSize(width: outline.size.width, height: outline.size.height + 2)
        let image = NSImage(size: size, flipped: false) { bounds in
            outline.draw(in: bounds)
            let bodyWidth = bounds.width - 4
            let percent = min(100, max(0, state.percent))
            let hasBolt = state.charging && percent < 100
            let fill = NSBezierPath(rect: CGRect(x: 0, y: 0,
                width: percent == 100 ? bounds.width : bodyWidth * CGFloat(percent) / 100, height: bounds.height))
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            solid.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
            let text = "\(percent)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.black]
            let centerX = bodyWidth / 2 - (hasBolt ? 2 : 0)
            func drawLabel(_ operation: NSCompositingOperation) {
                NSGraphicsContext.current?.compositingOperation = operation
                text.draw(at: CGPoint(x: centerX - text.size(withAttributes: attributes).width / 2,
                                      y: bounds.midY - numberFont.capHeight / 2 + numberFont.descender), withAttributes: attributes)
                if hasBolt {
                    NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                        .draw(in: CGRect(x: bodyWidth - 7.25, y: bounds.midY - 3.5, width: 4, height: 7), from: .zero, operation: operation, fraction: 1)
                }
            }
            drawLabel(.sourceOver)
            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            // Cut labels out of the solid fill so template tinting preserves inverted text in both appearances.
            drawLabel(.destinationOut)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.alignmentRect = outline.alignmentRect.offsetBy(dx: 0, dy: 1)
        image.isTemplate = true
        return image
    }

    // Draw at each presentation size; resizing the small template softens the panel-header icon.
    static let bluetooth = makeBluetooth(size: CGSize(width: 9, height: 16), lineWidth: 1)
    static let bluetoothHeader = makeBluetooth(size: CGSize(width: 13, height: 20), lineWidth: 1.25)

    private static func makeBluetooth(size: CGSize, lineWidth: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * size.width / 9, y: y * size.height / 16)
            }
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            // The stem and both diagonals share x=4.5; the one-point stem has whole-pixel edges at 1x.
            path.move(to: point(4.5, 2)); path.line(to: point(4.5, 14))
            path.line(to: point(8.5, 10.5)); path.line(to: point(0.5, 5.5))
            path.move(to: point(0.5, 10.5)); path.line(to: point(8.5, 5.5)); path.line(to: point(4.5, 2))
            NSColor.black.setStroke(); path.stroke()
            return true
        }
        image.alignmentRect = CGRect(x: 0, y: (size.height - font.capHeight) / 2, width: size.width, height: font.capHeight)
        image.isTemplate = true
        return image
    }

}

final class SystemControlButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else { return .zero }
        // NSButton is flipped; centering the canvas also preserves odd-height images' half-point placement.
        return CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                      width: image.size.width, height: image.size.height)
    }
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        var rect = imageRect(forBounds: controlView.bounds)
        if let context = NSGraphicsContext.current?.cgContext {
            let pixel = context.convertToDeviceSpace(rect.origin)
            let aligned = context.convertToUserSpace(CGPoint(x: pixel.x.rounded(), y: pixel.y))
            rect.origin.x = aligned.x
        }
        super.drawImage(image, withFrame: rect, in: controlView)
    }
}
