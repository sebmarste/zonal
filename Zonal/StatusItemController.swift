import AppKit
import Darwin
import OSLog
import SwiftUI

struct StatusMenuProfile: Equatable {
    var id: String
    var name: String
    var isSelected: Bool
}

struct StatusMenuSnapshot: Equatable {
    var accessibilityTrusted: Bool
    var inputMonitoringGranted: Bool
    var keyboardCaptureAvailable: Bool
    var trackingActive: Bool
    var displaySetupName: String
    var matchedProfileName: String?
    var matchingProfiles: [StatusMenuProfile] = []
}

@MainActor
final class StatusItemController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var lastMode: MenuBarMode?
    private var lastSnapshot: StatusMenuSnapshot?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusIcon(isHealthy: true)
        item.button?.target = self
        item.button?.action = #selector(openSettings)
        statusItem = item
        refresh(
            mode: AppContainer.shared.menuBarMode,
            snapshot: AppContainer.shared.menuSnapshot
        )
    }

    func refresh(mode: MenuBarMode, snapshot: StatusMenuSnapshot) {
        guard let item = statusItem else { return }
        guard mode != lastMode || snapshot != lastSnapshot else { return }
        lastMode = mode
        lastSnapshot = snapshot

        let isHealthy = snapshot.accessibilityTrusted
            && snapshot.inputMonitoringGranted
            && snapshot.keyboardCaptureAvailable
            && snapshot.trackingActive
        item.button?.image = statusIcon(isHealthy: isHealthy)
        item.button?.toolTip = statusSummary(snapshot)

        item.length = NSStatusItem.squareLength
        item.button?.title = ""
        item.button?.target = nil
        item.button?.action = nil
        item.menu = makeExtendedMenu(snapshot: snapshot)
    }

    private func statusIcon(isHealthy: Bool) -> NSImage? {
        guard isHealthy else {
            return NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Zonal needs attention"
            )
        }

        guard let icon = NSImage(named: "ZonalToolbar")?.copy() as? NSImage else {
            return NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Zonal")
        }
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        icon.accessibilityDescription = "Zonal"
        return icon
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func showGlobalSwitcher() {
        AppContainer.shared.showSwitcher(.allWindows)
    }

    @objc private func showZoneSwitcher() {
        AppContainer.shared.showSwitcher(.byZone)
    }

    @objc private func restoreWindows() {
        AppContainer.shared.restoreNow()
    }

    @objc private func undoLastWindowAction() {
        AppContainer.shared.undoLastWindowAction()
    }

    @objc private func rescanWindows() {
        AppContainer.shared.rescanWindows()
    }

    @objc private func quit() {
        AppContainer.shared.quit()
    }

    @objc private func applyProfile(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        AppContainer.shared.applyMatchingProfileFromMenu(id)
    }

    func makeExtendedMenu(snapshot: StatusMenuSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(disabledItem("Display setup: \(snapshot.displaySetupName)"))
        menu.addItem(disabledItem(statusSummary(snapshot)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Profiles"))
        if snapshot.matchingProfiles.isEmpty {
            menu.addItem(disabledItem("No matching profiles"))
        }
        for profile in snapshot.matchingProfiles {
            let item = actionItem(profile.name, keyEquivalent: "", action: #selector(applyProfile(_:)))
            item.representedObject = profile.id
            item.state = profile.isSelected ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(SwitcherMode.allWindows.title, keyEquivalent: "", action: #selector(showGlobalSwitcher)))
        menu.addItem(actionItem(SwitcherMode.byZone.title, keyEquivalent: "", action: #selector(showZoneSwitcher)))
        menu.addItem(actionItem("Rescan Windows", keyEquivalent: "", action: #selector(rescanWindows)))
        menu.addItem(actionItem(HotkeyCommand.restore.title, keyEquivalent: "", action: #selector(restoreWindows)))
        menu.addItem(actionItem(HotkeyCommand.undo.title, keyEquivalent: "z", action: #selector(undoLastWindowAction)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", keyEquivalent: ",", action: #selector(openSettings)))
        menu.addItem(actionItem("Quit Zonal", keyEquivalent: "q", action: #selector(quit)))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let updated = makeExtendedMenu(snapshot: AppContainer.shared.currentStatusMenuSnapshot())
        menu.removeAllItems()
        for item in updated.items {
            updated.removeItem(item)
            menu.addItem(item)
        }
    }

    private func actionItem(_ title: String, keyEquivalent: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLastWindowAction) {
            return AppContainer.shared.canUndoLastWindowAction
        }
        return true
    }

    private func statusSummary(_ snapshot: StatusMenuSnapshot) -> String {
        let activeCount = [
            snapshot.accessibilityTrusted,
            snapshot.inputMonitoringGranted,
            snapshot.keyboardCaptureAvailable,
            snapshot.trackingActive
        ].filter { $0 }.count
        return activeCount == 4 ? "Zonal is ready" : "Zonal needs attention (\(activeCount)/4 systems active)"
    }
}
