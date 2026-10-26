import Darwin
import Foundation

enum LocalAutomationProtocol {
    static let currentVersion = 2
    static let help = """
    Zonal local API v2
    Usage: Zonal --automation <command> [argument]

    Read: status, health, windows, zones, debug-state, diagnostics, doctor
    Switcher: show-global (All Windows), show-zone (By Zone), next, previous, confirm, cancel
    Windows: focus-previous, focus-zone <zone-id-or-name>, focus-next-in-zone, focus-previous-in-zone
             focus-bundle <bundle-id>, focus-assignment <uuid>, move-focused <zone-id-or-name>
             move-focused-relative <left|right|up|down>
    Workspace: rescan, apply-profile <profile-id>, restore, open-settings
    Performance: switcher-metrics, reset-switcher-metrics
    """
    static let directoryURL = ZonalStoragePaths.current.appendingPathComponent("Automation", isDirectory: true)
    static let socketURL = directoryURL.appendingPathComponent("zonal-v2.sock")
}

enum LocalAutomationReadKind: String, Equatable {
    case status
    case health
    case windows
    case zones
    case debugState = "debug-state"
}

enum LocalAutomationCommand: Equatable {
    case read(LocalAutomationReadKind)
    case diagnostics
    case doctor
    case switcherMetrics
    case resetSwitcherMetrics
    case openSettings
    case showGlobal
    case showZone
    case next
    case previous
    case confirm
    case cancel
    case restore
    case rescan
    case applyProfile(String)
    case moveFocused(String)
    case moveFocusedRelative(SwitcherArrowKey)
    case focusZone(String)
    case focusNextInZone
    case focusPreviousInZone
    case focusAssignment(UUID)
    case focusBundle(String)
    case focusPrevious
    case invalid(String)
    case unknown

    init(name: String, arguments: [String]) {
        switch name {
        case "status": self = .read(.status)
        case "health": self = .read(.health)
        case "windows": self = .read(.windows)
        case "zones": self = .read(.zones)
        case "debug-state": self = .read(.debugState)
        case "diagnostics": self = .diagnostics
        case "doctor": self = .doctor
        case "switcher-metrics": self = .switcherMetrics
        case "reset-switcher-metrics": self = .resetSwitcherMetrics
        case "open-settings": self = .openSettings
        case "show-global": self = .showGlobal
        case "show-zone": self = .showZone
        case "next": self = .next
        case "previous": self = .previous
        case "confirm": self = .confirm
        case "cancel": self = .cancel
        case "restore": self = .restore
        case "rescan": self = .rescan
        case "focus-previous": self = .focusPrevious
        case "focus-next-in-zone": self = .focusNextInZone
        case "focus-previous-in-zone": self = .focusPreviousInZone
        case "apply-profile":
            self = arguments.first.flatMap { $0.isEmpty ? nil : $0 }
                .map(Self.applyProfile) ?? .invalid("apply-profile requires a profile ID")
        case "move-focused":
            self = arguments.first.flatMap { $0.isEmpty ? nil : $0 }
                .map(Self.moveFocused) ?? .invalid("move-focused requires a zone ID or unique name")
        case "move-focused-relative":
            self = arguments.first.flatMap(SwitcherArrowKey.init(rawValue:))
                .map(Self.moveFocusedRelative)
                ?? .invalid("move-focused-relative requires left, right, up, or down")
        case "focus-zone":
            self = arguments.first.flatMap { $0.isEmpty ? nil : $0 }
                .map(Self.focusZone) ?? .invalid("focus-zone requires a zone ID or unique name")
        case "focus-assignment":
            self = arguments.first.flatMap(UUID.init(uuidString:))
                .map(Self.focusAssignment) ?? .invalid("focus-assignment requires an assignment UUID")
        case "focus-bundle":
            self = arguments.first.flatMap { $0.isEmpty ? nil : $0 }
                .map(Self.focusBundle) ?? .invalid("focus-bundle requires a bundle identifier")
        default: self = .unknown
        }
    }
}

enum ZoneReferenceResolution: Equatable {
    case resolved(ZoneID)
    case notFound
    case ambiguous([ZoneID])
}

struct ZoneReferenceResolver {
    func resolve(_ reference: String, in zones: [Zone]) -> ZoneReferenceResolution {
        if let exactID = zones.first(where: { $0.id.rawValue == reference })?.id {
            return .resolved(exactID)
        }
        let normalizedReference = normalize(reference)
        let matches = zones.filter { normalize($0.name) == normalizedReference }
        if matches.count == 1, let id = matches.first?.id {
            return .resolved(id)
        }
        if matches.count > 1 {
            return .ambiguous(matches.map(\.id))
        }
        return .notFound
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct LocalAutomationRequest: Codable {
    var apiVersion: Int
    var id: String
    var command: String
    var arguments: [String]
}

enum LocalAutomationExecutionState: String, Codable {
    case read
    case completed
    case accepted
}

struct LocalAutomationWindow: Codable, Equatable {
    var assignmentID: String
    var bundleIdentifier: String
    var appName: String
    var zoneID: String
    var zoneName: String
    var isSelected: Bool
    var isActive: Bool
}

struct LocalAutomationZone: Codable, Equatable {
    var id: String
    var name: String
    var windowCount: Int
    var isSelected: Bool
}

struct LocalAutomationZoneReference: Codable, Equatable {
    var id: String
    var name: String
}

struct LocalAutomationProfile: Codable, Equatable {
    var id: String
    var name: String
    var isMatched: Bool
    var isLastApplied: Bool
}

struct LocalAutomationHealth: Codable, Equatable {
    var accessibilityTrusted: Bool
    var inputMonitoringGranted: Bool
    var keyboardCaptureAvailable: Bool
    var trackingActive: Bool
}

struct LocalAutomationDebugWindow: Codable, Equatable {
    var id: String
    var bundleIdentifier: String
    var assignmentID: String?
    var zoneID: String?
    var observedFrame: [Double]?
    var desiredFrame: [Double]?
    var isFullScreen: Bool
    var isMinimized: Bool
    var isManaged: Bool
    var isPlacementPending: Bool
}

struct LocalAutomationDebugState: Codable, Equatable {
    var profileID: String
    var windows: [LocalAutomationDebugWindow]
}

struct LocalAutomationResult: Codable, Equatable {
    var state: LocalAutomationExecutionState
    var health: LocalAutomationHealth?
    var displaySetup: String?
    var matchedProfile: String?
    var switcherVisible: Bool?
    var mode: String?
    var focusedBundleIdentifier: String?
    var selectedBundleIdentifier: String?
    var zone: LocalAutomationZoneReference?
    var profiles: [LocalAutomationProfile]?
    var zones: [LocalAutomationZone]?
    var windows: [LocalAutomationWindow]?
    var diagnostics: String?
    var debugState: LocalAutomationDebugState?
    var healthFindings: [ZonalHealthFinding]?
    var switcherMetrics: [SwitcherLatencySample]?

    init(
        state: LocalAutomationExecutionState,
        health: LocalAutomationHealth? = nil,
        displaySetup: String? = nil,
        matchedProfile: String? = nil,
        switcherVisible: Bool? = nil,
        mode: String? = nil,
        focusedBundleIdentifier: String? = nil,
        selectedBundleIdentifier: String? = nil,
        zone: LocalAutomationZoneReference? = nil,
        profiles: [LocalAutomationProfile]? = nil,
        zones: [LocalAutomationZone]? = nil,
        windows: [LocalAutomationWindow]? = nil,
        diagnostics: String? = nil,
        debugState: LocalAutomationDebugState? = nil,
        healthFindings: [ZonalHealthFinding]? = nil,
        switcherMetrics: [SwitcherLatencySample]? = nil
    ) {
        self.state = state
        self.health = health
        self.displaySetup = displaySetup
        self.matchedProfile = matchedProfile
        self.switcherVisible = switcherVisible
        self.mode = mode
        self.focusedBundleIdentifier = focusedBundleIdentifier
        self.selectedBundleIdentifier = selectedBundleIdentifier
        self.zone = zone
        self.profiles = profiles
        self.zones = zones
        self.windows = windows
        self.diagnostics = diagnostics
        self.debugState = debugState
        self.healthFindings = healthFindings
        self.switcherMetrics = switcherMetrics
    }
}

struct LocalAutomationError: Codable, Equatable {
    var code: String
    var message: String
}

struct LocalAutomationResponse: Codable, Equatable {
    var apiVersion: Int
    var requestID: String
    var command: String
    var ok: Bool
    var message: String
    var result: LocalAutomationResult?
    var error: LocalAutomationError?

    private enum CodingKeys: String, CodingKey {
        case apiVersion
        case requestID = "requestId"
        case command
        case ok
        case message
        case result
        case error
    }
}

enum LocalAutomationTransportError: LocalizedError {
    case socketPathTooLong
    case appUnavailable(String)
    case connectionFailed(String)
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong: "Zonal automation socket path is too long"
        case .appUnavailable(let detail): "Zonal is not available: \(detail)"
        case .connectionFailed(let detail): "Could not connect to Zonal: \(detail)"
        case .requestFailed(let detail): "Could not send command to Zonal: \(detail)"
        case .invalidResponse: "Zonal returned an invalid response"
        }
    }
}

enum LocalAutomationClient {
    static func runIfRequested() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard let markerIndex = arguments.firstIndex(of: "--automation") else { return }
        let commandIndex = arguments.index(after: markerIndex)
        guard arguments.indices.contains(commandIndex) else {
            fail("Missing automation command")
        }

        let command = arguments[commandIndex]
        let commandArguments = Array(arguments.dropFirst(commandIndex + 1))
        if command == "help" {
            FileHandle.standardOutput.write(Data((LocalAutomationProtocol.help + "\n").utf8))
            exit(EXIT_SUCCESS)
        }

        let request = LocalAutomationRequest(
            apiVersion: LocalAutomationProtocol.currentVersion,
            id: UUID().uuidString,
            command: command,
            arguments: commandArguments
        )
        do {
            let response = try LocalAutomationSocketClient().send(request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(response.ok ? EXIT_SUCCESS : EXIT_FAILURE)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

struct LocalAutomationSocketClient {
    var socketURL: URL = LocalAutomationProtocol.socketURL
    func send(_ request: LocalAutomationRequest) throws -> LocalAutomationResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalAutomationTransportError.connectionFailed(Self.lastError())
        }
        defer { Darwin.close(descriptor) }
        var noSignal = Int32(1)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        let connectionResult = try withUnixSocketAddress(path: socketURL.path) {
            Darwin.connect(descriptor, $0, $1)
        }
        guard connectionResult == 0 else {
            throw LocalAutomationTransportError.appUnavailable(Self.lastError())
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try writeAll(payload, to: descriptor)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
                if response.contains(0x0A) { break }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw LocalAutomationTransportError.requestFailed(Self.lastError())
            }
        }
        guard let newline = response.firstIndex(of: 0x0A) else {
            throw LocalAutomationTransportError.invalidResponse
        }
        return try JSONDecoder().decode(LocalAutomationResponse.self, from: response[..<newline])
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written,
                    0
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw LocalAutomationTransportError.requestFailed(Self.lastError())
                }
            }
        }
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}

@MainActor
final class LocalAutomationSocketServer {
    typealias RequestHandler = (
        LocalAutomationRequest,
        @escaping (LocalAutomationResponse) -> Void
    ) -> Void

    private struct Connection {
        var source: DispatchSourceRead
        var buffer = Data()
        var isAwaitingResponse = false
        var readSuspended = false
        var writeSource: DispatchSourceWrite?
        var output = Data()
        var written = 0
        var deadline: DispatchWorkItem?
        let id = UUID()
    }

    private let handler: RequestHandler
    private let socketURL: URL
    private let connectionTimeout: TimeInterval
    private var lockDescriptor: Int32 = -1
    private var ownsSocket = false
    private var listeningDescriptor: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    init(socketURL: URL = LocalAutomationProtocol.socketURL, connectionTimeout: TimeInterval = 5,
         handler: @escaping RequestHandler) {
        self.socketURL = socketURL
        self.connectionTimeout = connectionTimeout
        self.handler = handler
    }

    func start() throws {
        stop()
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: socketURL.deletingLastPathComponent().path
        )
        let lockFD = Darwin.open(socketURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw LocalAutomationTransportError.connectionFailed(Self.lastError()) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw LocalAutomationTransportError.connectionFailed("Another Zonal instance owns the automation socket")
        }
        lockDescriptor = lockFD
        var started = false
        defer { if !started { stop() } }
        if FileManager.default.fileExists(atPath: socketURL.path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw LocalAutomationTransportError.connectionFailed(Self.lastError()) }
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            let result = try withUnixSocketAddress(path: socketURL.path) { Darwin.connect(probe, $0, $1) }
            let failure = errno
            Darwin.close(probe)
            guard result != 0, failure == ECONNREFUSED || failure == ENOENT else {
                throw LocalAutomationTransportError.connectionFailed("Automation socket is already in use")
            }
        }
        unlink(socketURL.path)
        ownsSocket = true

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalAutomationTransportError.connectionFailed(Self.lastError())
        }
        do {
            let bindResult = try withUnixSocketAddress(path: socketURL.path) {
                Darwin.bind(descriptor, $0, $1)
            }
            guard bindResult == 0 else {
                throw LocalAutomationTransportError.connectionFailed(Self.lastError())
            }
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw LocalAutomationTransportError.connectionFailed(Self.lastError())
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw LocalAutomationTransportError.connectionFailed(Self.lastError())
            }
        } catch {
            Darwin.close(descriptor)
            unlink(socketURL.path)
            throw error
        }

        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        listeningDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        listeningSource = source
        source.resume()
        started = true
    }

    func stop() {
        for descriptor in Array(connections.keys) { closeConnection(descriptor) }
        listeningSource?.cancel()
        listeningSource = nil
        listeningDescriptor = -1
        if ownsSocket { unlink(socketURL.path); ownsSocket = false }
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private func acceptConnection() {
        let descriptor = Darwin.accept(listeningDescriptor, nil, nil)
        guard descriptor >= 0 else { return }
        guard connections.count < 64 else { Darwin.close(descriptor); return }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        var noSignal = Int32(1)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid() else {
            Darwin.close(descriptor)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readRequest(from: descriptor)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        var connection = Connection(source: source)
        let id = connection.id
        let deadline = DispatchWorkItem { [weak self] in
            guard self?.connections[descriptor]?.id == id else { return }
            self?.closeConnection(descriptor)
        }
        connection.deadline = deadline
        connections[descriptor] = connection
        source.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeout, execute: deadline)
    }

    private func readRequest(from descriptor: Int32) {
        guard var connection = connections[descriptor],
              !connection.isAwaitingResponse else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        guard count > 0 else {
            closeConnection(descriptor)
            return
        }
        connection.buffer.append(contentsOf: buffer.prefix(count))
        guard connection.buffer.count <= 1_048_576 else {
            sendFailure(
                requestID: "unknown",
                command: "unknown",
                code: "request_too_large",
                message: "Automation request exceeded 1 MB",
                to: descriptor
            )
            return
        }
        connections[descriptor] = connection
        guard let newline = connection.buffer.firstIndex(of: 0x0A) else { return }
        let requestData = connection.buffer[..<newline]
        guard let request = try? JSONDecoder().decode(LocalAutomationRequest.self, from: requestData) else {
            sendFailure(
                requestID: "unknown",
                command: "unknown",
                code: "invalid_request",
                message: "Could not decode automation request",
                to: descriptor
            )
            return
        }
        guard request.apiVersion == LocalAutomationProtocol.currentVersion else {
            sendFailure(
                requestID: request.id,
                command: request.command,
                code: "unsupported_api_version",
                message: "Unsupported API version",
                to: descriptor
            )
            return
        }
        connection.isAwaitingResponse = true
        connection.readSuspended = true
        connection.source.suspend()
        connection.buffer.removeAll()
        let id = connection.id
        connections[descriptor] = connection
        handler(request) { [weak self] response in
            guard self?.connections[descriptor]?.id == id else { return }
            self?.send(response, to: descriptor)
        }
    }

    private func sendFailure(
        requestID: String,
        command: String,
        code: String,
        message: String,
        to descriptor: Int32
    ) {
        send(
            LocalAutomationResponse(
                apiVersion: LocalAutomationProtocol.currentVersion,
                requestID: requestID,
                command: command,
                ok: false,
                message: message,
                result: nil,
                error: LocalAutomationError(code: code, message: message)
            ),
            to: descriptor
        )
    }

    private func send(_ response: LocalAutomationResponse, to descriptor: Int32) {
        guard var connection = connections[descriptor], connection.writeSource == nil,
              var data = try? JSONEncoder().encode(response), data.count <= 1_048_576 else {
            closeConnection(descriptor)
            return
        }
        if !connection.readSuspended { connection.source.suspend(); connection.readSuspended = true }
        data.append(0x0A)
        connection.output = data
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.writeResponse(to: descriptor) }
        connection.writeSource = source
        connections[descriptor] = connection
        source.resume()
    }

    private func writeResponse(to descriptor: Int32) {
        guard var connection = connections[descriptor] else { return }
        // Nonblocking and bounded per callback, even when a client stops reading.
        let count = connection.output.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress!.advanced(by: connection.written),
                        min(16_384, bytes.count - connection.written), 0)
        }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        guard count > 0 else { closeConnection(descriptor); return }
        connection.written += count
        connections[descriptor] = connection
        if connection.written == connection.output.count { closeConnection(descriptor) }
    }

    private func closeConnection(_ descriptor: Int32) {
        guard let connection = connections.removeValue(forKey: descriptor) else { return }
        connection.deadline?.cancel()
        let readSource = connection.source
        let suspended = connection.readSuspended
        if let writeSource = connection.writeSource {
            writeSource.setCancelHandler {
                if suspended { readSource.resume() }
                readSource.cancel()
            }
            writeSource.cancel()
        } else {
            if suspended { readSource.resume() }
            readSource.cancel()
        }
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}

private func withUnixSocketAddress<Result>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
    var address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < pathCapacity else {
        throw LocalAutomationTransportError.socketPathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    let length = MemoryLayout<sa_family_t>.size + path.utf8.count + 1
    address.sun_len = UInt8(length)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
        path.withCString { source in
            _ = strlcpy(destination, source, pathCapacity)
        }
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(length))
        }
    }
}
