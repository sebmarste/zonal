import AppKit
@preconcurrency import CoreGraphics
import Foundation
import OSLog

enum ShortcutRecordingSession {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    private static let state = State()
    static var isActive: Bool { state.lock.withLock { state.count > 0 } }
    static func begin() { state.lock.withLock { state.count += 1 } }
    static func end() { state.lock.withLock { state.count = max(0, state.count - 1) } }
}

// Only cached key matching runs on the input thread. It never waits for AppKit or AX.
struct HotkeyCaptureSnapshot {
    var bindings: [HotkeyBinding] = []
    var useNativeCommandTab = false
    var switcherActive = false
    private var releaseModifier: CGEventFlags?
    private var releasePending = false

    init(bindings: [HotkeyBinding] = [], useNativeCommandTab: Bool = false, switcherActive: Bool = false) {
        self.bindings = bindings
        self.useNativeCommandTab = useNativeCommandTab
        self.switcherActive = switcherActive
    }

    mutating func update(_ next: HotkeyCaptureSnapshot) {
        bindings = next.bindings
        useNativeCommandTab = next.useNativeCommandTab
        if !next.switcherActive { releasePending = false }
        switcherActive = next.switcherActive && !releasePending
    }

    mutating func flagsChanged(_ flags: CGEventFlags) {
        if let releaseModifier, !flags.contains(releaseModifier) {
            switcherActive = false
            releasePending = true
            self.releaseModifier = nil
        }
    }

    mutating func captures(_ event: CGEvent) -> Bool {
        guard !ShortcutRecordingSession.isActive else { switcherActive = false; return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if switcherActive {
            if [48, 53, 36, 76, 51, 117, 123, 124, 125, 126].contains(code) { return true }
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length,
                                           unicodeString: &characters)
            return SwitcherTextInputPolicy().acceptedText(String(utf16CodeUnits: characters, count: length)) != nil
        }
        guard let binding = bindings.first(where: {
            $0.isEnabled && $0.keyCode == code
                && $0.modifiers.command == flags.contains(.maskCommand)
                && $0.modifiers.control == flags.contains(.maskControl)
                && $0.modifiers.option == flags.contains(.maskAlternate)
                && ($0.modifiers.shift == flags.contains(.maskShift)
                    || (code == 48 && flags.contains(.maskShift) && !$0.modifiers.shift))
        }) else { return false }
        if useNativeCommandTab, code == 48, flags.contains(.maskCommand),
           case .openGlobalSwitcher = binding.command { return false }
        switch binding.command {
        case .openGlobalSwitcher, .openZoneSwitcher:
            switcherActive = true
            releasePending = false
            releaseModifier = binding.modifiers.command ? .maskCommand
                : binding.modifiers.option ? .maskAlternate
                : binding.modifiers.control ? .maskControl : .maskShift
        default: break
        }
        return true
    }
}

final class KeyboardInputTap: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = HotkeyCaptureSnapshot()
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var tap: CFMachPort?
    private let deliver: @Sendable (CGEventType, CGEvent, Bool) -> Void

    init(deliver: @escaping @Sendable (CGEventType, CGEvent, Bool) -> Void) { self.deliver = deliver }
    func update(_ snapshot: HotkeyCaptureSnapshot) { lock.withLock { self.snapshot.update(snapshot) } }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeyboardInputTap>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            let shouldRun = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                runLoop = loop
                return true
            }
            guard shouldRun else { return }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            lock.withLock { runLoop = nil }
        }
        thread.name = "Zonal keyboard input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let loop = lock.withLock { stopped = true; return runLoop }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop {
            // A queued stop also works if shutdown races the first run-loop entry.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }

    func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !lock.withLock({ stopped }), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let captured = lock.withLock { () -> Bool in
            if type == .flagsChanged { snapshot.flagsChanged(event.flags) }
            return type == .keyDown && snapshot.captures(event)
        }
        if let copy = event.copy() { deliver(type, copy, captured) }
        return captured ? nil : Unmanaged.passUnretained(event)
    }
}

@MainActor
final class HotkeyManager {
    private struct PendingCommand {
        var command: ZonalCommand
        var enqueuedAt: TimeInterval
    }

    private static let performanceLog = OSLog(
        subsystem: "com.sebmarste.zonal",
        category: .pointsOfInterest
    )

    private let restoreEngine: RestoreEngine
    private let windowRegistry: WindowRegistry
    private let store: PersistenceStore
    private let workspaceState: WorkspaceStateService
    private let switcher: SwitcherController
    var onUserKeyDown: (() -> Void)?
    var onEscape: (() -> Bool)?
    private var inputTap: KeyboardInputTap?
    private var inputGeneration = UUID()
    private var switcherReleaseModifier: CGEventFlags?
    private var pendingSwitcherReverse = false
    private var pendingCommands: [PendingCommand] = []
    private var isCommandDrainScheduled = false

    init(
        restoreEngine: RestoreEngine,
        windowRegistry: WindowRegistry,
        store: PersistenceStore,
        workspaceState: WorkspaceStateService,
        switcher: SwitcherController
    ) {
        self.restoreEngine = restoreEngine
        self.windowRegistry = windowRegistry
        self.store = store
        self.workspaceState = workspaceState
        self.switcher = switcher
    }

    func start() {
        stop()
        switcher.onShow = { [weak self] in self?.refreshCaptureSnapshot() }
        switcher.onHide = { [weak self] in
            self?.switcherReleaseModifier = nil
            self?.pendingSwitcherReverse = false
            self?.refreshCaptureSnapshot()
        }
        let generation = UUID()
        inputGeneration = generation
        let input = KeyboardInputTap { [weak self] type, event, captured in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputGeneration == generation else { return }
                if type == .keyDown && !captured {
                    self.onUserKeyDown?()
                    if event.getIntegerValueField(.keyboardEventKeycode) == 53 { _ = self.onEscape?() }
                } else {
                    _ = self.handleEvent(type: type, event: event)
                }
            }
        }
        inputTap = input
        refreshCaptureSnapshot()
        input.start()
    }

    func refreshCaptureSnapshot() {
        let configuration = store.loadConfiguration()
        inputTap?.update(HotkeyCaptureSnapshot(bindings: configuration.hotkeys,
            useNativeCommandTab: configuration.useNativeCommandTab || workspaceState.shouldUseNativeSwitcherInFullScreen(),
            switcherActive: switcher.isVisible))
    }

    func stop() {
        inputGeneration = UUID()
        inputTap?.stop()
        inputTap = nil
        switcherReleaseModifier = nil
        pendingSwitcherReverse = false
        pendingCommands.removeAll()
        isCommandDrainScheduled = false
        switcher.onHide = nil
        switcher.onShow = nil
    }

    func handle(_ command: ZonalCommand) {
        switch command {
        case .focusZone(let zoneID):
            restoreEngine.focusZone(zoneID)
        case .moveFocusedWindow(let zoneID):
            restoreEngine.assignFocusedWindow(to: zoneID)
        case .moveFocusedWindowRelative(let direction):
            restoreEngine.assignFocusedWindow(in: direction)
        case .nextWindowInStack:
            restoreEngine.focusNextWindowInStack(direction: 1)
        case .previousWindowInStack:
            restoreEngine.focusNextWindowInStack(direction: -1)
        case .openGlobalSwitcher:
            switcher.show(mode: .allWindows, reverse: pendingSwitcherReverse)
            pendingSwitcherReverse = false
        case .openZoneSwitcher:
            switcher.show(mode: .byZone, reverse: pendingSwitcherReverse)
            pendingSwitcherReverse = false
        case .switcherNext:
            switcher.next()
        case .switcherPrevious:
            switcher.previous()
        case .switcherVerticalWindow(let direction):
            switcher.moveVerticalWindow(direction: direction)
        case .switcherMoveZone(let direction):
            switcher.moveZone(direction: direction)
        case .switcherAssignZone(let direction):
            switcher.assignZone(direction: direction)
        case .switcherAppendFilter(let text):
            switcher.appendFilter(text)
        case .switcherDeleteFilterCharacter:
            switcher.deleteFilterCharacter()
        case .confirmSwitcher:
            switcher.confirm()
        case .cancelSwitcher:
            switcher.cancel()
        case .undo:
            restoreEngine.undoLastAction()
        case .restore:
            restoreEngine.restoreNow(trigger: .manual)
        }
    }

    func isKeyboardCaptureAvailable() -> Bool { inputTap?.isEnabled ?? false }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return Unmanaged.passUnretained(event)
        }

        guard !ShortcutRecordingSession.isActive else {
            if type == .keyDown { onUserKeyDown?() }
            switcherReleaseModifier = nil
            pendingSwitcherReverse = false
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged,
           let switcherReleaseModifier,
           SwitcherModifierReleasePolicy().shouldConfirm(
               hasPendingReleaseModifier: true,
               modifierIsStillPressed: event.flags.contains(switcherReleaseModifier)
           ) {
            switcher.dismissPresentation()
            enqueue(.confirmSwitcher)
            self.switcherReleaseModifier = nil
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventKeycode) == 53, onEscape?() == true { return nil }
        guard let command = command(for: event) else {
            onUserKeyDown?()
            return Unmanaged.passUnretained(event)
        }
        // A new switcher press must not discard the preceding release's focus handoff.
        // Confirming its selection supersedes the old request in WorkspaceStateService.
        switch command {
        case .openGlobalSwitcher, .openZoneSwitcher, .switcherNext, .switcherPrevious,
             .switcherVerticalWindow, .switcherMoveZone: break
        default: onUserKeyDown?()
        }
        enqueue(command)
        return nil
    }

    private func enqueue(_ command: ZonalCommand) {
        pendingCommands.append(PendingCommand(
            command: command,
            enqueuedAt: ProcessInfo.processInfo.systemUptime
        ))
        guard !isCommandDrainScheduled else { return }
        isCommandDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingCommands()
        }
    }

    private func drainPendingCommands() {
        isCommandDrainScheduled = false
        let commands = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        guard !ShortcutRecordingSession.isActive else { return }
        switcher.performPresentationBatch {
            for pending in commands {
                handle(pending.command)
                let milliseconds = (
                    ProcessInfo.processInfo.systemUptime - pending.enqueuedAt
                ) * 1_000
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "HotkeyCommandHandled",
                    "latency_ms=%{public}.2f",
                    milliseconds
                )
            }
        }
        refreshCaptureSnapshot()
        if !pendingCommands.isEmpty {
            isCommandDrainScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.drainPendingCommands()
            }
        }
    }

    private var isSwitcherVisible: Bool {
        switcher.isVisible
    }

    private func command(for event: CGEvent) -> ZonalCommand? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)

        if keyCode == 48, isSwitcherVisible {
            return shift ? .switcherPrevious : .switcherNext
        }

        if isSwitcherVisible {
            switch keyCode {
            case 53:
                return .cancelSwitcher
            case 36, 76:
                return .confirmSwitcher
            case 51, 117:
                return .switcherDeleteFilterCharacter
            case 123, 124, 125, 126:
                let key: SwitcherArrowKey = switch keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                default: .up
                }
                let action = SwitcherArrowCommandPolicy().action(
                    for: key,
                    shift: shift,
                    mode: switcher.mode
                )
                switch action {
                case .none:
                    return nil
                case .selectWindow(let direction):
                    return direction < 0 ? .switcherPrevious : .switcherNext
                case .selectVerticalWindow(let direction):
                    return .switcherVerticalWindow(direction)
                case .selectZone(let direction):
                    return .switcherMoveZone(direction)
                case .assignZone(let direction):
                    return .switcherAssignZone(direction)
                }
            default:
                let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
                if let text = SwitcherTextInputPolicy().acceptedText(characters) {
                    return .switcherAppendFilter(text)
                }
                return nil
            }
        }

        if let configuredCommand = configuredCommand(
            keyCode: keyCode,
            command: command,
            control: control,
            option: option,
            shift: shift
        ) {
            switch configuredCommand {
            case .openGlobalSwitcher:
                return configuredCommand
            case .openZoneSwitcher:
                return configuredCommand
            default:
                return configuredCommand
            }
        }

        return nil
    }

    private func configuredCommand(
        keyCode: Int64,
        command: Bool,
        control: Bool,
        option: Bool,
        shift: Bool
    ) -> ZonalCommand? {
        let configuration = store.loadConfiguration()
        let binding = configuration.hotkeys.first { hotkey in
            hotkey.isEnabled
                && hotkey.keyCode == keyCode
                && hotkey.modifiers.command == command
                && hotkey.modifiers.control == control
                && hotkey.modifiers.option == option
                && (
                    hotkey.modifiers.shift == shift
                        || (shift && !hotkey.modifiers.shift && hotkey.keyCode == 48)
                )
        }
        guard let binding else { return nil }
        if configuration.useNativeCommandTab,
           keyCode == 48,
           command,
           case .openGlobalSwitcher = binding.command {
            return nil
        }
        if keyCode == 48,
           command,
           case .openGlobalSwitcher = binding.command,
           workspaceState.shouldUseNativeSwitcherInFullScreen() {
            return nil
        }
        switch binding.command {
        case .openGlobalSwitcher, .openZoneSwitcher:
            switcherReleaseModifier = releaseModifier(for: binding.modifiers)
            pendingSwitcherReverse = shift && !binding.modifiers.shift
        default:
            break
        }
        return binding.command.zonalCommand
    }

    private func releaseModifier(for modifiers: HotkeyModifiers) -> CGEventFlags {
        if modifiers.command { return .maskCommand }
        if modifiers.option { return .maskAlternate }
        if modifiers.control { return .maskControl }
        if modifiers.shift { return .maskShift }
        return .maskCommand
    }

}
