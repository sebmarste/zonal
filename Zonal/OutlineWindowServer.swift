import AppKit
import Darwin

// Optional WindowServer events supplement exact AX focus; they never choose a window.
enum OutlineWindowServerEvent: Equatable, Sendable {
    case moved(UInt32), resized(UInt32), closed(UInt32), hidden(UInt32), shown(UInt32)
    case reordered(UInt32), levelChanged(UInt32)
    case frontApplicationChanged

    var windowID: UInt32? {
        switch self {
        case .moved(let id), .resized(let id), .closed(let id), .hidden(let id), .shown(let id),
             .reordered(let id), .levelChanged(let id): id
        case .frontApplicationChanged: nil
        }
    }

    static func decode(number: UInt32, payload: UnsafeRawPointer?, length: Int) -> Self? {
        if number == 1508 { return .frontApplicationChanged }
        guard [804, 806, 807, 808, 811, 815, 816].contains(number),
              length >= MemoryLayout<UInt32>.size, let payload else { return nil }
        // Callback memory expires on return and need not be aligned.
        var id: UInt32 = 0
        withUnsafeMutableBytes(of: &id) { $0.copyMemory(from: UnsafeRawBufferPointer(start: payload, count: 4)) }
        guard id != 0 else { return nil }
        switch number {
        case 804: return .closed(id)
        case 806: return .moved(id)
        case 807: return .resized(id)
        case 808: return .reordered(id)
        case 811: return .levelChanged(id)
        case 815: return .shown(id)
        case 816: return .hidden(id)
        default: return nil
        }
    }
}

// Opaque refcons are unique integer keys, never object pointers. Late callbacks after
// removal cannot dereference a released adapter, and queued delivery rechecks the key.
final class OutlineWindowServerRoutes: @unchecked Sendable {
    static let shared = OutlineWindowServerRoutes()
    typealias Handler = @MainActor @Sendable (OutlineWindowServerEvent) -> Void
    private struct Route { var windowID: UInt32?; var handler: Handler }
    private let lock = NSLock()
    private var nextToken: UInt = 0
    private var routes: [UInt: Route] = [:]

    func add(_ handler: @escaping Handler) -> UInt {
        lock.withLock {
            nextToken += 1
            routes[nextToken] = Route(handler: handler)
            return nextToken
        }
    }

    func remove(_ token: UInt) { lock.withLock { _ = routes.removeValue(forKey: token) } }
    func observe(_ id: UInt32?, token: UInt) { lock.withLock { routes[token]?.windowID = id } }
    func handler(for token: UInt, event: OutlineWindowServerEvent) -> Handler? {
        lock.withLock {
            guard let route = routes[token], event.windowID == nil || event.windowID == route.windowID else { return nil }
            return route.handler
        }
    }
}

private typealias OutlineWindowServerCallback = @convention(c) (
    UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?
) -> Void

private let outlineWindowServerCallback: OutlineWindowServerCallback = { number, payload, length, context in
    guard let context,
          let event = OutlineWindowServerEvent.decode(number: number, payload: payload, length: length) else { return }
    let token = UInt(bitPattern: context)
    DispatchQueue.main.async {
        OutlineWindowServerRoutes.shared.handler(for: token, event: event)?(event)
    }
}

private final class OutlineWindowServerSymbols: @unchecked Sendable {
    typealias Connection = @convention(c) () -> Int32
    typealias Registration = @convention(c) (OutlineWindowServerCallback, UInt32, UnsafeMutableRawPointer?) -> Int32
    typealias Request = @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> Int32
    typealias Level = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int64>) -> Int32
    typealias CreateTransaction = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    typealias SetLevel = @convention(c) (CFTypeRef, UInt32, Int32) -> Void
    typealias Order = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
    typealias Commit = @convention(c) (CFTypeRef, Int32) -> Void
    typealias SubLevel = @convention(c) (Int32, UInt32) -> Int32

    let handle: UnsafeMutableRawPointer
    let connection: Connection
    let register: Registration
    let unregister: Registration
    let request: Request
    let level: Level?
    let createTransaction: CreateTransaction?
    let setLevel: SetLevel?
    let order: Order?
    let commit: Commit?
    let subLevel: SubLevel?
    let setSubLevel: SetLevel?

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let connection = symbol("SLSMainConnectionID", as: Connection.self),
              let register = symbol("SLSRegisterNotifyProc", as: Registration.self),
              let unregister = symbol("SLSRemoveNotifyProc", as: Registration.self),
              let request = symbol("SLSRequestNotificationsForWindows", as: Request.self) else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.connection = connection
        self.register = register
        self.unregister = unregister
        self.request = request
        level = symbol("SLSGetWindowLevel", as: Level.self)
        createTransaction = symbol("SLSTransactionCreate", as: CreateTransaction.self)
        setLevel = symbol("SLSTransactionSetWindowLevel", as: SetLevel.self)
        order = symbol("SLSTransactionOrderWindow", as: Order.self)
        commit = symbol("SLSTransactionCommit", as: Commit.self)
        subLevel = symbol("SLSGetWindowSubLevel", as: SubLevel.self)
        setSubLevel = symbol("SLSTransactionSetWindowSubLevel", as: SetLevel.self)
    }

    deinit { dlclose(handle) }
}

@MainActor
final class OutlineWindowServer {
    private let symbols: OutlineWindowServerSymbols?
    private var token: UInt?
    private var registeredEvents: [UInt32] = []
    private(set) var observedWindowID: UInt32?
    private(set) var callbackCount = 0
    private(set) var lastEvent: OutlineWindowServerEvent?
    private(set) var orderFailures = 0
    private(set) var lastOrderFailure: String?
    var isSupported: Bool { symbols != nil }
    var isRunning: Bool { token != nil }

    init(loadPrivateSymbols: Bool = true) {
        symbols = loadPrivateSymbols ? OutlineWindowServerSymbols() : nil
    }

    @discardableResult
    func start(onEvent: @escaping @MainActor @Sendable (OutlineWindowServerEvent) -> Void) -> Bool {
        stop()
        guard let symbols else { return false }
        let token = OutlineWindowServerRoutes.shared.add { [weak self] event in
            guard let self else { return }
            self.callbackCount += 1
            self.lastEvent = event
            onEvent(event)
        }
        self.token = token
        let context = UnsafeMutableRawPointer(bitPattern: token)
        for number: UInt32 in [804, 806, 807, 808, 811, 815, 816, 1508] {
            guard symbols.register(outlineWindowServerCallback, number, context) == 0 else {
                stop()
                return false
            }
            registeredEvents.append(number)
        }
        return true
    }

    @discardableResult
    func observe(windowID: UInt32?) -> Bool {
        guard let token, let symbols else { return false }
        if observedWindowID == windowID { return true }
        guard windowID != 0 else { return false }
        let ids = windowID.map { [$0] } ?? []
        let result = ids.withUnsafeBufferPointer { symbols.request(symbols.connection(), $0.baseAddress, Int32($0.count)) }
        guard result == 0 else { return false }
        observedWindowID = windowID
        OutlineWindowServerRoutes.shared.observe(windowID, token: token)
        return true
    }

    func stop() {
        guard let token else { return }
        OutlineWindowServerRoutes.shared.remove(token)
        if let symbols {
            let context = UnsafeMutableRawPointer(bitPattern: token)
            for number in registeredEvents { _ = symbols.unregister(outlineWindowServerCallback, number, context) }
            _ = symbols.request(symbols.connection(), nil, 0)
        }
        registeredEvents.removeAll()
        observedWindowID = nil
        self.token = nil
    }

    // AppKit maintains visibility bookkeeping; the transaction keeps the decoration
    // at the target's level and directly adjacent to its exact WindowServer ID.
    func level(for windowID: UInt32) -> NSWindow.Level? {
        guard windowID != 0, let symbols, let getLevel = symbols.level else { return nil }
        var rawLevel: Int64 = 0
        guard getLevel(symbols.connection(), windowID, &rawLevel) == 0,
              let rawValue = Int(exactly: rawLevel) else { return nil }
        return NSWindow.Level(rawValue: rawValue)
    }

    @discardableResult
    func order(panel: NSPanel, relativeTo targetID: UInt32, ordering: NSWindow.OrderingMode = .above) -> Bool {
        var succeeded = false
        lastOrderFailure = nil
        defer { if !succeeded { orderFailures += 1 } }
        func failed(_ stage: String) -> Bool { lastOrderFailure = stage; return false }
        guard targetID != 0, panel.windowNumber > 0 else { return failed("invalid-window-id") }
        guard let symbols, let getLevel = symbols.level, let create = symbols.createTransaction,
              let setLevel = symbols.setLevel, let order = symbols.order, let commit = symbols.commit else {
            return failed("symbols-unavailable")
        }
        let cid = symbols.connection()
        var rawLevel: Int64 = 0
        let levelResult = getLevel(cid, targetID, &rawLevel)
        guard levelResult == 0 else { return failed("get-target-level:\(levelResult)") }
        guard let targetLevel = Int32(exactly: rawLevel) else { return failed("target-level-out-of-range") }
        guard let transaction = create(cid)?.takeRetainedValue() else { return failed("create-transaction") }
        panel.level = NSWindow.Level(rawValue: Int(targetLevel))
        panel.order(ordering, relativeTo: Int(targetID))
        guard let ownID = UInt32(exactly: panel.windowNumber) else { return failed("invalid-panel-id") }
        // AppKit owns position and size together. A transaction-only move can
        // expose the new origin with the old size before setFrame is flushed.
        // The transaction mutators have no reliable CGError return ABI. Upstream
        // consumers ignore their return registers; checking them rejects valid work.
        setLevel(transaction, ownID, targetLevel)
        if let getSubLevel = symbols.subLevel, let setSubLevel = symbols.setSubLevel {
            setSubLevel(transaction, ownID, getSubLevel(cid, targetID))
        }
        order(transaction, ownID, Int32(ordering.rawValue), targetID)
        commit(transaction, 0)
        succeeded = true
        return true
    }

    func detailedDiagnosticLines() -> [String] {
        ["WindowServer outline: supported=\(isSupported) running=\(isRunning) target=\(observedWindowID.map(String.init) ?? "none") callbacks=\(callbackCount) orderFailures=\(orderFailures) lastOrderFailure=\(lastOrderFailure ?? "none") lastEvent=\(lastEvent.map { String(describing: $0) } ?? "none")"]
    }

    deinit {
        if let token {
            OutlineWindowServerRoutes.shared.remove(token)
            if let symbols {
                let context = UnsafeMutableRawPointer(bitPattern: token)
                for number in registeredEvents { _ = symbols.unregister(outlineWindowServerCallback, number, context) }
                _ = symbols.request(symbols.connection(), nil, 0)
            }
        }
    }
}
