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
    var isAppleMenu: Bool { path.titles.count == 1 && ["Apple", "\u{F8FF}"].contains(title) }
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
        var nodes = descend(bar as! AXUIElement, path: AppCommandPath(indices: [], titles: []), depth: 0, recursive: false).filter { !$0.isAppleMenu }
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
// on the existing input tap; AppKit retains unfiltered navigation and submenus.
final class TabMenuSearchField: NSSearchField {
    var clear: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        if convert(event.locationInWindow, from: nil).x > bounds.maxX - 24 { clear?() }
    }
}

// Search stays inside the native menu, but uses a table for public, explicit
// selection/scrolling instead of private NSMenu highlight methods.
@MainActor
final class TabMenuResultsView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        var item: NSMenuItem?
        var title: String { item?.title ?? "" }
        var enabled: Bool { item?.isEnabled == true && item?.action != nil }
    }
    private final class Table: NSTableView { override var acceptsFirstResponder: Bool { false } }
    private final class SelectedRow: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }
    let table: NSTableView = Table()
    private(set) var rows: [Row] = []
    var activate: ((NSMenuItem) -> Void)?
    var selectedItem: NSMenuItem? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].item : nil
    }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = 320
        table.addTableColumn(column)
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        table.autoresizingMask = [.width]
        documentView = table
        table.setAccessibilityLabel("Matching commands")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRows(_ value: [Row]) {
        rows = value
        table.reloadData()
        if let first = rows.firstIndex(where: \.enabled) { select(first) }
        else { table.deselectAll(nil) }
    }
    private func select(_ index: Int) {
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    func move(_ direction: Int) {
        let candidates = rows.indices.filter { rows[$0].enabled }
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex(of: table.selectedRow) ?? 0
        select(candidates[min(max(0, current + direction), candidates.count - 1)])
    }
    @objc private func clicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), rows[row].enabled, let item = rows[row].item else { return }
        activate?(item)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].enabled }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].item == nil ? 8 : 28 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectedRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: rows[row].title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = rows[row].enabled ? .labelColor : .disabledControlTextColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = rows[row].title
        let cell = NSTableCellView(frame: NSRect(x: 0,y: 0,width: tableView.bounds.width,height: 28))
        label.frame = cell.bounds.insetBy(dx: 12, dy: 5)
        label.autoresizingMask = [.width]
        cell.addSubview(label); cell.textField = label
        return cell
    }
}

@MainActor
final class TabContextMenuSession: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let reader: AppCommandReader?
    let zonalItems: [NSMenuItem]
    let search = TabMenuSearchField(frame: NSRect(x: 12, y: 8, width: 296, height: 26))
    let results = TabMenuResultsView()
    private let searchItem = NSMenuItem()
    private let resultsItem = NSMenuItem()
    private var nodes: [AppCommandNode] = []
    private var closed = false
    private var browseHeight: CGFloat?
    private(set) var isTracking = false
    private(set) var isPreparing = false
    var opensUpward = false
    private(set) var query = ""
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onPreparing: (() -> Void)?
    var onInventory: ((String) -> Void)?
    var onQueryChanged: (() -> Void)?
    var canPresent: () -> Bool = { true }
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
        resultsItem.view = results
        results.activate = { [weak self] item in self?.activate(item) }
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
    func prepare(_ completion: @escaping @MainActor @Sendable () -> Void) {
        guard !closed else { return }
        guard let reader else { completion(); return }
        isPreparing = true; onPreparing?()
        reader.queue.async { [weak self] in
            let (nodes, complete) = reader.read()
            Self.deliver {
                guard let self, !self.closed else { return }
                self.setNodes(nodes, complete: complete)
                self.isPreparing = false
                self.onQueryChanged?()
                guard self.canPresent() else { self.cancel(); self.onClose?(); return }
                completion()
            }
        }
    }
    func setQuery(_ value: String) {
        guard !closed else { return }
        query = value
        search.stringValue = value
        rebuild()
        onQueryChanged?()
    }
    func setNodes(_ value: [AppCommandNode], complete: Bool) {
        // The menu is a frozen snapshot while tracking: no loading-induced resize,
        // scroll changes, replaced mouse targets, or lost keyboard selection.
        guard !closed, !isTracking else { return }
        nodes = value.filter { !$0.isAppleMenu }
        browseHeight = nil
        onInventory?("categories=\(nodes.count) commands=\(nodes.flatMap { [$0] + $0.descendants }.filter { !$0.isMenu }.count) complete=\(complete)")
        rebuild()
    }
    private func appendSections(_ sections: [TabContextMenuPolicy.Section: [NSMenuItem]]) {
        for section in TabContextMenuPolicy.sections(opensUpward: opensUpward) {
            let items = sections[section] ?? []
            guard !items.isEmpty else { continue }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
    }
    func rebuild() {
        menu.removeAllItems()
        if query.isEmpty || browseHeight == nil {
            var app = nodes.map { item(for: $0, fullPath: false) }
            if reader == nil { app = [info(unavailableReason)] }
            else if app.isEmpty { app = [info("App did not expose any menus")] }
            appendSections([.search: [searchItem], .zonal: zonalItems, .app: app])
            menu.update()
            browseHeight = menu.size.height
            if query.isEmpty { return }
            menu.removeAllItems()
        }
        let zonal = zonalItems.filter { matches($0.title) }
        let app = nodes.flatMap { [$0] + $0.descendants }
            .filter { !$0.isMenu && matches($0.path.display + " " + $0.shortcut) }
            .map { item(for: $0, fullPath: true) }
        let groups = opensUpward ? [app, zonal] : [zonal, app]
        var rows: [TabMenuResultsView.Row] = []
        for group in groups where !group.isEmpty {
            if !rows.isEmpty { rows.append(.init(item: nil)) }
            rows += group.map { .init(item: $0) }
        }
        if rows.isEmpty { rows = [.init(item: info("No matching commands"))] }
        results.setRows(rows)
        results.frame.size.height = 24
        // Preserve the exact menu height and Search-row anchor while filtering.
        if opensUpward { menu.addItem(resultsItem); menu.addItem(.separator()); menu.addItem(searchItem) }
        else { menu.addItem(searchItem); menu.addItem(.separator()); menu.addItem(resultsItem) }
        results.frame.size.height = max(24, 24 + (browseHeight ?? menu.size.height) - menu.size.height)
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
            for child in node.children { submenu.addItem(self.item(for: child, fullPath: false)) }
            if submenu.items.isEmpty { submenu.addItem(info("No available commands")) }
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
        guard menu === self.menu else { return }
        isTracking = true; onOpen?()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { closed = true; isTracking = false; onClose?() }
    }
    func cancel() { closed = true; isPreparing = false; isTracking = false; menu.cancelTracking() }
    private func activate(_ item: NSMenuItem) {
        guard !closed, item.isEnabled, item.action != nil else { return }
        // Capture the exact handler before menu dismissal releases its weak target.
        let target = item.target
        let action = item.action
        closed = true
        menu.cancelTracking()
        DispatchQueue.main.async {
            if let command = item as? ZoneTabMenuItem { command.invoke() }
            else if let action { NSApp.sendAction(action, to: target, from: item) }
        }
    }
    func input(key: Int64, text: String?, flags: CGEventFlags) {
        guard !closed else { return }
        if key == 53 {
            if isPreparing { cancel(); onClose?() }
            else { setQuery("") }
            return
        }
        if [36, 76].contains(key), !query.isEmpty {
            if !isPreparing, let item = results.selectedItem { activate(item) }
        } else if key == 125 { results.move(1) }
        else if key == 126 { results.move(-1) }
        else if [51, 117].contains(key) {
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
    var isCapturingInput: Bool { isVisible || session?.isPreparing == true }
    var isFiltering: Bool { session?.isPreparing == true || session?.query.isEmpty == false }
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
        session.canPresent = { [weak self, weak session] in
            guard let self, self.session === session else { return false }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == active && reader?.windowContextMatches() != false
        }
        session.onPreparing = { [weak self] in self?.startWatching(); self?.onVisibilityChanged?() }
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
        guard timer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturingInput else { return }
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
        guard isCapturingInput, let session, let reader = session.reader, !checkingFocus else { return }
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
        guard isCapturingInput, let reader = session?.reader, let window else { return }
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
