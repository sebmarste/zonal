import AppKit
import ApplicationServices
import Darwin
import OSLog

struct ResolvedWindowID: Equatable {
    var windowID: UInt32?
    var source: WindowIDResolutionSource
}

final class WindowIDResolver: @unchecked Sendable {
    typealias DirectResolver = (AXUIElement) -> UInt32?
    private typealias AXWindowFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<UInt32>
    ) -> AXError

    private let directResolver: DirectResolver?
    private var dynamicLibraryHandle: UnsafeMutableRawPointer?

    init(directResolver: DirectResolver? = nil, loadPrivateSymbol: Bool = true) {
        if let directResolver {
            self.directResolver = directResolver
            return
        }
        guard loadPrivateSymbol,
              let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            self.directResolver = nil
            return
        }
        dynamicLibraryHandle = handle
        let function = unsafeBitCast(symbol, to: AXWindowFunction.self)
        self.directResolver = { element in
            var identifier: UInt32 = 0
            return function(element, &identifier) == .success && identifier != 0
                ? identifier
                : nil
        }
    }

    deinit {
        if let dynamicLibraryHandle {
            dlclose(dynamicLibraryHandle)
        }
    }

    static func uniqueCandidateIndex(targetWindowID: UInt32, directWindowIDs: [UInt32?],
                                     fallbackMatches: Set<Int>) -> Int? {
        let direct = directWindowIDs.indices.filter { directWindowIDs[$0] == targetWindowID }
        if !direct.isEmpty { return direct.count == 1 ? direct[0] : nil }
        let fallback = fallbackMatches.filter { directWindowIDs[$0] == nil }
        return fallback.count == 1 ? fallback.first : nil
    }

    func resolve(
        element: AXUIElement,
        excluding usedWindowIDs: Set<UInt32> = [],
        publicFallback: () -> UInt32?
    ) -> ResolvedWindowID {
        if let direct = directResolver?(element), !usedWindowIDs.contains(direct) {
            return ResolvedWindowID(windowID: direct, source: .direct)
        }
        if let heuristic = publicFallback() {
            return ResolvedWindowID(windowID: heuristic, source: .publicHeuristic)
        }
        return ResolvedWindowID(windowID: nil, source: .sessionOnly)
    }
}

struct AXWindowSnapshot {
    var element: AXUIElement
    var attributes: [String: Any]
    var directID: UInt32?

    static func capture(_ element: AXUIElement, resolver: WindowIDResolver) -> AXWindowSnapshot? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, "AXIdentifier",
                     "AXDocument", kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     "AXFullScreen"]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let attributes = values as? [Any], attributes.count == names.count,
              attributes[0] is String else { return nil }
        return AXWindowSnapshot(element: element,
                                attributes: Dictionary(uniqueKeysWithValues: zip(names, attributes)),
                                directID: resolver.resolve(element: element) { nil }.windowID)
    }

    var title: String? { attributes[kAXTitleAttribute] as? String }
    var role: String? { attributes[kAXRoleAttribute] as? String }
    var subrole: String? { attributes[kAXSubroleAttribute] as? String }
    var identifier: String? { attributes["AXIdentifier"] as? String }
    var document: String? { attributes["AXDocument"] as? String }
    var isMinimized: Bool { attributes[kAXMinimizedAttribute] as? Bool == true }
    var frame: CGRect? {
        guard let position = attributes[kAXPositionAttribute],
              let size = attributes[kAXSizeAttribute],
              CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
    var isStandard: Bool {
        exclusionReason == nil
    }

    var exclusionReason: String? {
        guard role == kAXWindowRole as String else { return "non-window-role" }
        if subrole == kAXUnknownSubrole as String { return "unknown-subrole" }
        if subrole == "AXSystemDialog" { return "system-dialog" }
        if subrole == "AXFloatingWindow" { return "floating-window" }
        if WindowInclusionPolicy().isTransientHost(
                subrole: subrole,
                stableIdentifier: identifier,
                titleHint: title.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(160)) }
            ) { return "transient-host" }
        return nil
    }
}

enum AXFocusRead {
    case window(AXUIElement)
    case none
    case incomplete

    var element: AXUIElement? {
        if case .window(let element) = self { return element }
        return nil
    }

    var isComplete: Bool {
        if case .incomplete = self { return false }
        return true
    }

    static func classify(error: AXError, element: AXUIElement?) -> AXFocusRead {
        if error == .noValue { return .none }
        guard error == .success else { return .incomplete }
        return element.map { .window($0) } ?? .none
    }

    static func read(application: AXUIElement) -> AXFocusRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value)
        return classify(error: error, element: value as! AXUIElement?)
    }

    var diagnosticOutcome: String {
        switch self {
        case .window: "window"
        case .none: "none"
        case .incomplete: "incomplete"
        }
    }

    static func readFocusedWindow(timeout: Float, processIdentifier: pid_t? = nil) -> AXFocusRead {
        if let processIdentifier {
            let application = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(application, timeout)
            return read(application: application)
        }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        let applicationRead = classify(error: error, element: value as! AXUIElement?)
        guard let application = applicationRead.element else { return applicationRead }
        AXUIElementSetMessagingTimeout(application, timeout)
        return read(application: application)
    }
}

struct AXNotificationRegistrationPolicy {
    var maximumRetryAttempts = 2
    func retryDelay(error: AXError, attempt: Int) -> TimeInterval? {
        error == .cannotComplete && attempt < maximumRetryAttempts ? 0.1 * Double(attempt + 1) : nil
    }
}

struct AXApplicationSnapshot {
    var windows: [AXWindowSnapshot]
    var focusedElement: AXUIElement?
    var focusedReadIsComplete = true
}

final class AXEnumerationBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotsByPID: [pid_t: AXApplicationSnapshot] = [:]
    private var isSealed = false

    func complete(pid: pid_t, snapshot: AXApplicationSnapshot) {
        lock.lock()
        if !isSealed { snapshotsByPID[pid] = snapshot }
        lock.unlock()
    }

    func seal() {
        lock.lock()
        isSealed = true
        lock.unlock()
    }

    func snapshot(pid: pid_t) -> AXApplicationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotsByPID[pid]
    }
}

private final class AXApplicationExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var isBusy = false

    init(pid: pid_t) {
        queue = DispatchQueue(label: "com.sebmarste.zonal.ax.\(pid)", qos: .userInitiated)
    }

    func enumerateWindows(pid: pid_t, resolver: WindowIDResolver,
                          batch: AXEnumerationBatch, group: DispatchGroup,
                          read: @escaping AXApplicationExecutorPool.SnapshotReader) {
        stateLock.lock()
        guard !isBusy else { stateLock.unlock(); return }
        isBusy = true
        stateLock.unlock()
        group.enter()
        queue.async {
            defer {
                self.stateLock.lock()
                self.isBusy = false
                self.stateLock.unlock()
                group.leave()
            }
            if let snapshot = read(pid, resolver) { batch.complete(pid: pid, snapshot: snapshot) }

        }
    }
}

final class AXApplicationExecutorPool {
    private var executorsByPID: [pid_t: AXApplicationExecutor] = [:]
    typealias SnapshotReader = @Sendable (pid_t, WindowIDResolver) -> AXApplicationSnapshot?
    private let scanTimeout: TimeInterval
    private let read: SnapshotReader

    init(scanTimeout: TimeInterval = 0.8, read: @escaping SnapshotReader = AXApplicationExecutorPool.readApplication) {
        self.scanTimeout = scanTimeout
        self.read = read
    }

    static func readApplication(pid: pid_t, resolver: WindowIDResolver) -> AXApplicationSnapshot? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        var snapshots: [AXWindowSnapshot] = []
        for element in elements {
            guard let snapshot = AXWindowSnapshot.capture(element, resolver: resolver) else { return nil }
            snapshots.append(snapshot)
        }
        let focus = AXFocusRead.read(application: appElement)
        return AXApplicationSnapshot(windows: snapshots, focusedElement: focus.element,
                                     focusedReadIsComplete: focus.isComplete)
    }

    func enumerateWindows(for pids: [pid_t], resolver: WindowIDResolver,
                          completion: @escaping (AXEnumerationBatch) -> Void) {
        let livePIDs = Set(pids)
        executorsByPID = executorsByPID.filter { livePIDs.contains($0.key) }
        let batch = AXEnumerationBatch()
        let group = DispatchGroup()
        for pid in pids {
            let executor = executorsByPID[pid] ?? AXApplicationExecutor(pid: pid)
            executorsByPID[pid] = executor
            executor.enumerateWindows(pid: pid, resolver: resolver, batch: batch, group: group, read: read)
        }
        // Both paths execute on main; late workers cannot publish a second inventory.
        var delivered = false
        let deliver = DispatchWorkItem {
            guard !delivered else { return }
            delivered = true
            batch.seal()
            completion(batch)
        }
        group.notify(queue: .main, work: deliver)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeout, execute: deliver)
    }
}

struct WindowScanDiagnostics {
    var date = Date()
    var regularApplicationCount = 0
    var enumeratedApplicationCount = 0
    var failedApplicationBundleIdentifiers: [String] = []
    var enumeratedAXWindowCount = 0
    var eligibleAXWindowCount = 0
    var onScreenNativeWindowCount = 0
    var rejectedWindowCounts: [String: Int] = [:]
    var currentSpaceWindowCount = 0
    var minimizedWindowCount = 0
    var historyRetainedWindowCount = 0
    var unresolvedSpaceWindowCount = 0
    var directIDCount = 0
    var heuristicIDCount = 0
    var sessionOnlyIDCount = 0

    mutating func recordRejection(bundleIdentifier: String, reason: String) {
        rejectedWindowCounts["\(bundleIdentifier):\(reason)", default: 0] += 1
    }

    var rejectionSummary: String {
        rejectedWindowCounts.keys.sorted().map {
            "\($0)=\(rejectedWindowCounts[$0]!)"
        }.joined(separator: ", ")
    }

    var rejectedAllVisibleWindows: Bool {
        onScreenNativeWindowCount > 0 && enumeratedAXWindowCount > 0 && eligibleAXWindowCount == 0
    }
}

struct AXMetadataRequests {
    private var pending: [(element: AXUIElement, generation: UUID)] = []

    mutating func begin(element: AXUIElement) -> UUID {
        invalidate(element: element)
        let generation = UUID()
        pending.append((element, generation))
        return generation
    }

    mutating func finish(element: AXUIElement, generation: UUID) -> Bool {
        guard pending.contains(where: { CFEqual($0.element, element) && $0.generation == generation }) else {
            return false
        }
        invalidate(element: element)
        return true
    }

    mutating func invalidate(element: AXUIElement) {
        pending.removeAll { CFEqual($0.element, element) }
    }
}

enum WindowHitTestPolicy {
    static func windowID(in metadata: [[String: Any]], at point: CGPoint? = nil,
                         excludingProcessIdentifier: pid_t) -> UInt32? {
        metadata.first { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != excludingProcessIdentifier,
                  (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return point.map { bounds.contains($0) } ?? true
        }?[kCGWindowNumber as String] as? UInt32
    }
}

final class WindowRegistry {
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowRegistry")
    private var inventoryWindows: [ManagedWindow] = []
    private var metadataRequests = AXMetadataRequests()
    private var focusRevision: UInt64 = 0
    private var destroyedElements: [AXUIElement] = []
    private var inventoryFocusedElement: AXUIElement?
    private var focusedElementsByPID: [pid_t: AXUIElement] = [:]
    private let focusQueue = DispatchQueue(label: "com.sebmarste.zonal.focus-read", qos: .userInitiated)
    private var switcherIconCache: [String: NSImage] = [:]
    private var fallbackWindowIDsByPID: [pid_t: [(element: AXUIElement, id: UUID)]] = [:]
    private var resolvedCGWindowIDsByPID: [pid_t: [(element: AXUIElement, id: UInt32)]] = [:]
    typealias InventoryProvider = (@escaping ([ManagedWindow], AXUIElement?) -> Void) -> Void
    private let inventoryProvider: InventoryProvider?
    typealias FocusedElementProvider = (@escaping (AXFocusRead) -> Void) -> Void
    private let focusedElementProvider: FocusedElementProvider?
    var usesInjectedInventory: Bool { inventoryProvider != nil }
    private let windowIDResolver: WindowIDResolver
    private let applicationExecutors = AXApplicationExecutorPool()
    private(set) var outlineFocusProcessIdentifier: pid_t?
    private(set) var outlineFocusComparison = "not sampled"
    private(set) var outlineFocusLastRead = "not sampled"
    private(set) var outlineFocusEnrichment = "not sampled"
    private var comparedOutlineFocusPID: pid_t?
    private(set) var lastScanFocusRead: AXFocusRead = .incomplete
    private(set) var lastScanDiagnostics = WindowScanDiagnostics()
    private(set) var lastAllRejectedScan: WindowScanDiagnostics?

    init(windowIDResolver: WindowIDResolver = WindowIDResolver(), inventoryProvider: InventoryProvider? = nil,
         focusedElementProvider: FocusedElementProvider? = nil) {
        self.windowIDResolver = windowIDResolver
        self.inventoryProvider = inventoryProvider
        self.focusedElementProvider = focusedElementProvider
    }

    func manageableWindows(knownCurrentSpaceWindows: [ManagedWindow] = [],
                           completion: @escaping ([ManagedWindow], AXUIElement?) -> Void) {
        if let inventoryProvider {
            inventoryProvider { [self] windows, focused in
                lastScanFocusRead = focused.map { .window($0) } ?? .none
                completion(windows, focused)
            }
            return
        }
        let onScreenCGWindows = cgWindowMetadata(onScreenOnly: true)
        let onScreenWindowIDs = Set(
            onScreenCGWindows.compactMap {
                $0[kCGWindowNumber as String] as? UInt32
            }
        )
        let allCGWindows = cgWindowMetadata(onScreenOnly: false)
        var observedOrder = 0
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusRevisionAtScan = focusRevision
        let livePIDs = Set(applications.map(\.processIdentifier))
        destroyedElements.removeAll { element in
            var pid: pid_t = 0
            _ = AXUIElementGetPid(element, &pid)
            return !livePIDs.contains(pid)
        }
        applicationExecutors.enumerateWindows(
            for: applications.map(\.processIdentifier), resolver: windowIDResolver
        ) { [self] enumerationBatch in
        var diagnostics = WindowScanDiagnostics()
        diagnostics.regularApplicationCount = applications.count
        diagnostics.onScreenNativeWindowCount = onScreenCGWindows.filter {
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                && ($0[kCGWindowOwnerPID as String] as? NSNumber).map { livePIDs.contains($0.int32Value) } == true
        }.count
        var result: [ManagedWindow] = []

        for app in applications {
            guard let bundleIdentifier = app.bundleIdentifier else { continue }

            guard let snapshot = enumerationBatch.snapshot(pid: app.processIdentifier) else {
                diagnostics.failedApplicationBundleIdentifiers.append(bundleIdentifier)
                continue
            }
            diagnostics.enumeratedApplicationCount += 1
            diagnostics.enumeratedAXWindowCount += snapshot.windows.count

            var usedWindowIDs = Set<UInt32>()
            for raw in snapshot.windows {
                let element = raw.element
                if let reason = raw.exclusionReason {
                    diagnostics.recordRejection(bundleIdentifier: bundleIdentifier, reason: reason)
                    continue
                }
                if destroyedElements.contains(where: { CFEqual($0, element) }) {
                    diagnostics.recordRejection(bundleIdentifier: bundleIdentifier, reason: "destroyed-element")
                    continue
                }
                if bundleIdentifier == Bundle.main.bundleIdentifier,
                   raw.identifier != "ZonalSettingsWindow" {
                    diagnostics.recordRejection(bundleIdentifier: bundleIdentifier, reason: "own-overlay")
                    continue
                }
                diagnostics.eligibleAXWindowCount += 1
                observedOrder += 1
                let title = raw.title
                let frame = raw.frame
                let isMinimized = raw.isMinimized
                let directID = raw.directID.flatMap { usedWindowIDs.contains($0) ? nil : $0 }
                let fallbackID = directID == nil ? publicHeuristicWindowID(
                        for: element,
                        pid: app.processIdentifier,
                        title: title,
                        frame: frame,
                        metadata: isMinimized ? allCGWindows : onScreenCGWindows,
                        excluding: usedWindowIDs
                    ) : nil
                let resolution = ResolvedWindowID(
                    windowID: directID ?? fallbackID,
                    source: directID != nil ? .direct : fallbackID != nil ? .publicHeuristic : .sessionOnly
                )
                let windowID = resolution.windowID
                switch resolution.source {
                case .direct: diagnostics.directIDCount += 1
                case .publicHeuristic: diagnostics.heuristicIDCount += 1
                case .sessionOnly: diagnostics.sessionOnlyIDCount += 1
                }
                let wasConfirmedOnCurrentSpace = knownCurrentSpaceWindows.contains {
                    CFEqual($0.element, element)
                }
                if windowID.map(onScreenWindowIDs.contains) != true
                    && !isMinimized
                    && !wasConfirmedOnCurrentSpace {
                    diagnostics.unresolvedSpaceWindowCount += 1
                }
                if let windowID {
                    usedWindowIDs.insert(windowID)
                }
                let isConfirmedOnCurrentSpace = windowID.map(onScreenWindowIDs.contains) == true
                    || wasConfirmedOnCurrentSpace
                if isConfirmedOnCurrentSpace {
                    diagnostics.currentSpaceWindowCount += 1
                }
                if isMinimized {
                    diagnostics.minimizedWindowCount += 1
                }
                if wasConfirmedOnCurrentSpace
                    && windowID.map(onScreenWindowIDs.contains) != true {
                    diagnostics.historyRetainedWindowCount += 1
                }
                let identity = WindowIdentity(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: app.processIdentifier,
                    cgWindowID: windowID,
                    axRole: raw.role,
                    axSubrole: raw.subrole,
                    observedOrder: observedOrder,
                    stableIdentifier: raw.identifier,
                    documentURL: raw.document,
                    titleHint: normalizedTitleHint(title),
                    sessionID: sessionID(for: element, pid: app.processIdentifier, windowID: windowID)
                )
                result.append(ManagedWindow(
                    id: liveWindowID(for: element, pid: app.processIdentifier, windowID: windowID),
                    identity: identity,
                    appName: app.localizedName ?? bundleIdentifier,
                    title: title,
                    icon: highResolutionIcon(for: app),
                    element: element,
                    isOnCurrentSpace: isConfirmedOnCurrentSpace,
                    isMinimized: isMinimized,
                    idResolutionSource: resolution.source,
                    observedFrame: raw.frame,
                    isFullScreen: raw.attributes["AXFullScreen"] as? Bool == true
                ))
            }
        }
        if diagnostics.rejectedAllVisibleWindows {
            lastAllRejectedScan = diagnostics
            if !lastScanDiagnostics.rejectedAllVisibleWindows {
                Self.logger.error("AX inventory rejected all windows native=\(diagnostics.onScreenNativeWindowCount) AX=\(diagnostics.enumeratedAXWindowCount) reasons=\(diagnostics.rejectionSummary, privacy: .public)")
            }
        }
        lastScanDiagnostics = diagnostics
        inventoryWindows = result
        let focusedSnapshot = frontmostPID.flatMap { enumerationBatch.snapshot(pid: $0) }
        let scannedFocus = focusedSnapshot?.focusedElement
        if let focusedSnapshot, focusedSnapshot.focusedReadIsComplete {
            lastScanFocusRead = scannedFocus.map { .window($0) } ?? .none
        } else { lastScanFocusRead = .incomplete }
        if focusRevision == focusRevisionAtScan {
            for app in applications {
                if let snapshot = enumerationBatch.snapshot(pid: app.processIdentifier), snapshot.focusedReadIsComplete {
                    focusedElementsByPID[app.processIdentifier] = snapshot.focusedElement
                }
            }
            if lastScanFocusRead.isComplete { inventoryFocusedElement = scannedFocus }
        }
        completion(result, scannedFocus)
        }
    }

    /// Reads focus without blocking the main thread.
    func focusedWindow(completion: @escaping (ManagedWindow?) -> Void) {
        focusedWindowRead { window, _ in completion(window) }
    }

    /// The outline watchdog needs exact focus, not a full window metadata snapshot.
    func focusedElementRead(processIdentifier: pid_t? = nil, completion: @escaping (AXFocusRead) -> Void) {
        outlineFocusProcessIdentifier = processIdentifier
        if let focusedElementProvider { focusedElementProvider(completion); return }
        let compare = processIdentifier != nil && comparedOutlineFocusPID != processIdentifier
        comparedOutlineFocusPID = processIdentifier
        focusQueue.async(execute: DispatchWorkItem { [weak self] in
            // Pin the read to the same frontmost PID that the tracker verifies on return.
            let read = AXFocusRead.readFocusedWindow(timeout: WindowTracker.focusBoundaryTimeout,
                                                    processIdentifier: processIdentifier)
            let comparison = compare ? AXFocusRead.readFocusedWindow(timeout: WindowTracker.focusBoundaryTimeout) : nil
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                self?.outlineFocusLastRead = "pid=\(processIdentifier ?? 0) result=\(read.diagnosticOutcome)"
                if let comparison {
                    self?.outlineFocusComparison = "pid=\(processIdentifier ?? 0) application=\(read.diagnosticOutcome) system=\(comparison.diagnosticOutcome)"
                }
                completion(read)
            })
        })
    }

    /// Enrich only a previously unknown exact focused element; unsupported panels
    /// are authoritative absence, whereas failed reads preserve the last focus.
    func focusedWindowRead(element: AXUIElement, completion: @escaping (ManagedWindow?, AXFocusRead) -> Void) {
        let resolver = windowIDResolver
        focusQueue.async(execute: DispatchWorkItem { [weak self] in
            let raw = AXWindowSnapshot.capture(element, resolver: resolver)
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.outlineFocusEnrichment = "role=\(raw?.role ?? "none") subrole=\(raw?.subrole ?? "none") window=\(raw?.directID ?? 0) exclusion=\(raw?.exclusionReason ?? "none")"
                if let raw, !raw.isStandard { completion(nil, .none) }
                else if let raw, let window = self.managedWindow(snapshot: raw) {
                    completion(window, .window(element))
                } else { completion(nil, .incomplete) }
            })
        })
    }

    func focusedWindowRead(completion: @escaping (ManagedWindow?, AXFocusRead) -> Void) {
        let requestedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusQueue.async(execute: DispatchWorkItem { [weak self] in
            let focus = requestedPID.map { AXFocusRead.readFocusedWindow(timeout: 0.2, processIdentifier: $0) } ?? .none
            let raw = focus.element.flatMap { focused in
                self.flatMap { AXWindowSnapshot.capture(focused, resolver: $0.windowIDResolver) }
            }
            DispatchQueue.main.async(execute: DispatchWorkItem {
                let window = raw.flatMap { self?.managedWindow(snapshot: $0) }
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard frontmostPID == requestedPID else { completion(nil, .incomplete); return }
                if let window, window.identity.processIdentifier == frontmostPID {
                    completion(window, .window(window.element))
                } else if case .none = focus {
                    completion(nil, .none)
                } else if let raw, !raw.isStandard {
                    completion(nil, .none)
                } else { completion(nil, .incomplete) }
            })
        })
    }

    func clearFocusedWindow() {
        focusRevision &+= 1
        inventoryFocusedElement = nil
    }

    func forgetWindow(element: AXUIElement) {
        metadataRequests.invalidate(element: element)
        focusRevision &+= 1
        if !destroyedElements.contains(where: { CFEqual($0, element) }) { destroyedElements.append(element) }
        inventoryWindows.removeAll { CFEqual($0.element, element) }
        if inventoryFocusedElement.map({ CFEqual($0, element) }) == true { inventoryFocusedElement = nil }
        focusedElementsByPID = focusedElementsByPID.filter { !CFEqual($0.value, element) }
    }

    func noteFocusedWindow(_ window: ManagedWindow) {
        guard !destroyedElements.contains(where: { CFEqual($0, window.element) }) else { return }
        focusRevision &+= 1
        inventoryFocusedElement = window.element
        if let pid = window.identity.processIdentifier { focusedElementsByPID[pid] = window.element }
        if let index = inventoryWindows.firstIndex(where: { CFEqual($0.element, window.element) }) {
            inventoryWindows[index] = window
        } else { inventoryWindows.append(window) }
    }

    func focusedWindow() -> ManagedWindow? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = inventoryFocusedElement.flatMap({ element in
                  inventoryWindows.first { CFEqual($0.element, element) }
              }), focused.identity.processIdentifier == frontmostPID else { return nil }
        return focused
    }

    func focusedWindow(processIdentifier: pid_t) -> ManagedWindow? {
        focusedElementsByPID[processIdentifier].flatMap { element in
            inventoryWindows.first { CFEqual($0.element, element) }
        }
    }

    func focusedWindow(element: AXUIElement) -> ManagedWindow? {
        inventoryWindows.first { CFEqual($0.element, element) }
    }

    func window(element: AXUIElement, replacePending: Bool = true, completion: @escaping (ManagedWindow?) -> Void) {
        let generation = replacePending ? metadataRequests.begin(element: element) : nil
        let resolver = windowIDResolver
        DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem { [weak self] in
            let raw = AXWindowSnapshot.capture(element, resolver: resolver)
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let generation, !self.metadataRequests.finish(element: element, generation: generation) { return }
                completion(raw.flatMap { self.managedWindow(snapshot: $0) })
            })
        })
    }

    private func managedWindow(snapshot raw: AXWindowSnapshot, quartzID: UInt32? = nil) -> ManagedWindow? {
        guard raw.isStandard, !destroyedElements.contains(where: { CFEqual($0, raw.element) }) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(raw.element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier else { return nil }
        if bundle == Bundle.main.bundleIdentifier, raw.identifier != "ZonalSettingsWindow" { return nil }
        let id = quartzID ?? raw.directID ?? publicHeuristicWindowID(
            for: raw.element, pid: pid, title: raw.title, frame: raw.frame,
            metadata: cgWindowMetadata(onScreenOnly: true), excluding: []
        )
        let identity = WindowIdentity(bundleIdentifier: bundle, processIdentifier: pid, cgWindowID: id,
                                      axRole: raw.role, axSubrole: raw.subrole, observedOrder: 0,
                                      stableIdentifier: raw.identifier, documentURL: raw.document,
                                      titleHint: normalizedTitleHint(raw.title),
                                      sessionID: sessionID(for: raw.element, pid: pid, windowID: id))
        return ManagedWindow(id: liveWindowID(for: raw.element, pid: pid, windowID: id),
                             identity: identity, appName: app.localizedName ?? bundle,
                             title: raw.title, icon: highResolutionIcon(for: app), element: raw.element,
                             isOnCurrentSpace: id.map { currentSpaceFrames()[.quartz(processIdentifier: pid, windowNumber: $0)] != nil } == true,
                             isMinimized: raw.isMinimized,
                             idResolutionSource: raw.directID != nil ? .direct : id != nil ? .publicHeuristic : .sessionOnly,
                             observedFrame: raw.frame, isFullScreen: raw.attributes["AXFullScreen"] as? Bool == true)
    }

    /// Creates the smallest useful live record at the AX notification boundary.
    /// Optional metadata can be filled by the next inventory refresh without
    /// changing the live ID.
    func provisionalFocusedWindow(element: AXUIElement) -> ManagedWindow? {
        focusedWindow(element: element)
    }

    func window(at point: CGPoint, completion: @escaping (ManagedWindow?) -> Void) {
        let id = WindowHitTestPolicy.windowID(in: cgWindowMetadata(onScreenOnly: true), at: point,
                                              excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier)
        guard let id else { completion(nil); return }
        window(cgWindowID: id, completion: completion)
    }

    func window(cgWindowID: UInt32, completion: @escaping (ManagedWindow?) -> Void) {
        if let cached = window(cgWindowID: cgWindowID) { completion(cached); return }
        let current = cgWindowMetadata(onScreenOnly: true)
        let metadata = current.contains { ($0[kCGWindowNumber as String] as? UInt32) == cgWindowID }
            ? current : cgWindowMetadata(onScreenOnly: false)
        guard let info = metadata.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == cgWindowID }),
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
            completion(nil); return
        }
        let targetBounds = bounds(from: info)
        let title = info[kCGWindowName as String] as? String
        let resolver = windowIDResolver
        DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            var value: CFTypeRef?
            var snapshots: [AXWindowSnapshot] = []
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let elements = value as? [AXUIElement] {
                let captured = elements.compactMap { AXWindowSnapshot.capture($0, resolver: resolver) }
                // A missing sibling makes fallback identity ambiguous even if the rest match.
                if captured.count == elements.count { snapshots = captured.filter(\.isStandard) }
            }
            let fallback = Set(snapshots.indices.filter { index in
                let raw = snapshots[index]
                return targetBounds.flatMap { bounds in raw.frame.map { $0.isClose(to: bounds) } } == true
                    || (title != nil && raw.title == title)
            })
            let index = WindowIDResolver.uniqueCandidateIndex(targetWindowID: cgWindowID,
                                                              directWindowIDs: snapshots.map(\.directID),
                                                              fallbackMatches: fallback)
            let raw = index.map { snapshots[$0] }
            DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
                completion(raw.flatMap { self?.managedWindow(snapshot: $0, quartzID: cgWindowID) })
            })
        })
    }

    func window(at point: CGPoint) -> ManagedWindow? {
        guard let windowID = WindowHitTestPolicy.windowID(in: cgWindowMetadata(onScreenOnly: true), at: point,
                                                         excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier) else {
            return nil
        }

        return window(cgWindowID: windowID)
    }

    func window(cgWindowID: UInt32) -> ManagedWindow? {
        inventoryWindows.first { $0.identity.cgWindowID == cgWindowID }
    }

    func frontmostWindow() -> ManagedWindow? {
        guard let windowID = WindowHitTestPolicy.windowID(in: cgWindowMetadata(onScreenOnly: true),
                                                         excludingProcessIdentifier: ProcessInfo.processInfo.processIdentifier) else {
            return nil
        }

        return window(cgWindowID: windowID)
    }

    func isOnScreen(_ window: ManagedWindow) -> Bool {
        guard let windowID = window.identity.cgWindowID else { return false }
        return cgWindowMetadata(onScreenOnly: true).contains {
            ($0[kCGWindowNumber as String] as? UInt32) == windowID
        }
    }

    private func highResolutionIcon(for app: NSRunningApplication?) -> NSImage? {
        guard let app else { return nil }
        let cacheKey = app.bundleIdentifier ?? app.bundleURL?.path ?? String(app.processIdentifier)
        if let cached = switcherIconCache[cacheKey] {
            return cached
        }

        let source = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app.icon
        guard let source else { return nil }
        var proposedRect = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let cgImage = source.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            switcherIconCache[cacheKey] = source
            return source
        }

        let icon = NSImage(cgImage: cgImage, size: NSSize(width: 64, height: 64))
        icon.isTemplate = false
        switcherIconCache[cacheKey] = icon
        return icon
    }

    func bestMatch(for assignment: WindowAssignment, in windows: [ManagedWindow]) -> ManagedWindow? {
        bestMatch(for: assignment.identity, in: windows)
    }

    func bestMatch(for identity: WindowIdentity, in windows: [ManagedWindow]) -> ManagedWindow? {
        switch match(for: identity.fingerprint, liveHint: identity, in: windows) {
        case .exact(let window), .confident(let window):
            return window
        case .ambiguous, .unmatched:
            return nil
        }
    }

    func match(
        for fingerprint: PersistentWindowFingerprint,
        liveHint: WindowIdentity? = nil,
        in windows: [ManagedWindow]
    ) -> WindowMatchResult {
        if let liveHint,
           let exact = windows.first(where: {
               liveHint.matchesSameLiveWindow(as: $0.identity)
           }) {
            return .exact(exact)
        }

        let candidates = windows.filter {
            $0.identity.bundleIdentifier == fingerprint.bundleIdentifier
        }
        guard !candidates.isEmpty else { return .unmatched }

        let scored = candidates.map { window -> (ManagedWindow, Int) in
            var score = 0
            if let stable = fingerprint.stableIdentifier,
               window.fingerprint.stableIdentifier == stable {
                score += 100
            }
            if let document = fingerprint.documentURL,
               window.fingerprint.documentURL == document {
                score += 90
            }
            if window.fingerprint.axRole == fingerprint.axRole {
                score += 8
            }
            if window.fingerprint.axSubrole == fingerprint.axSubrole {
                score += 8
            }
            if let titleHint = fingerprint.titleHint,
               window.fingerprint.titleHint == titleHint {
                score += 12
            }
            return (window, score)
        }.sorted { $0.1 > $1.1 }

        guard let best = scored.first, best.1 >= 20 else {
            return candidates.count == 1 ? .unmatched : .ambiguous
        }
        if scored.count > 1, scored[1].1 == best.1 {
            return .ambiguous
        }
        return .confident(best.0)
    }

    func assignment(_ assignment: WindowAssignment, matches window: ManagedWindow) -> Bool {
        if assignment.identity.matchesSameLiveWindow(as: window.identity) {
            return true
        }
        switch match(for: assignment.fingerprint, liveHint: assignment.identity, in: [window]) {
        case .exact, .confident:
            return true
        case .ambiguous, .unmatched:
            return false
        }
    }

    func elementsMatch(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    private func liveWindowID(
        for element: AXUIElement,
        pid: pid_t,
        windowID: UInt32?
    ) -> LiveWindowID {
        if let windowID {
            return .quartz(processIdentifier: pid, windowNumber: windowID)
        }
        return .session(
            processIdentifier: pid,
            id: fallbackSessionID(for: element, pid: pid)
        )
    }

    private func sessionID(
        for element: AXUIElement,
        pid: pid_t,
        windowID: UInt32?
    ) -> UUID? {
        guard windowID == nil else { return nil }
        return fallbackSessionID(for: element, pid: pid)
    }

    private func fallbackSessionID(for element: AXUIElement, pid: pid_t) -> UUID {
        if let existing = fallbackWindowIDsByPID[pid]?.first(where: {
            CFEqual($0.element, element)
        }) {
            return existing.id
        }
        let id = UUID()
        fallbackWindowIDsByPID[pid, default: []].append((element, id))
        return id
    }

    func currentSpaceFrames() -> [LiveWindowID: CGRect] {
        var result: [LiveWindowID: CGRect] = [:]
        for info in cgWindowMetadata(onScreenOnly: true) {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let number = info[kCGWindowNumber as String] as? UInt32,
                  let frame = bounds(from: info) else { continue }
            result[.quartz(processIdentifier: pid, windowNumber: number)] = frame
        }
        return result
    }

    func cgBounds(for window: ManagedWindow) -> CGRect? {
        guard let windowID = window.identity.cgWindowID else { return nil }
        return cgWindowMetadata(onScreenOnly: false)
            .first { info in
                (info[kCGWindowNumber as String] as? UInt32) == windowID
            }
            .flatMap(bounds(from:))
    }

    private func cgWindowMetadata(onScreenOnly: Bool) -> [[String: Any]] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly {
            options.insert(.optionOnScreenOnly)
        } else {
            options.insert(.optionAll)
        }
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func publicHeuristicWindowID(
        for element: AXUIElement,
        pid: pid_t,
        title: String?,
        frame: CGRect?,
        metadata: [[String: Any]],
        excluding usedWindowIDs: Set<UInt32>
    ) -> UInt32? {
        let matches = metadata.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = bounds(from: info),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return false
            }
            if (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
               (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 0 {
                return false
            }
            return !usedWindowIDs.contains(windowNumber)
        }

        if let cached = resolvedCGWindowIDsByPID[pid]?.first(where: { cached in
            CFEqual(cached.element, element)
                && !usedWindowIDs.contains(cached.id)
                && matches.contains(where: { info in
                    (info[kCGWindowNumber as String] as? UInt32) == cached.id
                })
        }) {
            return cached.id
        }

        // Once an AX element needed a session identity, keep that identity for
        // the rest of the process lifetime. Upgrading it to a CG number during
        // a later scan would itself look like a new window.
        if fallbackWindowIDsByPID[pid]?.contains(where: { CFEqual($0.element, element) }) == true {
            return nil
        }

        let resolved: UInt32?

        if let frame {
            let frameMatches = matches.filter { info in
                guard let bounds = bounds(from: info) else { return false }
                return bounds.isClose(to: frame)
            }

            if let title {
                let titleAndFrameMatches = frameMatches.filter { info in
                   (info[kCGWindowName as String] as? String) == title
                }
                if titleAndFrameMatches.count == 1 {
                    resolved = titleAndFrameMatches[0][kCGWindowNumber as String] as? UInt32
                    remember(windowID: resolved, for: element, pid: pid)
                    return resolved
                }
            }

            if frameMatches.count == 1 {
                resolved = frameMatches[0][kCGWindowNumber as String] as? UInt32
                remember(windowID: resolved, for: element, pid: pid)
                return resolved
            }
        }

        if let title {
            let titleMatches = matches.filter { info in
               (info[kCGWindowName as String] as? String) == title
            }
            if titleMatches.count == 1 {
                resolved = titleMatches[0][kCGWindowNumber as String] as? UInt32
                remember(windowID: resolved, for: element, pid: pid)
                return resolved
            }
        }

        // Enumeration order is not identity. If metadata cannot uniquely
        // resolve this AX element, retain a stable session ID instead of
        // attaching another window's CG number.
        resolved = matches.count == 1
            ? matches[0][kCGWindowNumber as String] as? UInt32
            : nil
        remember(windowID: resolved, for: element, pid: pid)
        return resolved
    }

    private func remember(windowID: UInt32?, for element: AXUIElement, pid: pid_t) {
        guard let windowID else { return }
        if let index = resolvedCGWindowIDsByPID[pid]?.firstIndex(where: { CFEqual($0.element, element) }) {
            resolvedCGWindowIDsByPID[pid]?[index].id = windowID
        } else {
            resolvedCGWindowIDsByPID[pid, default: []].append((element, windowID))
        }
    }

    private func bounds(from metadata: [String: Any]) -> CGRect? {
        guard let dictionary = metadata[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private func normalizedTitleHint(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(160))
    }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) <= 2
            && abs(minY - other.minY) <= 2
            && abs(width - other.width) <= 2
            && abs(height - other.height) <= 2
    }
}
