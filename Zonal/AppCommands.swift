import AppKit
import ApplicationServices
import Carbon

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
    var keyEquivalent = ""
    var keyModifiers: NSEvent.ModifierFlags = []
    var id: [Int] { path.indices }
    var title: String { path.titles.last ?? "" }
    var isAppleMenu: Bool { path.titles.count == 1 && ["Apple", "\u{F8FF}"].contains(title) }
    var descendants: [AppCommandNode] { children.flatMap { [$0] + $0.descendants } }
}

// AX calls have a per-message timeout and scans have a total budget; neither runs on the UI thread.
final class AppCommandReader: @unchecked Sendable {
    let app: AXUIElement
    let pid: pid_t
    let window: AXUIElement
    let queue = DispatchQueue(label: "Zonal app commands", qos: .userInitiated)
    private let attribute: (AXUIElement, String) -> CFTypeRef?
    private let press: (AXUIElement) -> AXError
    init(pid: pid_t, window: AXUIElement,
         attribute: @escaping (AXUIElement, String) -> CFTypeRef? = commandAttribute,
         press: @escaping (AXUIElement) -> AXError = { AXUIElementPerformAction($0, kAXPressAction as CFString) }) {
        self.pid = pid
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
    // Poll readiness only; this never sends an action or retries AXPress.
    func waitForContext(transitionPID: pid_t? = nil, allowWindowTransition: Bool = false, timeout: TimeInterval = 0.8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if contextIsCurrent() { return true }
            if windowContextMatches() == false && !allowWindowTransition { return false }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.15)
            if let focused = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var focusedPID: pid_t = 0
                AXUIElementGetPid(focused as! AXUIElement, &focusedPID)
                if focusedPID != pid && focusedPID != transitionPID && focusedPID != ProcessInfo.processInfo.processIdentifier { return false }
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
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
                                             shortcut: shortcut, children: nested, isMenu: menu,
                                             keyEquivalent: Self.shortcutKey(character: character, glyph: glyph).key,
                                             keyModifiers: Self.shortcutModifiers(mods)))
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
    static func shortcutModifiers(_ value: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if value & 1 != 0 { flags.insert(.shift) }
        if value & 2 != 0 { flags.insert(.option) }
        if value & 4 != 0 { flags.insert(.control) }
        if value & 8 == 0 { flags.insert(.command) }
        return flags
    }
    static func shortcutKey(character: String, glyph: Int) -> (key: String, display: String) {
        if !character.isEmpty { return (character.lowercased(), character.uppercased()) }
        let function: Int?
        switch glyph {
        case Int(kMenuF1Glyph)...Int(kMenuF12Glyph): function = glyph - Int(kMenuF1Glyph) + 1
        case Int(kMenuF13Glyph)...Int(kMenuF15Glyph): function = glyph - Int(kMenuF13Glyph) + 13
        case Int(kMenuF16Glyph)...Int(kMenuF19Glyph): function = glyph - Int(kMenuF16Glyph) + 16
        default: function = nil
        }
        if let function { return (String(UnicodeScalar(0xF704 + function - 1)!), "F\(function)") }
        // Carbon menu glyph IDs differ from key codes and Unicode characters.
        let keys: [Int: (UInt32, String)] = [
            Int(kMenuTabRightGlyph): (0x09, "⇥"), Int(kMenuTabLeftGlyph): (0x19, "⇤"),
            Int(kMenuEnterGlyph): (0x03, "⌤"), Int(kMenuReturnGlyph): (0x0D, "↩"),
            Int(kMenuReturnR2LGlyph): (0x0D, "↩"), Int(kMenuNonmarkingReturnGlyph): (0x0D, "↩"),
            Int(kMenuSpaceGlyph): (0x20, "Space"), Int(kMenuDeleteLeftGlyph): (0x08, "⌫"),
            Int(kMenuDeleteRightGlyph): (0x7F, "⌦"), Int(kMenuEscapeGlyph): (0x1B, "⎋"),
            Int(kMenuClearGlyph): (0xF739, "⌧"), Int(kMenuLeftArrowGlyph): (0xF702, "←"),
            Int(kMenuRightArrowGlyph): (0xF703, "→"), Int(kMenuUpArrowGlyph): (0xF700, "↑"),
            Int(kMenuDownArrowGlyph): (0xF701, "↓"), Int(kMenuPageUpGlyph): (0xF72C, "⇞"),
            Int(kMenuPageDownGlyph): (0xF72D, "⇟"), Int(kMenuNorthwestArrowGlyph): (0xF729, "↖"),
            Int(kMenuSoutheastArrowGlyph): (0xF72B, "↘"), Int(kMenuHelpGlyph): (0xF746, "Help")]
        if let (scalar, display) = keys[glyph] { return (String(UnicodeScalar(scalar)!), display) }
        return ("", glyph == 0 ? "" : glyph == Int(kMenuCapsLockGlyph) ? "⇪" : "[key \(glyph)]")
    }
    static func glyph(_ value: Int) -> String { shortcutKey(character: "", glyph: value).display }
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

// Commands retain their own captured context after the menu session is dismissed.
@MainActor
final class AppCommandExecution {
    let reader: AppCommandReader
    var focusWindow: (@escaping @MainActor @Sendable () -> Void) -> Void = { $0() }
    var menuOwnedFocus = false
    weak var menuKeyWindow: NSWindow?
    var onStatus: ((String) -> Void)?
    init(reader: AppCommandReader) { self.reader = reader }
    func execute(_ node: AppCommandNode) {
        let begin: @MainActor @Sendable () -> Void = { [self] in
            reader.queue.async { [self, reader] in
                let ready = reader.waitForContext(transitionPID: ProcessInfo.processInfo.processIdentifier)
                let error = ready ? reader.execute(node) : "The focused window changed or focus did not settle. Reopen the window menu."
                TabContextMenuSession.deliver { [self] in
                    onStatus?(error.map { "not-confirmed: \($0)" } ?? "confirmed")
                    if let error {
                        let alert = NSAlert()
                        alert.messageText = "App Command Not Confirmed"
                        alert.informativeText = error
                        alert.runModal()
                    }
                }
            }
        }
        // Only our own dismissed menu may need to return focus to its captured window.
        // Never take focus back from another app or another document.
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if menuOwnedFocus, active == ProcessInfo.processInfo.processIdentifier,
           (NSApp.keyWindow == nil || NSApp.keyWindow === menuKeyWindow), reader.windowContextMatches() == true {
            focusWindow(begin)
        } else { begin() }
    }
}

struct AppCommandFocusPolicy {
    static func allowsApp(active: pid_t?, target: pid_t?, opening: pid_t?, preparing: Bool, menuOwnsFocus: Bool) -> Bool {
        guard let active, let target else { return false }
        return active == target || (preparing && active == opening) || menuOwnsFocus
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

// These are presentation hints only; command identity always uses the full AX path.
struct AppCommandSymbol {
    static func name(path: AppCommandPath, isMenu: Bool) -> String? {
        let title = (path.titles.last ?? "").lowercased()
            .replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let categories = ["file": "doc", "edit": "pencil", "view": "eye", "window": "macwindow",
            "help": "questionmark.circle", "history": "clock.arrow.circlepath", "bookmarks": "bookmark",
            "tabs": "square.on.square", "extensions": "puzzlepiece.extension", "tools": "wrench.and.screwdriver",
            "format": "textformat", "go": "arrow.right"]
        if isMenu, let symbol = categories[title] { return symbol }
        return ["find": "magnifyingglass", "find next": "arrow.down", "find previous": "arrow.up",
            "copy": "doc.on.doc", "cut": "scissors", "paste": "doc.on.clipboard",
            "undo": "arrow.uturn.backward", "redo": "arrow.uturn.forward", "select all": "checkmark.square",
            "open": "folder", "save": "square.and.arrow.down", "save as": "square.and.arrow.down",
            "print": "printer", "duplicate": "plus.square.on.square", "delete": "trash",
            "new tab": "plus.square", "new window": "macwindow.badge.plus", "close tab": "xmark",
            "close window": "xmark", "settings": "gearshape", "preferences": "gearshape",
            "reload": "arrow.clockwise", "reload this page": "arrow.clockwise",
            "zoom in": "plus.magnifyingglass", "zoom out": "minus.magnifyingglass"][title]
    }
}

@MainActor
struct TabMenuAppearance {
    static let iconSize = NSSize(width: 16, height: 16)
    static func icon(_ source: NSImage?) -> NSImage? {
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(iconSize.width / source.size.width, iconSize.height / source.size.height)
        let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let image = NSImage(size: iconSize, flipped: false) { bounds in
            source.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = source.isTemplate
        return image
    }
}

// Native custom menu views do not receive normal menu typing. Keep text filtering
// on the existing input tap; AppKit retains unfiltered navigation and submenus.
final class TabMenuSearchField: NSSearchField {
    var clear: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
        var shortcut: String { (item as? ZoneTabMenuItem)?.displayedShortcut ?? "" }
        var enabled: Bool { item?.isEnabled == true && item?.action != nil }
    }
    private final class Table: NSTableView {
        override var acceptsFirstResponder: Bool { false }
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            NSApp.preventWindowOrdering()
            super.mouseDown(with: event)
        }
    }
    private final class SelectedRow: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    let table: NSTableView = Table()
    private(set) var rows: [Row] = []
    var activate: ((NSMenuItem) -> Void)?
    var contentHeight: CGFloat { rows.reduce(0) { $0 + ($1.item == nil ? 8 : 28) } }
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
    func fit(maximumHeight: CGFloat) {
        frame.size.height = min(maximumHeight, contentHeight)
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
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
        let cell = TabMenuResultCell(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 28))
        cell.textField?.stringValue = rows[row].title
        cell.textField?.textColor = rows[row].enabled ? .labelColor : .disabledControlTextColor
        cell.shortcut.stringValue = rows[row].shortcut
        cell.shortcut.isEnabled = rows[row].enabled
        cell.imageView?.image = rows[row].item?.image
        cell.toolTip = [rows[row].title, rows[row].shortcut].filter { !$0.isEmpty }.joined(separator: "    ")
        cell.setAccessibilityLabel(cell.toolTip)
        return cell
    }

}

@MainActor
final class TabMenuResultCell: NSTableCellView {
    let shortcut = NSTextField(labelWithString: "")
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { shortcut.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .systemFont(ofSize: 13)
        shortcut.alignment = .right
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        for view in [icon, label, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon; textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -16),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class TabContextMenuSession: NSObject, NSMenuDelegate {
    let menu: NSMenu
    let reader: AppCommandReader?
    let execution: AppCommandExecution?
    let zonalItems: [NSMenuItem]
    let search = TabMenuSearchField(frame: NSRect(x: 12, y: 8, width: 296, height: 26))
    let results = TabMenuResultsView()
    private let searchItem = NSMenuItem()
    private let resultsItem = NSMenuItem()
    private var nodes: [AppCommandNode] = []
    private var closed = false
    private var reopenAfterQuery = false
    private var didNotifyClose = false
    private var preparationTimeout: Task<Void, Never>?
    var focusBeforeRead: (@escaping @MainActor @Sendable () -> Void) -> Void = { $0() }
    var cancelFocus: (() -> Void)?
    var transitionPID: pid_t?
    var onPreparationFailure: (() -> Void)?
    var preparationTimeoutDuration: Duration = .seconds(3)
    private var applicationName: String?
    private var applicationIcon: NSImage?
    var maximumResultsHeight: CGFloat = 420
    // Injection keeps anchoring and tracking transitions testable without a live GUI.
    var popUp: (NSMenu, NSMenuItem?, CGPoint) -> Void = { menu, item, point in
        menu.popUp(positioning: item, at: point, in: nil)
    }
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

    init(menu: NSMenu, reader: AppCommandReader?, application: NSRunningApplication? = nil, unavailableReason: String = "App commands require the focused window") {
        self.menu = menu
        self.reader = reader
        execution = reader.map(AppCommandExecution.init)
        applicationName = application?.localizedName
        applicationIcon = application?.icon
        self.unavailableReason = unavailableReason
        zonalItems = menu.items.filter { !$0.isSeparatorItem }
        super.init()
        for item in zonalItems { item.image = TabMenuAppearance.icon(item.image) }
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
        preparationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: self?.preparationTimeoutDuration ?? .seconds(3)) } catch { return }
            guard let self, self.isPreparing else { return }
            self.cancel(); self.notifyClosed(); self.onPreparationFailure?()
        }
        focusBeforeRead { [weak self] in
            guard let self, !self.closed else { return }
            let transitionPID = self.transitionPID
            reader.queue.async { [weak self] in
                let ready = reader.waitForContext(transitionPID: transitionPID, allowWindowTransition: true)
                let (nodes, complete) = ready ? reader.read() : ([], false)
                Self.deliver {
                    guard let self, !self.closed else { return }
                    self.preparationTimeout?.cancel(); self.preparationTimeout = nil
                    guard ready else {
                        self.cancel(); self.notifyClosed(); self.onPreparationFailure?(); return
                    }
                    self.setNodes(nodes, complete: complete)
                    self.isPreparing = false
                    self.onQueryChanged?()
                    guard self.canPresent() else { self.cancel(); self.notifyClosed(); return }
                    completion()
                }
            }
        }
    }
    func present(at point: CGPoint, visibleFrame: CGRect) {
        guard !closed, canPresent() else { cancel(); notifyClosed(); return }
        opensUpward = TabContextMenuPolicy.opensUpward(at: point, visibleFrame: visibleFrame, menuHeight: menu.size.height)
        let space = opensUpward ? visibleFrame.maxY - point.y : point.y - visibleFrame.minY
        maximumResultsHeight = min(420, max(28, space - 80))
        repeat {
            reopenAfterQuery = false
            rebuild()
            popUp(menu, opensUpward ? menu.items.last : menu.items.first, point)
            // AppKit does not support resizing custom item views while tracking.
            // End that pass, then re-present the same snapshot at the original anchor.
        } while reopenAfterQuery && !closed && canPresent()
        if !closed { cancel(); notifyClosed() }
    }
    func setQuery(_ value: String) {
        guard !closed, query != value else { return }
        query = value
        search.stringValue = value
        onQueryChanged?()
        if isTracking {
            // Keep Return bound to the latest query even before the tracking pass ends.
            if !query.isEmpty { updateResults() }
            reopenAfterQuery = true
            menu.cancelTrackingWithoutAnimation()
        } else { rebuild() }
    }
    func setNodes(_ value: [AppCommandNode], complete: Bool) {
        // The menu is a frozen snapshot while tracking: no loading-induced resize,
        // scroll changes, replaced mouse targets, or lost keyboard selection.
        guard !closed, !isTracking else { return }
        nodes = value.filter { !$0.isAppleMenu }
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
        guard !isTracking else { return }
        menu.removeAllItems()
        if query.isEmpty {
            var app = nodes.map { item(for: $0, fullPath: false) }
            if reader == nil { app = [info(unavailableReason)] }
            else if app.isEmpty { app = [info("App did not expose any menus")] }
            appendSections([.search: [searchItem], .zonal: zonalItems, .app: app])
            menu.update()
            return
        }
        updateResults()
        results.fit(maximumHeight: maximumResultsHeight)
        // The presenter anchors the Search row again after every filtering pass.
        if opensUpward { menu.addItem(resultsItem); menu.addItem(.separator()); menu.addItem(searchItem) }
        else { menu.addItem(searchItem); menu.addItem(.separator()); menu.addItem(resultsItem) }
        menu.update()
    }
    private func updateResults() {
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
    }
    private func item(for node: AppCommandNode, fullPath: Bool) -> NSMenuItem {
        let title = fullPath ? node.path.display : node.title
        let execution = self.execution
        let root = menu
        let item = ZoneTabMenuItem(title: title) { [weak root] in
            guard let execution, !node.isMenu, node.enabled else { return }
            root?.cancelTracking()
            DispatchQueue.main.async { execution.execute(node) }
        }
        item.isEnabled = node.enabled
        item.displayedShortcut = node.shortcut
        item.keyEquivalent = node.keyEquivalent
        item.keyEquivalentModifierMask = node.keyModifiers
        item.allowsAutomaticKeyEquivalentLocalization = false
        item.allowsAutomaticKeyEquivalentMirroring = false
        item.toolTip = node.path.display + (node.shortcut.isEmpty ? "" : "    " + node.shortcut)
        if let symbol = AppCommandSymbol.name(path: node.path, isMenu: node.isMenu) {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        } else if node.path.titles.count == 1, node.title == applicationName {
            item.image = applicationIcon
        }
        item.image = TabMenuAppearance.icon(item.image)
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
        guard menu === self.menu else { return }
        execution?.menuOwnedFocus = execution?.menuOwnedFocus == true || ownsMenuFocus || isTracking
        execution?.menuKeyWindow = ownsMenuFocus ? NSApp.keyWindow : nil
        isTracking = false
        if !reopenAfterQuery { closed = true; notifyClosed() }
    }
    private func notifyClosed() {
        guard !didNotifyClose else { return }
        didNotifyClose = true; onClose?()
    }
    var ownsMenuFocus: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return false }
        let key = NSApp.keyWindow
        return key == nil || key === search.window || key === results.window
    }
    func cancel() {
        if isPreparing { cancelFocus?() }
        preparationTimeout?.cancel(); preparationTimeout = nil
        closed = true; isPreparing = false; isTracking = false; reopenAfterQuery = false
        menu.cancelTracking()
    }
    private func activate(_ item: NSMenuItem) {
        guard !closed, item.isEnabled, item.action != nil else { return }
        // Capture the exact handler before menu dismissal releases its weak target.
        let target = item.target
        let action = item.action
        execution?.menuOwnedFocus = execution?.menuOwnedFocus == true || ownsMenuFocus || isTracking
        execution?.menuKeyWindow = ownsMenuFocus ? NSApp.keyWindow : nil
        closed = true; reopenAfterQuery = false
        menu.cancelTracking()
        notifyClosed()
        DispatchQueue.main.async {
            if let command = item as? ZoneTabMenuItem { command.invoke() }
            else if let action { NSApp.sendAction(action, to: target, from: item) }
        }
    }
    func input(key: Int64, text: String?, flags: CGEventFlags) {
        guard !closed else { return }
        if key == 53 {
            if isPreparing { cancel(); notifyClosed() }
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
    private var openingPID: pid_t?
    private var openingWindow: AXUIElement?
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
    func configure(_ menu: NSMenu, expectedWindow: AXUIElement,
                   focusWindow: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void = { $0() },
                   cancelFocus: @escaping () -> Void = {}) {
        close()
        cancelFocus()
        var targetPID: pid_t = 0
        AXUIElementGetPid(expectedWindow, &targetPID)
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        openingPID = active
        if let active, let focused = commandAttribute(AXUIElementCreateApplication(active), kAXFocusedWindowAttribute),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            openingWindow = (focused as! AXUIElement)
        }
        let reader = AppCommandReader(pid: targetPID, window: expectedWindow)
        let valid = active == targetPID && reader.contextIsCurrent()
        lastInventory = "Preparing focused window menus"
        let session = TabContextMenuSession(menu: menu, reader: reader, application: NSRunningApplication(processIdentifier: targetPID))
        self.session = session
        pid = targetPID
        session.transitionPID = active
        session.cancelFocus = cancelFocus
        if !valid { session.focusBeforeRead = focusWindow }
        session.execution?.focusWindow = focusWindow
        session.execution?.onStatus = { [weak self] status in self?.lastInventory += " execution=\(status)" }
        session.onPreparationFailure = { [weak self] in
            self?.lastInventory = "Menu focus was not confirmed"
            let alert = NSAlert()
            alert.messageText = "Window Focus Not Confirmed"
            alert.informativeText = "Zonal could not verify focus on the clicked window. Reopen its tab menu."
            alert.runModal()
        }
        session.canPresent = { [weak self, weak session] in
            guard let self, self.session === session else { return false }
            return self.currentAppIsAllowed() && reader.windowContextMatches() != false
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
                if !self.currentAppIsAllowed() { self.close() }
            }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyFocus() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func currentAppIsAllowed() -> Bool {
        AppCommandFocusPolicy.allowsApp(active: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            target: pid, opening: openingPID, preparing: session?.isPreparing == true,
            menuOwnsFocus: isVisible && session?.ownsMenuFocus == true)
    }
    private func verifyFocus() {
        guard isCapturingInput, let session, let reader = session.reader, !checkingFocus else { return }
        if !currentAppIsAllowed() { close(); return }
        guard !session.isPreparing else { return }
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
        if CFEqual(window, reader.window) { return }
        var windowPID: pid_t = 0
        AXUIElementGetPid(window, &windowPID)
        if session?.isPreparing == true {
            if windowPID == pid { return }
            if let openingWindow, CFEqual(window, openingWindow) { return }
        }
        if isVisible, session?.ownsMenuFocus == true, windowPID == ProcessInfo.processInfo.processIdentifier { return }
        close()
    }
    func close() {
        let current = session
        session = nil
        isVisible = false
        openingPID = nil; openingWindow = nil
        timer?.invalidate(); timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil; checkingFocus = false
        current?.cancel()
        onVisibilityChanged?()
    }
    func input(key: Int64, text: String?, flags: CGEventFlags) { session?.input(key: key, text: text, flags: flags) }
}
