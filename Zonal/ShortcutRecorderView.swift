import AppKit
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    var modifiers: HotkeyModifiers
    var key: HotkeyKey
    var onRecord: (HotkeyModifiers, HotkeyKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(modifiers: modifiers, key: key, onRecord: onRecord)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.coordinator = context.coordinator
        button.target = button
        button.action = #selector(ShortcutRecorderButton.beginRecording)
        button.updateTitle(modifiers: modifiers, key: key)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.modifiers = modifiers
        context.coordinator.key = key
        context.coordinator.onRecord = onRecord
        if !button.isRecording {
            button.updateTitle(modifiers: modifiers, key: key)
        }
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: Coordinator) {
        button.cancelRecording()
    }

    final class Coordinator {
        var modifiers: HotkeyModifiers
        var key: HotkeyKey
        var onRecord: (HotkeyModifiers, HotkeyKey) -> Void

        init(modifiers: HotkeyModifiers, key: HotkeyKey, onRecord: @escaping (HotkeyModifiers, HotkeyKey) -> Void) {
            self.modifiers = modifiers
            self.key = key
            self.onRecord = onRecord
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    weak var coordinator: ShortcutRecorderView.Coordinator?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        ShortcutRecordingSession.begin()
        title = "Type Shortcut…"
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            finishRecording(cancelled: true)
            return
        }
        guard let key = HotkeyKey.common.first(where: { $0.keyCode == Int64(event.keyCode) }) else {
            NSSound.beep()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = HotkeyModifiers(
            command: flags.contains(.command),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift)
        )
        guard modifiers.command || modifiers.control || modifiers.option || modifiers.shift else {
            NSSound.beep()
            title = "Include a Modifier"
            return
        }
        coordinator?.modifiers = modifiers
        coordinator?.key = key
        coordinator?.onRecord(modifiers, key)
        finishRecording(cancelled: false)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            finishRecording(cancelled: true)
        }
        return resigned
    }

    func cancelRecording() {
        finishRecording(cancelled: true)
    }

    func updateTitle(modifiers: HotkeyModifiers, key: HotkeyKey) {
        title = "\(modifiers.displayString) + \(key.label)"
        setAccessibilityLabel("Record shortcut")
        setAccessibilityValue(title)
    }

    private func finishRecording(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        ShortcutRecordingSession.end()
        if let coordinator {
            updateTitle(
                modifiers: coordinator.modifiers,
                key: coordinator.key
            )
        }
        if !cancelled {
            window?.makeFirstResponder(nil)
        }
    }
}
