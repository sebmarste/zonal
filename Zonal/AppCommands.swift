import AppKit
import ApplicationServices
import SwiftUI

// Paths include sibling positions and titles: duplicate labels never select each other.
struct AppCommandPath: Equatable, Sendable {
    var indices: [Int]
    var titles: [String]
    var display: String { titles.joined(separator: " › ") }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            display.localizedCaseInsensitiveContains(String($0))
        }
    }
}

func commandAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

// AX handles are retained immutable references; messages are serialized by AppCommandReader.queue.
struct AppCommandNode: Identifiable, @unchecked Sendable {
    var path: AppCommandPath
    var element: AXUIElement
    var enabled: Bool
    var shortcut: String
    var children: [AppCommandNode]
    var isMenu: Bool
    var id: [Int] { path.indices }
    var title: String { path.titles.last ?? "" }
    var descendants: [AppCommandNode] { children.flatMap { [$0] + $0.descendants } }
}

// AX calls have a per-message timeout and scans have a total budget; neither runs on the UI thread.
final class AppCommandReader: @unchecked Sendable {
    let app: AXUIElement
    let window: AXUIElement
    let queue = DispatchQueue(label: "Zonal app commands", qos: .userInitiated)
    private let attribute: (AXUIElement, String) -> CFTypeRef?
    private let press: (AXUIElement) -> AXError
    init(pid: pid_t, window: AXUIElement,
         attribute: @escaping (AXUIElement, String) -> CFTypeRef? = commandAttribute,
         press: @escaping (AXUIElement) -> AXError = { AXUIElementPerformAction($0, kAXPressAction as CFString) }) {
        self.attribute = attribute
        self.press = press
        app = AXUIElementCreateApplication(pid)
        self.window = window
        AXUIElementSetMessagingTimeout(app, 0.15)
    }
    func contextIsCurrent() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let active = attribute(system, kAXFocusedApplicationAttribute), CFEqual(active, app),
              let focused = attribute(app, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(focused, window)
    }
    func read() -> ([AppCommandNode], Bool) {
        let deadline = Date().addingTimeInterval(1.5)
        var count = 0
        var complete = true
        func descend(_ parent: AXUIElement, path: AppCommandPath, depth: Int, ancestorsEnabled: Bool = true) -> [AppCommandNode] {
            guard depth < 12, count < 1500, Date() < deadline else { complete = false; return [] }
            guard let children = attribute(parent, kAXChildrenAttribute) as? [AXUIElement] else { complete = false; return [] }
            var result: [AppCommandNode] = []
            for (index, child) in children.enumerated() {
                guard count < 1500, Date() < deadline else { complete = false; break }
                count += 1
                let role = attribute(child, kAXRoleAttribute) as? String
                if role == kAXMenuRole {
                    result += descend(child, path: path, depth: depth + 1, ancestorsEnabled: ancestorsEnabled)
                    continue
                }
                guard let title = attribute(child, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
                let next = AppCommandPath(indices: path.indices + [index], titles: path.titles + [title])
                let submenus = (attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                let menu = role == kAXMenuBarItemRole || submenus.contains { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }
                let enabled = ancestorsEnabled && (attribute(child, kAXEnabledAttribute) as? Bool ?? false)
                let character = attribute(child, kAXMenuItemCmdCharAttribute) as? String ?? ""
                let glyph = (attribute(child, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue ?? 0
                let mods = (attribute(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                let key = character.isEmpty ? Self.glyph(glyph) : character.uppercased()
                let shortcut = key.isEmpty ? "" : ((mods & 4 != 0 ? "⌃" : "") + (mods & 2 != 0 ? "⌥" : "") + (mods & 1 != 0 ? "⇧" : "") + (mods & 8 == 0 ? "⌘" : "") + key)
                let nested = menu ? descend(child, path: next, depth: depth + 1, ancestorsEnabled: enabled) : []
                if menu && nested.isEmpty { complete = false }
                result.append(AppCommandNode(path: next, element: child, enabled: enabled,
                                             shortcut: shortcut, children: nested, isMenu: menu))
            }
            return result
        }
        guard contextIsCurrent(), let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return ([], false) }
        let nodes = descend(bar as! AXUIElement, path: AppCommandPath(indices: [], titles: []), depth: 0)
        return (nodes, complete)
    }
    func expand(_ node: AppCommandNode) -> ([AppCommandNode], Bool) {
        guard contextIsCurrent() else { return ([], false) }
        // Populate lazy menus only on explicit navigation, using the non-command ShowMenu action.
        // Apps without this action keep their native menu as the fallback; never press a guessed item.
        var actions: CFArray?
        if node.children.isEmpty,
           AXUIElementCopyActionNames(node.element, &actions) == .success,
           (actions as? [String])?.contains(kAXShowMenuAction) == true {
            guard AXUIElementPerformAction(node.element, kAXShowMenuAction as CFString) == .success else { return ([], false) }
            let snapshot = read()
            if let menu = (attribute(node.element, kAXChildrenAttribute) as? [AXUIElement])?.first(where: {
                attribute($0, kAXRoleAttribute) as? String == kAXMenuRole
            }) {
                _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            }
            return snapshot
        }
        return read()
    }
    static func glyph(_ value: Int) -> String {
        [9: "⇥", 10: "⇤", 11: "↩", 23: "⌫", 27: "⎋", 28: "←", 29: "→", 30: "↑", 31: "↓", 98: "⇞", 99: "⇟", 115: "↖", 119: "↘" ][value] ?? (value == 0 ? "" : "[key \(value)]")
    }
    func execute(_ node: AppCommandNode) -> String? {
        guard contextIsCurrent() else { return "The focused window changed. Reopen App Commands." }
        let (roots, _) = read()
        let matches = roots.flatMap { [$0] + $0.descendants }.filter { $0.path == node.path }
        guard matches.count == 1, let fresh = matches.first,
              CFEqual(fresh.element, node.element), fresh.enabled, !fresh.isMenu,
              fresh.shortcut == node.shortcut, contextIsCurrent() else {
            return "This command changed or is unavailable. Reopen App Commands."
        }
        // A timeout may mean the action ran. Issue exactly one press, never retry.
        let result = press(fresh.element)
        return result == .success ? nil : "The app did not confirm execution (\(result.rawValue)). Check its state before trying again."
    }
}

@MainActor
final class AppCommandsController: ObservableObject {
    @Published private var roots: [AppCommandNode] = []
    @Published private var ancestors: [AppCommandNode] = []
    @Published private var query = ""
    @Published private var selection = 0
    @Published private var status = ""
    private var reader: AppCommandReader?
    private var pid: pid_t = 0
    private var generation = UUID()
    private var timer: Timer?
    private var panel: NSPanel?
    private var busy = false
    private var checkingFocus = false
    private var activationObserver: NSObjectProtocol?
    var onVisibilityChanged: (() -> Void)?
    var isVisible: Bool { panel?.isVisible == true }
    private var rows: [AppCommandNode] {
        if query.isEmpty { return ancestors.last?.children ?? roots }
        return roots.flatMap { [$0] + $0.descendants }.filter { !$0.isMenu && $0.path.matches(query) }
    }
    func show(expectedWindow: AXUIElement? = nil) {
        close()
        guard let active = NSWorkspace.shared.frontmostApplication,
              active.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let app = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let focused = commandAttribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(),
              expectedWindow.map({ CFEqual($0, focused) }) ?? true else { return }
        pid = active.processIdentifier
        reader = AppCommandReader(pid: pid, window: focused as! AXUIElement)
        roots = []; ancestors = []; query = ""; selection = 0; status = "Reading \(active.localizedName ?? "app") menus…"
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .popUpMenu
        window.contentView = NSHostingView(rootView: AppCommandsView(controller: self))
        window.center(); window.orderFrontRegardless(); panel = window
        onVisibilityChanged?()
        refresh()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.pid { self.close() }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.pid { self.close(); return }
                self.verifyFocus()
            }
        }
    }
    private func verifyFocus() {
        guard let reader, !busy, !checkingFocus else { return }
        checkingFocus = true
        let token = generation
        reader.queue.async { [weak self] in
            let valid = reader.contextIsCurrent()
            DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.checkingFocus = false; if !valid { self.close() } }
        }
    }
    func focusedWindowChanged(_ window: AXUIElement?) {
        guard isVisible, let reader else { return }
        guard let window, CFEqual(window, reader.window) else { close(); return }
    }
    func close() {
        generation = UUID(); timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil; checkingFocus = false
        panel?.orderOut(nil); panel = nil; reader = nil; busy = false
        onVisibilityChanged?()
    }
    private func refresh(expanding node: AppCommandNode? = nil) {
        guard let reader, !busy else { return }
        busy = true
        let token = generation
        reader.queue.async { [weak self] in
            let (nodes, complete) = node.map { reader.expand($0) } ?? reader.read()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.busy = false; self.roots = nodes
                self.status = complete ? "Type to search · ↑↓ select · →/Return open · ←/Escape back" : "Some menus are unavailable or lazy. Open them in the app, then reopen App Commands."
                if !self.ancestors.isEmpty {
                    let path = self.ancestors.last!.path
                    if let fresh = nodes.flatMap({ [$0] + $0.descendants }).first(where: { $0.path == path }) { self.ancestors[self.ancestors.count - 1] = fresh }
                }
                self.selection = 0
            }
        }
    }
    func input(key: Int64, text: String?, flags: CGEventFlags) {
        guard isVisible else { return }
        switch key {
        case 53:
            if !query.isEmpty { query = ""; selection = 0 }
            else if !ancestors.isEmpty { ancestors.removeLast(); selection = 0 }
            else { close() }
        case 125: selection = min(max(0, rows.count - 1), selection + 1)
        case 126: selection = max(0, selection - 1)
        case 123: if query.isEmpty, !ancestors.isEmpty { ancestors.removeLast(); selection = 0 }
        case 124: if query.isEmpty, rows.indices.contains(selection), rows[selection].isMenu { choose(rows[selection]) }
        case 36, 76: if rows.indices.contains(selection) { choose(rows[selection]) }
        case 51, 117: if !query.isEmpty { query.removeLast(); selection = 0 }
        default:
            if !flags.contains(.maskCommand), !flags.contains(.maskControl), let text,
               let accepted = SwitcherTextInputPolicy().acceptedText(text) { query += accepted; selection = 0 }
        }
    }
    private func choose(_ node: AppCommandNode) {
        guard !busy, node.enabled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        if node.isMenu { ancestors.append(node); selection = 0; refresh(expanding: node); return }
        guard let reader else { return }
        busy = true
        let token = generation
        // Stop consuming keys and release the overlay before performing an app action.
        panel?.orderOut(nil); onVisibilityChanged?()
        reader.queue.async { [weak self] in
            let error = reader.execute(node)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.close()
                if let error { let alert = NSAlert(); alert.messageText = "App Command Not Confirmed"; alert.informativeText = error; alert.runModal() }
            }
        }
    }
    fileprivate var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ancestors.last?.path.display ?? "App Commands").font(.headline)
            Text(query.isEmpty ? "Type to search commands…" : query).frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(self.rows.enumerated()), id: \.element.id) { index, node in
                            Button { self.choose(node) } label: {
                                HStack {
                                    Text(self.query.isEmpty ? node.title : node.path.display).lineLimit(2)
                                    Spacer(); Text(node.shortcut).foregroundStyle(.secondary)
                                    if node.isMenu { Image(systemName: "chevron.right") }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == self.selection ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).disabled(!node.enabled || self.busy).id(index)
                        }
                    }
                }.onChange(of: self.selection) { _, value in proxy.scrollTo(value) }
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 620, height: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3).padding(20)
    }
}

private struct AppCommandsView: View {
    @ObservedObject var controller: AppCommandsController
    var body: some View { controller.content }
}
