import AppKit
import ApplicationServices

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
    func windowContextMatches() -> Bool? {
        guard let focused = attribute(app, kAXFocusedWindowAttribute) else { return nil }
        return CFEqual(focused, window)
    }
    func read(category: AppCommandNode? = nil, categoriesOnly: Bool = false) -> ([AppCommandNode], Bool) {
        let deadline = Date().addingTimeInterval(1.5)
        var branchDeadline = deadline
        var count = 0
        var complete = true
        func descend(_ parent: AXUIElement, path: AppCommandPath, depth: Int, ancestorsEnabled: Bool = true, recursive: Bool = true) -> [AppCommandNode] {
            guard depth < 12, count < 1500, Date() < branchDeadline else { complete = false; return [] }
            guard let children = attribute(parent, kAXChildrenAttribute) as? [AXUIElement] else { complete = false; return [] }
            var result: [AppCommandNode] = []
            for (index, child) in children.enumerated() {
                guard count < 1500, Date() < branchDeadline else { complete = false; break }
                count += 1
                let role = attribute(child, kAXRoleAttribute) as? String
                if role == kAXMenuRole {
                    result += descend(child, path: path, depth: depth + 1, ancestorsEnabled: ancestorsEnabled, recursive: recursive)
                    continue
                }
                guard let title = attribute(child, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
                let next = AppCommandPath(indices: path.indices + [index], titles: path.titles + [title])
                let submenus = (attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                let menu = role == kAXMenuBarItemRole || submenus.contains { attribute($0, kAXRoleAttribute) as? String == kAXMenuRole }
                let enabled = ancestorsEnabled && (attribute(child, kAXEnabledAttribute) as? Bool ?? menu)
                let character = attribute(child, kAXMenuItemCmdCharAttribute) as? String ?? ""
                let glyph = (attribute(child, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue ?? 0
                let mods = (attribute(child, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                let key = character.isEmpty ? Self.glyph(glyph) : character.uppercased()
                let shortcut = key.isEmpty ? "" : ((mods & 4 != 0 ? "⌃" : "") + (mods & 2 != 0 ? "⌥" : "") + (mods & 1 != 0 ? "⇧" : "") + (mods & 8 == 0 ? "⌘" : "") + key)
                let nested = menu && recursive ? descend(child, path: next, depth: depth + 1, ancestorsEnabled: enabled) : []
                if menu && recursive && nested.isEmpty { complete = false }
                result.append(AppCommandNode(path: next, element: child, enabled: enabled,
                                             shortcut: shortcut, children: nested, isMenu: menu))
            }
            return result
        }
        // A native context menu may temporarily own system AX focus. Inventory reads use
        // the captured app's window; execution still requires strict system focus after closing.
        guard windowContextMatches() != false else { return ([], false) }
        if let category {
            return (descend(category.element, path: category.path, depth: 0, ancestorsEnabled: category.enabled), complete)
        }
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return ([], false) }
        var nodes = descend(bar as! AXUIElement, path: AppCommandPath(indices: [], titles: []), depth: 0, recursive: false)
        if categoriesOnly { return (nodes, complete) }
        // Discover every category before spending time in any one category's descendants.
        for index in nodes.indices where nodes[index].isMenu {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            branchDeadline = Date().addingTimeInterval(remaining / Double(nodes.count - index))
            nodes[index].children = descend(nodes[index].element, path: nodes[index].path, depth: 1, ancestorsEnabled: nodes[index].enabled)
        }
        return (nodes, complete)
    }
    static func glyph(_ value: Int) -> String {
        [9: "⇥", 10: "⇤", 11: "↩", 23: "⌫", 27: "⎋", 28: "←", 29: "→", 30: "↑", 31: "↓", 98: "⇞", 99: "⇟", 115: "↖", 119: "↘" ][value] ?? (value == 0 ? "" : "[key \(value)]")
    }
    func execute(_ node: AppCommandNode) -> String? {
        guard contextIsCurrent() else { return "The focused window changed. Reopen the window menu." }
        let (roots, _) = read(categoriesOnly: true)
        let categories = roots.filter {
            $0.path.indices.first == node.path.indices.first && $0.path.titles.first == node.path.titles.first
        }
        guard categories.count == 1, let category = categories.first else {
            return "This menu changed. Reopen the window menu."
        }
        let freshNodes = category.isMenu ? read(category: category).0 : [category]
        let matches = freshNodes.flatMap { [$0] + $0.descendants }.filter { $0.path == node.path }
        guard matches.count == 1, let fresh = matches.first,
              CFEqual(fresh.element, node.element), fresh.enabled, !fresh.isMenu,
              fresh.shortcut == node.shortcut, contextIsCurrent() else {
            return "This command changed or is unavailable. Reopen the window menu."
        }
        // A timeout may mean the action ran. Issue exactly one press, never retry.
        let result = press(fresh.element)
        return result == .success ? nil : "The app did not confirm execution (\(result.rawValue)). Check its state before trying again."
    }
}

struct TabContextMenuPolicy {
    enum Section: CaseIterable, Hashable { case search, zonal, app }
    static func sections(opensUpward: Bool) -> [Section] {
        opensUpward ? [.app, .zonal, .search] : [.search, .zonal, .app]
    }
    static func opensUpward(at point: CGPoint, visibleFrame: CGRect, menuHeight: CGFloat) -> Bool {
        let below = point.y - visibleFrame.minY
        let above = visibleFrame.maxY - point.y
        return below < menuHeight && above > below
    }
}

// Native custom menu views do not receive normal menu typing. Keep text filtering
// on the existing input tap; AppKit retains arrows, Return, Escape and submenus.
final class TabMenuSearchField: NSSearchField {
    var clear: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        if convert(event.locationInWindow, from: nil).x > bounds.maxX - 24 { clear?() }
    }
}

@MainActor
final class TabContextMenuSession: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let reader: AppCommandReader?
    let zonalItems: [NSMenuItem]
    let search = TabMenuSearchField(frame: NSRect(x: 12, y: 8, width: 296, height: 26))
    private let searchItem = NSMenuItem()
    private var nodes: [AppCommandNode] = []
    private var submenuNodes: [ObjectIdentifier: AppCommandNode] = [:]
    private var submenuObjects: [NSMenu] = []
    private var complete = false
    private var indexing = false
    private var loading = false
    private var closed = false
    var opensUpward = false
    private(set) var query = ""
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onInventory: ((String) -> Void)?
    var onQueryChanged: (() -> Void)?
    private(set) var unavailableReason: String

    init(menu: NSMenu, reader: AppCommandReader?, unavailableReason: String = "App commands require the focused window") {
        self.menu = menu
        self.reader = reader
        self.unavailableReason = unavailableReason
        zonalItems = menu.items.filter { !$0.isSeparatorItem }
        super.init()
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.minimumWidth = 320
        menu.delegate = self
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 42))
        search.placeholderString = "Search commands…"
        search.setAccessibilityLabel("Search commands — type to filter")
        search.clear = { [weak self] in self?.setQuery("") }
        view.addSubview(search)
        searchItem.view = view
        rebuild()
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    private func matches(_ title: String) -> Bool {
        AppCommandPath(indices: [], titles: [title]).matches(query)
    }
    func setQuery(_ value: String) {
        guard !closed else { return }
        query = value
        search.stringValue = value
        rebuild()
        onQueryChanged?()
    }
    func setNodes(_ value: [AppCommandNode], complete: Bool) {
        guard !closed else { return }
        nodes = value
        self.complete = complete
        loading = false
        onInventory?("categories=\(nodes.count) commands=\(nodes.flatMap { [$0] + $0.descendants }.filter { !$0.isMenu }.count) complete=\(complete)")
        rebuild()
    }
    func rebuild() {
        menu.removeAllItems()
        submenuNodes.removeAll(); submenuObjects.removeAll()
        let zonal = query.isEmpty ? zonalItems : zonalItems.filter { matches($0.title) }
        var app: [NSMenuItem] = []
        if query.isEmpty {
            app = nodes.map { item(for: $0, fullPath: false) }
            if reader == nil { app = [info(unavailableReason)] }
            else if app.isEmpty { app = [info(loading ? "Reading app menus…" : "App did not expose any menus")] }
            if !complete, !nodes.isEmpty { app.append(info("Some dynamic menus may be unavailable")) }
        } else {
            app = nodes.flatMap { [$0] + $0.descendants }.filter { !$0.isMenu && matches($0.path.display + " " + $0.shortcut) }
                .map { item(for: $0, fullPath: true) }
            if app.isEmpty { app = [info(loading || indexing ? "Reading app menus…" : "No matching app commands")] }
        }
        let sections: [TabContextMenuPolicy.Section: [NSMenuItem]] = [
            .search: [searchItem],
            .zonal: zonal.isEmpty ? [info("No matching Zonal commands")] : zonal,
            .app: app
        ]
        for section in TabContextMenuPolicy.sections(opensUpward: opensUpward) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in sections[section] ?? [] { menu.addItem(item) }
        }
        menu.update()
    }
    private func item(for node: AppCommandNode, fullPath: Bool) -> NSMenuItem {
        let title = (fullPath ? node.path.display : node.title) + (node.shortcut.isEmpty ? "" : "    " + node.shortcut)
        let reader = self.reader
        let root = menu
        let item = ZoneTabMenuItem(title: title) { [weak root] in
            guard let reader, !node.isMenu, node.enabled else { return }
            root?.cancelTracking()
            DispatchQueue.main.async {
                reader.queue.async {
                    let error = reader.execute(node)
                    if let error {
                        Self.deliver {
                            let alert = NSAlert()
                            alert.messageText = "App Command Not Confirmed"
                            alert.informativeText = error
                            alert.runModal()
                        }
                    }
                }
            }
        }
        item.isEnabled = node.enabled
        if node.isMenu {
            let submenu = NSMenu(title: node.title)
            submenu.autoenablesItems = false
            submenu.delegate = self
            submenuNodes[ObjectIdentifier(submenu)] = node
            submenuObjects.append(submenu)
            for child in node.children { submenu.addItem(self.item(for: child, fullPath: false)) }
            if submenu.items.isEmpty { submenu.addItem(info("Reading menu…")) }
            item.submenu = submenu
        }
        return item
    }
    nonisolated static func deliver(_ body: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            closed = false
            onOpen?()
            guard let reader else { return }
            loading = true
            rebuild()
            reader.queue.async { [weak self] in
                let (nodes, complete) = reader.read()
                Self.deliver {
                    guard let self, !self.closed else { return }
                    self.setNodes(nodes, complete: complete)
                    self.indexing = true
                    self.indexCategories(nodes, complete: true)
                }
            }
        } else if let node = submenuNodes[ObjectIdentifier(menu)], let reader {
            let menuID = ObjectIdentifier(menu)
            reader.queue.async { [weak self] in
                let (children, complete) = reader.read(category: node)
                Self.deliver {
                    guard let self, !self.closed,
                          let menu = self.submenuObjects.first(where: { ObjectIdentifier($0) == menuID }) else { return }
                    menu.removeAllItems()
                    for child in children { menu.addItem(self.item(for: child, fullPath: false)) }
                    if children.isEmpty { menu.addItem(self.info(complete ? "No commands" : "App did not expose this menu")) }
                    menu.update()
                    self.replaceChildren(children, at: node.path)
                }
            }
        }
    }
    private func indexCategories(_ remaining: [AppCommandNode], complete: Bool) {
        guard !closed, let reader else { return }
        guard let node = remaining.first else {
            indexing = false
            self.complete = complete
            onInventory?("categories=\(nodes.count) commands=\(nodes.flatMap { [$0] + $0.descendants }.filter { !$0.isMenu }.count) complete=\(complete)")
            if !query.isEmpty { rebuild() }
            return
        }
        guard node.isMenu else { indexCategories(Array(remaining.dropFirst()), complete: complete); return }
        reader.queue.async { [weak self] in
            let (children, categoryComplete) = reader.read(category: node)
            Self.deliver {
                guard let self, !self.closed else { return }
                self.replaceChildren(children, at: node.path)
                if !self.query.isEmpty { self.rebuild() }
                self.indexCategories(Array(remaining.dropFirst()), complete: complete && categoryComplete)
            }
        }
    }
    private func replaceChildren(_ children: [AppCommandNode], at path: AppCommandPath) {
        func replace(_ node: AppCommandNode) -> AppCommandNode {
            var copy = node
            copy.children = node.path == path ? children : node.children.map(replace)
            return copy
        }
        nodes = nodes.map(replace)
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { closed = true; onClose?() }
    }
    func cancel() { closed = true; menu.cancelTracking() }
    func input(key: Int64, text: String?, flags: CGEventFlags) {
        if key == 53 { setQuery(""); return }
        if [36, 76].contains(key), !query.isEmpty {
            let highlighted = menu.highlightedItem
            guard let item = (highlighted?.isEnabled == true && highlighted?.action != nil && highlighted?.submenu == nil ? highlighted : nil)
                ?? menu.items.first(where: { $0.isEnabled && $0.action != nil && $0.submenu == nil }),
                let action = item.action else { return }
            menu.cancelTracking()
            DispatchQueue.main.async { NSApp.sendAction(action, to: item.target, from: item) }
        } else if [51, 117].contains(key) {
            if flags.contains(.maskCommand) { setQuery("") }
            else if !query.isEmpty { setQuery(String(query.dropLast())) }
        } else if key == 9, flags.contains(.maskCommand) {
            if let value = NSPasteboard.general.string(forType: .string) { setQuery(query + value) }
        } else if !flags.contains(.maskCommand), !flags.contains(.maskControl), let text,
                  let value = SwitcherTextInputPolicy().acceptedText(text) {
            setQuery(query + value)
        }
    }
}

@MainActor
final class AppCommandsController {
    private var session: TabContextMenuSession?
    private var pid: pid_t?
    private var timer: Timer?
    private var checkingFocus = false
    private var activationObserver: NSObjectProtocol?
    private(set) var isVisible = false
    private(set) var lastInventory = "App menus have not been opened"
    var isFiltering: Bool { session?.query.isEmpty == false }
    var onVisibilityChanged: (() -> Void)?
    var openFocusedTabMenu: (() -> Bool)?

    func inspectActiveMenus(_ completion: @escaping @MainActor @Sendable (String) -> Void) {
        guard let active = NSWorkspace.shared.frontmostApplication else { completion("No active app"); return }
        let app = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let focused = commandAttribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            completion("Active app has no readable focused window"); return
        }
        let reader = AppCommandReader(pid: active.processIdentifier, window: focused as! AXUIElement)
        reader.queue.async { [weak self] in
            let (nodes, complete) = reader.read()
            let summary = "categories=\(nodes.count) complete=\(complete)\n" + nodes.map {
                "\($0.title): commands=\($0.descendants.filter { !$0.isMenu }.count) enabled=\($0.enabled)"
            }.joined(separator: "\n")
            TabContextMenuSession.deliver {
                self?.lastInventory = summary
                completion(summary)
            }
        }
    }
    func show() { TabContextMenuSession.deliver { [weak self] in _ = self?.openFocusedTabMenu?() } }
    func configure(_ menu: NSMenu, expectedWindow: AXUIElement) {
        close()
        var targetPID: pid_t = 0
        AXUIElementGetPid(expectedWindow, &targetPID)
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = AXUIElementCreateApplication(targetPID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let focused = commandAttribute(app, kAXFocusedWindowAttribute)
        let valid = active == targetPID && focused.map { CFEqual($0, expectedWindow) } == true
        lastInventory = valid ? "Reading app menus" : "Context unavailable: activePID=\(active ?? 0) targetPID=\(targetPID) focusedWindow=\(focused != nil)"
        let reader = valid ? AppCommandReader(pid: targetPID, window: expectedWindow) : nil
        let session = TabContextMenuSession(menu: menu, reader: reader)
        self.session = session
        pid = targetPID
        session.onOpen = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.isVisible = true; self.onVisibilityChanged?()
            self.startWatching()
        }
        session.onClose = { [weak self, weak session] in
            guard let self, self.session === session else { return }
            self.close()
        }
        session.onInventory = { [weak self] in self?.lastInventory = $0 }
        session.onQueryChanged = { [weak self] in self?.onVisibilityChanged?() }
    }
    private func startWatching() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.pid { self.close() }
            }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyFocus() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func verifyFocus() {
        guard isVisible, let session, let reader = session.reader, !checkingFocus else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { close(); return }
        checkingFocus = true
        reader.queue.async { [weak self, weak session] in
            let matches = reader.windowContextMatches()
            TabContextMenuSession.deliver {
                guard let self, self.session === session else { return }
                self.checkingFocus = false
                if matches == false { self.close() }
            }
        }
    }
    func focusedWindowChanged(_ window: AXUIElement?) {
        guard isVisible, let reader = session?.reader, let window else { return }
        if !CFEqual(window, reader.window) { close() }
    }
    func close() {
        let current = session
        session = nil
        isVisible = false
        timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil; checkingFocus = false
        current?.cancel()
        onVisibilityChanged?()
    }
    func input(key: Int64, text: String?, flags: CGEventFlags) { session?.input(key: key, text: text, flags: flags) }
}
