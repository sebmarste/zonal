import AppKit
import Darwin
import OSLog
import SwiftUI

extension AppTheme {
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .followSystem: nil
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var hasUnsavedDraft = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Zonal Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.setAccessibilityIdentifier("ZonalSettingsWindow")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        if !window.setFrameUsingName("ZonalSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("ZonalSettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if window?.contentViewController == nil {
            let host = NSHostingController(rootView: SettingsView(store: AppContainer.shared.store,
                onPendingEditsChanged: { [weak self] pending in self?.hasUnsavedDraft = pending }))
            // The resizable AppKit window owns sizing, not SwiftUI intrinsic content.
            host.sizingOptions = []
            window?.contentViewController = host
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppContainer.shared.settingsVisibilityDidChange()
    }

    func windowWillClose(_ notification: Notification) {
        // Let SettingsView flush its pending draft through willClose before teardown.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            Self.discardClosedContent(in: window, hasUnsavedDraft: self.hasUnsavedDraft)
        }
        updateOutline(isFocused: false)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppContainer.shared.settingsVisibilityDidChange()
    }

    static func discardClosedContent(in window: NSWindow, hasUnsavedDraft: Bool) {
        guard !window.isVisible, !hasUnsavedDraft else { return }
        window.contentViewController = nil
        window.contentView = nil
    }

    func windowDidBecomeKey(_ notification: Notification) { updateOutline(isFocused: true) }
    func windowDidResignKey(_ notification: Notification) { updateOutline(isFocused: false) }
    func windowDidMove(_ notification: Notification) { updateOutline(geometryChanged: true) }
    func windowDidResize(_ notification: Notification) { updateOutline(geometryChanged: true) }

    private func updateOutline(geometryChanged: Bool = false, isFocused: Bool? = nil) {
        guard let window else { return }
        AppContainer.shared.settingsWindowDidChange(window, geometryChanged: geometryChanged,
            isFocused: isFocused ?? (window.isKeyWindow && NSApp.isActive))
    }
}
