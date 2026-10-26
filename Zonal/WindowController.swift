import AppKit
import ApplicationServices
import OSLog

enum WindowPlacementReason: String {
    case zoneDrop
    case restore
    case undo
    case assignment
    case focusTransition
    case zoneReflow
    case unspecified
}

struct WindowPlacementRetryPolicy: Equatable {
    var settleDelay: TimeInterval = 0.12
    var maximumWrites = 2
    var suppressionGrace: TimeInterval = 0.5

    var suppressionDuration: TimeInterval {
        settleDelay * Double(maximumWrites) + suppressionGrace
    }
}

struct WindowSizeConstraints: Equatable {
    var minimumWidth: CGFloat? = nil
    var maximumWidth: CGFloat? = nil
    var minimumHeight: CGFloat? = nil
    var maximumHeight: CGFloat? = nil
}

struct WindowConstraintMemory {
    private struct Observation {
        var requested: CGSize
        var actual: CGSize
    }

    private var candidates: [LiveWindowID: Observation] = [:]
    private(set) var constraints: [LiveWindowID: WindowSizeConstraints] = [:]

    mutating func observe(
        windowID: LiveWindowID,
        requested: CGRect,
        actual: CGRect
    ) -> WindowSizeConstraints? {
        let refusedWidth = abs(actual.width - requested.width) > 2
        let refusedHeight = abs(actual.height - requested.height) > 2
        guard refusedWidth || refusedHeight else {
            candidates.removeValue(forKey: windowID)
            return nil
        }

        let previous = candidates[windowID]
        candidates[windowID] = Observation(requested: requested.size, actual: actual.size)
        var learned = constraints[windowID] ?? WindowSizeConstraints()
        var changed = false
        if refusedWidth,
           let previous,
           sameRefusal(requested.width, actual.width, previous.requested.width, previous.actual.width) {
            if actual.width > requested.width {
                learned.minimumWidth = max(learned.minimumWidth ?? 0, actual.width)
            } else {
                learned.maximumWidth = min(learned.maximumWidth ?? .greatestFiniteMagnitude, actual.width)
            }
            changed = true
        }
        if refusedHeight,
           let previous,
           sameRefusal(requested.height, actual.height, previous.requested.height, previous.actual.height) {
            if actual.height > requested.height {
                learned.minimumHeight = max(learned.minimumHeight ?? 0, actual.height)
            } else {
                learned.maximumHeight = min(learned.maximumHeight ?? .greatestFiniteMagnitude, actual.height)
            }
            changed = true
        }
        guard changed else { return nil }
        constraints[windowID] = learned
        candidates.removeValue(forKey: windowID)
        return learned
    }

    func reachableSize(for windowID: LiveWindowID, requested: CGSize) -> CGSize {
        guard let constraint = constraints[windowID] else { return requested }
        var width = requested.width
        var height = requested.height
        if let minimum = constraint.minimumWidth { width = max(width, minimum) }
        if let maximum = constraint.maximumWidth { width = min(width, maximum) }
        if let minimum = constraint.minimumHeight { height = max(height, minimum) }
        if let maximum = constraint.maximumHeight { height = min(height, maximum) }
        return CGSize(width: width, height: height)
    }

    mutating func forget(_ windowID: LiveWindowID) {
        candidates.removeValue(forKey: windowID)
        constraints.removeValue(forKey: windowID)
    }

    mutating func retain(_ liveIDs: Set<LiveWindowID>) {
        candidates = candidates.filter { liveIDs.contains($0.key) }
        constraints = constraints.filter { liveIDs.contains($0.key) }
    }

    private func sameRefusal(
        _ requested: CGFloat,
        _ actual: CGFloat,
        _ previousRequested: CGFloat,
        _ previousActual: CGFloat
    ) -> Bool {
        let directionMatches = (actual > requested) == (previousActual > previousRequested)
        return directionMatches && abs(actual - previousActual) <= 2
    }
}

struct AXPlacementJob: @unchecked Sendable {
    var token: UUID
    var windowID: LiveWindowID
    var pid: pid_t
    var element: AXUIElement
    var target: CGRect
    var container: CGRect?
    var verifyImmediately = false
}

struct AXPlacementResult: @unchecked Sendable {
    var token: UUID
    var windowID: LiveWindowID
    var outcome: WindowPlacementOutcome
    var actual: CGRect?
    var writes: Int
    var learnedConstraint: WindowSizeConstraints?
}

final class AXPlacementResultSink: @unchecked Sendable {
    let deliver: (AXPlacementResult) -> Void

    init(deliver: @escaping (AXPlacementResult) -> Void) {
        self.deliver = deliver
    }
}

protocol AXPlacementAccess: Sendable {
    func prepare(_ element: AXUIElement)
    func frame(of element: AXUIElement) -> CGRect?
    func apply(_ frame: CGRect, container: CGRect?, to element: AXUIElement, isCurrent: () -> Bool)
}

final class AXPlacementScheduler: @unchecked Sendable {
    private final class AppLane: @unchecked Sendable {
        let queue: DispatchQueue
        var pending: [LiveWindowID: AXPlacementJob] = [:]
        var isScheduled = false

        init(pid: pid_t) {
            queue = DispatchQueue(label: "com.sebmarste.zonal.ax.place.\(pid)", qos: .userInitiated)
        }
    }

    private let lock = NSLock()
    private let policy: WindowPlacementRetryPolicy
    private let sink: AXPlacementResultSink
    private let access: any AXPlacementAccess
    private let waitForSettle: @Sendable (TimeInterval) -> Void
    private var lanes: [pid_t: AppLane] = [:]
    private var currentTokens: [LiveWindowID: UUID] = [:]
    private var constraints = WindowConstraintMemory()

    init(policy: WindowPlacementRetryPolicy, sink: AXPlacementResultSink, access: any AXPlacementAccess = SystemAXPlacementAccess(),
         waitForSettle: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.policy = policy
        self.sink = sink
        self.access = access
        self.waitForSettle = waitForSettle
    }

    func submit(_ job: AXPlacementJob) {
        lock.lock()
        currentTokens[job.windowID] = job.token
        let lane = lanes[job.pid] ?? AppLane(pid: job.pid)
        lanes[job.pid] = lane
        lane.pending[job.windowID] = job
        let shouldSchedule = !lane.isScheduled
        lane.isScheduled = true
        lock.unlock()
        if shouldSchedule {
            lane.queue.async { [weak self, weak lane] in
                guard let self, let lane else { return }
                self.drain(lane, pid: job.pid)
            }
        }
    }

    func cancel(windowID: LiveWindowID, forgetConstraint: Bool = false) {
        lock.lock()
        currentTokens.removeValue(forKey: windowID)
        for lane in lanes.values { lane.pending.removeValue(forKey: windowID) }
        if forgetConstraint { constraints.forget(windowID) }
        lock.unlock()
    }

    func diagnosticSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let queued = lanes.values.reduce(0) { $0 + $1.pending.count }
        return "Placement scheduler: lanes=\(lanes.count) queued=\(queued) learnedConstraints=\(constraints.constraints.count)"
    }

    func retainWindows(_ liveIDs: Set<LiveWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        currentTokens = currentTokens.filter { liveIDs.contains($0.key) }
        constraints.retain(liveIDs)
        for lane in lanes.values {
            lane.pending = lane.pending.filter { liveIDs.contains($0.key) }
        }
    }

    private func drain(_ lane: AppLane, pid: pid_t) {
        while true {
            lock.lock()
            let jobs = Array(lane.pending.values)
            lane.pending.removeAll()
            if jobs.isEmpty {
                lane.isScheduled = false
                if lanes[pid] === lane { lanes.removeValue(forKey: pid) }
                lock.unlock()
                return
            }
            lock.unlock()
            for job in jobs where isCurrent(job) {
                let result = run(job)
                lock.lock()
                if currentTokens[job.windowID] == job.token {
                    currentTokens.removeValue(forKey: job.windowID)
                }
                lock.unlock()
                sink.deliver(result)
            }
        }
    }

    private func run(_ job: AXPlacementJob) -> AXPlacementResult {
        access.prepare(job.element)
        let reachable = reachableFrame(for: job)
        if let current = access.frame(of: job.element),
           PlacementNoOpPolicy.shouldSkip(actual: current, target: reachable) {
            let outcome: WindowPlacementOutcome = reachable.matchesPlacement(to: job.target)
                ? .placed
                : .constrained
            return result(job, outcome, current, writes: 0)
        }
        var writes = 0
        for attempt in 0..<policy.maximumWrites {
            guard isCurrent(job) else {
                return result(job, .superseded, nil, writes: writes)
            }
            access.apply(reachable, container: job.container, to: job.element, isCurrent: { self.isCurrent(job) })
            writes += 1
            if job.verifyImmediately, let actual = access.frame(of: job.element),
               actual.matchesPlacement(to: reachable) {
                guard isCurrent(job) else { return result(job, .superseded, nil, writes: writes) }
                return result(job, actual.matchesPlacement(to: job.target) ? .placed : .constrained,
                              actual, writes: writes)
            }
            if policy.settleDelay > 0 { waitForSettle(policy.settleDelay) }
            guard isCurrent(job) else { return result(job, .superseded, nil, writes: writes) }
            guard let actual = access.frame(of: job.element) else {
                return result(job, .constrained, nil, writes: writes)
            }
            if actual.matchesPlacement(to: job.target) {
                return result(job, .placed, actual, writes: writes)
            }
            if !reachable.matchesPlacement(to: job.target),
               actual.matchesPlacement(to: reachable) {
                return result(job, .constrained, actual, writes: writes)
            }
            lock.lock()
            let learned = currentTokens[job.windowID] == job.token
                ? constraints.observe(windowID: job.windowID, requested: job.target, actual: actual)
                : nil
            lock.unlock()
            if attempt == policy.maximumWrites - 1 {
                return AXPlacementResult(
                    token: job.token,
                    windowID: job.windowID,
                    outcome: .constrained,
                    actual: actual,
                    writes: writes,
                    learnedConstraint: learned
                )
            }
        }
        return result(job, .constrained, access.frame(of: job.element), writes: writes)
    }

    private func reachableFrame(for job: AXPlacementJob) -> CGRect {
        lock.lock()
        let size = constraints.reachableSize(for: job.windowID, requested: job.target.size)
        lock.unlock()
        guard size != job.target.size else { return job.target }
        return CGRect(
            origin: WindowPlacementGeometry().position(
                for: job.target,
                actualSize: size,
                in: job.container
            ),
            size: size
        )
    }

    private func isCurrent(_ job: AXPlacementJob) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentTokens[job.windowID] == job.token
    }

    private func result(
        _ job: AXPlacementJob,
        _ outcome: WindowPlacementOutcome,
        _ actual: CGRect?,
        writes: Int
    ) -> AXPlacementResult {
        AXPlacementResult(
            token: job.token,
            windowID: job.windowID,
            outcome: outcome,
            actual: actual,
            writes: writes,
            learnedConstraint: nil
        )
    }

}

// Self-AX calls enter AppKit directly rather than messaging another process.
enum AXThreadAccess {
    static func perform<T>(for element: AXUIElement, _ operation: () -> T) -> T {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier, !Thread.isMainThread {
            return DispatchQueue.main.sync(execute: operation)
        }
        return operation()
    }
}

struct SystemAXPlacementAccess: AXPlacementAccess {
    func prepare(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 1)
    }

    func apply(_ frame: CGRect, container: CGRect?, to element: AXUIElement, isCurrent: () -> Bool) {
        AXThreadAccess.perform(for: element) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 1)
            AXFrameAdjustment.perform(
                readEnhancedUI: {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString,
                                                        &value) == .success else { return nil }
                    return value as? Bool
                },
                writeEnhancedUI: { enabled in
                    // AppKit can apply this change while returning notImplemented.
                    _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString,
                                                     enabled ? kCFBooleanTrue : kCFBooleanFalse)
                }
            ) {
                WindowPlacementGeometry().apply(frame, container: container,
                    readFrame: { self.frame(of: element) },
                    setSize: { requested in
                        var size = requested
                        guard let value = AXValueCreate(.cgSize, &size) else { return false }
                        _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
                        return true
                    },
                    setPosition: { self.setPosition($0, element: element) },
                    isCurrent: isCurrent)
            }
        }
    }

    private func setPosition(_ point: CGPoint, element: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func frame(of element: AXUIElement) -> CGRect? {
        AXThreadAccess.perform(for: element) {
            let names = [kAXPositionAttribute, kAXSizeAttribute]
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
                  let attributes = values as? [Any], attributes.count == names.count else { return nil }
            return AXWindowSnapshot(element: element,
                attributes: Dictionary(uniqueKeysWithValues: zip(names, attributes)), directID: nil).frame
        }
    }
}

// AppKit's Enhanced UI animations can undo interleaved size/position writes.
// Placement lanes serialize this short transaction per app; restore its prior mode.
enum AXFrameAdjustment {
    static func perform(readEnhancedUI: () -> Bool?, writeEnhancedUI: (Bool) -> Void,
                        adjustment: () -> Void) {
        guard readEnhancedUI() == true else {
            adjustment()
            return
        }
        writeEnhancedUI(false)
        defer { writeEnhancedUI(true) }
        adjustment()
    }
}

enum WindowPlacementOutcome: Equatable {
    case placed
    case constrained
    case notSaved
    case cancelledByUser
    case superseded
}

struct WindowPlacementGeometry {
    func apply(_ frame: CGRect, container: CGRect?, readFrame: () -> CGRect?,
               setSize: (CGSize) -> Bool, setPosition: (CGPoint) -> Void, isCurrent: () -> Bool) {
        if let current = readFrame(), !needsResize(from: current.size, to: frame.size) {
            guard isCurrent() else { return }
            setPosition(position(for: frame, actualSize: current.size, in: container))
            return
        }
        guard isCurrent(), setSize(frame.size) else { return }
        let accepted = readFrame()?.size ?? frame.size
        guard isCurrent() else { return }
        // Make room at the requested origin before retrying growth clipped by a screen edge.
        setPosition(frame.origin)
        guard isCurrent(), setSize(frame.size) else { return }
        let finalSize = readFrame()?.size ?? accepted
        guard isCurrent() else { return }
        setPosition(position(for: frame, actualSize: finalSize, in: container))
    }

    func needsResize(from current: CGSize, to target: CGSize) -> Bool {
        // A one-point border edit changes each dimension by two points and still needs a resize.
        abs(current.width - target.width) > 0.01 || abs(current.height - target.height) > 0.01
    }

    func position(for frame: CGRect, actualSize: CGSize, in container: CGRect?) -> CGPoint {
        guard let container else { return frame.origin }

        return CGPoint(
            x: resolvedOrigin(
                targetLeading: frame.minX,
                targetTrailing: frame.maxX,
                targetLength: frame.width,
                actualLength: actualSize.width,
                containerLeading: container.minX,
                containerTrailing: container.maxX
            ),
            y: resolvedOrigin(
                targetLeading: frame.minY,
                targetTrailing: frame.maxY,
                targetLength: frame.height,
                actualLength: actualSize.height,
                containerLeading: container.minY,
                containerTrailing: container.maxY
            )
        )
    }

    private func resolvedOrigin(
        targetLeading: CGFloat,
        targetTrailing: CGFloat,
        targetLength: CGFloat,
        actualLength: CGFloat,
        containerLeading: CGFloat,
        containerTrailing: CGFloat
    ) -> CGFloat {
        // A full-span target touches both edges. Prefer its leading edge so a
        // size request temporarily constrained at the old position can grow
        // on the next size-position-size pass instead of remaining trapped at
        // the trailing edge.
        if isAligned(targetLeading, with: containerLeading) {
            return targetLeading
        }
        if isAligned(targetTrailing, with: containerTrailing) {
            return targetTrailing - actualLength
        }
        if actualLength != targetLength {
            return (targetLeading + targetTrailing) / 2 - actualLength / 2
        }
        return targetLeading
    }

    private func isAligned(_ lhs: CGFloat, with rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 1
    }
}

struct AXCloseRequest: @unchecked Sendable {
    var element: AXUIElement
}

protocol AXCloseAccess: Sendable {
    func close(_ request: AXCloseRequest) -> Bool
}

struct SystemAXCloseAccess: AXCloseAccess {
    func close(_ request: AXCloseRequest) -> Bool {
        AXThreadAccess.perform(for: request.element) {
            AXUIElementSetMessagingTimeout(request.element, 1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(request.element, kAXCloseButtonAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            let button = unsafeBitCast(value, to: AXUIElement.self)
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
    }
}

struct AXFocusJob: @unchecked Sendable {
    var token: UUID
    var pid: pid_t
    var element: AXUIElement
}

protocol AXFocusAccess: Sendable {
    func focus(_ job: AXFocusJob, isCurrent: () -> Bool)
}

struct SystemAXFocusAccess: AXFocusAccess {
    var setAttribute: @Sendable (AXUIElement, CFString, CFTypeRef) -> AXError = {
        AXUIElementSetAttributeValue($0, $1, $2)
    }
    var raise: @Sendable (AXUIElement) -> AXError = {
        AXUIElementPerformAction($0, kAXRaiseAction as CFString)
    }
    var activateFrontWindow: @Sendable (pid_t) -> Bool = { pid in
        var process = ProcessSerialNumber()
        // These public legacy APIs remain exported but are unavailable to Swift's importer.
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let lookup = dlsym(handle, "GetProcessForPID"),
              let activate = dlsym(handle, "SetFrontProcessWithOptions") else { return false }
        let getProcess = unsafeBitCast(lookup, to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
        let setFront = unsafeBitCast(activate, to: (@convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32) -> OSStatus).self)
        guard getProcess(pid, &process) == noErr else { return false }
        // AXFrontmost/AppKit activation can raise sibling windows across other zones.
        return setFront(&process, UInt32(kSetFrontProcessFrontWindowOnly)) == noErr
    }

    func focus(_ job: AXFocusJob, isCurrent: () -> Bool) {
        AXThreadAccess.perform(for: job.element) {
            AXUIElementSetMessagingTimeout(job.element, 1)
            let app = AXUIElementCreateApplication(job.pid)
            AXUIElementSetMessagingTimeout(app, 1)
            guard isCurrent() else { return }
            _ = setAttribute(job.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard isCurrent() else { return }
            _ = setAttribute(app, kAXFocusedWindowAttribute as CFString, job.element)
            guard isCurrent() else { return }
            _ = setAttribute(job.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard isCurrent() else { return }
            guard raise(job.element) == .success else { return }
            guard isCurrent() else { return }
            _ = setAttribute(job.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard isCurrent() else { return }
            _ = activateFrontWindow(job.pid)
        }
    }
}

private final class AXFocusCompletion: @unchecked Sendable {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}

final class AXFocusExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var queues: [pid_t: DispatchQueue] = [:]
    private let access: any AXFocusAccess

    init(access: any AXFocusAccess = SystemAXFocusAccess()) { self.access = access }

    func submit(_ job: AXFocusJob, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        token = job.token
        let queue = queues[job.pid] ?? DispatchQueue(label: "com.sebmarste.zonal.ax.focus.\(job.pid)", qos: .userInitiated)
        queues[job.pid] = queue
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(job.token) else { return }
            access.focus(job, isCurrent: { self.isCurrent(job.token) })
            if isCurrent(job.token) { completion() }
        }
    }

    func cancel() {
        lock.lock()
        token = nil
        lock.unlock()
    }

    func isCurrent(_ candidate: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == candidate
    }

    func retainProcesses(_ pids: Set<pid_t>) {
        lock.lock()
        queues = queues.filter { pids.contains($0.key) }
        lock.unlock()
    }
}

@MainActor
final class WindowController {
    var onPlacementStarted: ((LiveWindowID, CGRect?, CGRect) -> Void)?
    var onPlacementSettled: ((LiveWindowID) -> Void)?
    var onPlacementVerified: ((LiveWindowID, CGRect) -> Void)?
    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowPlacement")
    private static let focusLogger = Logger(subsystem: "com.sebmarste.zonal", category: "WindowFocus")
    private var placementSuppressionUntil: [LiveWindowID: Date] = [:]
    private var placementGenerationByWindowID: [LiveWindowID: UUID] = [:]
    private var placementCompletionByWindowID: [LiveWindowID: (UUID, (WindowPlacementOutcome) -> Void)] = [:]
    private var userInteractionWindowIDs = Set<LiveWindowID>()
    private var recentPlacementDiagnostics: [String] = []
    private var skippedUnchangedPlacements = 0
    private let retryPolicy = WindowPlacementRetryPolicy()
    private let focusExecutor: AXFocusExecutor
    private let closeAccess: any AXCloseAccess
    private let frameProvider: (ManagedWindow) -> CGRect?

    init(focusAccess: any AXFocusAccess = SystemAXFocusAccess(),
         closeAccess: any AXCloseAccess = SystemAXCloseAccess(),
         frameProvider: ((ManagedWindow) -> CGRect?)? = nil) {
        focusExecutor = AXFocusExecutor(access: focusAccess)
        self.closeAccess = closeAccess
        self.frameProvider = frameProvider ?? { WindowController.quartzFrame($0) }
    }
    private lazy var placementScheduler = AXPlacementScheduler(
        policy: retryPolicy,
        sink: AXPlacementResultSink { [weak self] result in
            DispatchQueue.main.async {
                self?.handlePlacementResult(result)
            }
        }
    )

    func focus(_ window: ManagedWindow, completion: (() -> Void)? = nil) {
        guard let pid = window.identity.processIdentifier else { completion?(); return }
        let token = UUID()
        let delivery = AXFocusCompletion { completion?() }
        focusExecutor.submit(AXFocusJob(token: token, pid: pid, element: window.element)) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.focusExecutor.isCurrent(token) else { return }
                delivery.action()
            }
        }
    }

    func close(_ window: ManagedWindow, completion: @escaping (Bool) -> Void) {
        let request = AXCloseRequest(element: window.element)
        let access = closeAccess
        Task {
            let accepted = await Task.detached { access.close(request) }.value
            completion(accepted)
        }
    }

    func cancelPendingFocus() { focusExecutor.cancel() }

    func move(
        _ window: ManagedWindow,
        to frame: CGRect,
        in container: CGRect? = nil,
        reason: WindowPlacementReason = .unspecified,
        completion: ((WindowPlacementOutcome) -> Void)? = nil
    ) {
        guard !isUserInteracting(with: window) else {
            Self.logger.info(
                "placement.skip reason=\(reason.rawValue, privacy: .public) window=\(window.id) activeGesture=true"
            )
            completion?(.cancelledByUser)
            return
        }
        let initialFrame = self.frame(of: window)
        // The worker verifies no-op placement from live AX bounds. Cached or
        // Quartz preflight bounds must never report an unverified success.
        Self.logger.info(
            "placement.begin reason=\(reason.rawValue, privacy: .public) window=\(window.id) x=\(frame.minX) y=\(frame.minY) w=\(frame.width) h=\(frame.height)"
        )
        if initialFrame?.matchesPlacement(to: frame) != true { onPlacementStarted?(window.id, initialFrame, frame) }
        recordPlacementDiagnostic(
            status: "begin",
            window: window,
            reason: reason,
            target: frame,
            actual: initialFrame
        )
        let generation = UUID()
        if let pending = placementCompletionByWindowID.removeValue(forKey: window.id) {
            pending.1(.superseded)
        }
        placementGenerationByWindowID[window.id] = generation
        if let completion {
            placementCompletionByWindowID[window.id] = (generation, completion)
        }
        placementSuppressionUntil[window.id] = Date().addingTimeInterval(retryPolicy.suppressionDuration)
        guard let pid = window.identity.processIdentifier else {
            finishPlacement(for: window.id, generation: generation, outcome: .constrained)
            return
        }
        placementScheduler.submit(
            AXPlacementJob(
                token: generation,
                windowID: window.id,
                pid: pid,
                element: window.element,
                target: frame,
                container: container,
                verifyImmediately: reason == .focusTransition || reason == .zoneReflow
            )
        )
    }

    func beginUserInteraction(with window: ManagedWindow) {
        Self.logger.info("gesture.guard.begin window=\(window.id)")
        userInteractionWindowIDs.insert(window.id)
        placementScheduler.cancel(windowID: window.id, forgetConstraint: true)
        placementGenerationByWindowID.removeValue(forKey: window.id)
        placementSuppressionUntil.removeValue(forKey: window.id)
        if let pending = placementCompletionByWindowID.removeValue(forKey: window.id) {
            pending.1(.cancelledByUser)
        }
        onPlacementSettled?(window.id)
    }

    func endUserInteraction(with window: ManagedWindow) {
        Self.logger.info("gesture.guard.end window=\(window.id)")
        userInteractionWindowIDs.remove(window.id)
    }

    var hasActiveUserInteraction: Bool {
        !userInteractionWindowIDs.isEmpty
    }

    func detailedDiagnosticLines() -> [String] {
        [placementScheduler.diagnosticSummary(), "Unchanged placements skipped: \(skippedUnchangedPlacements)", "Recent placements:"] + (recentPlacementDiagnostics.isEmpty
            ? ["none"]
            : recentPlacementDiagnostics)
    }

    private func handlePlacementResult(_ result: AXPlacementResult) {
        guard placementGenerationByWindowID[result.windowID] == result.token else { return }
        Self.logger.info("handoff.stage=placementVerified window=\(result.windowID) writes=\(result.writes) uptime=\(ProcessInfo.processInfo.systemUptime)")
        if result.writes == 0 && result.outcome == .placed { skippedUnchangedPlacements += 1 }
        if let actual = result.actual { onPlacementVerified?(result.windowID, actual) }
        let status = result.outcome == .placed ? "placed" : "constrained"
        if let learnedConstraint = result.learnedConstraint {
            Self.logger.info(
                "placement.constraint window=\(result.windowID) value=\(String(describing: learnedConstraint), privacy: .public)"
            )
        }
        if let pending = placementCompletionByWindowID[result.windowID],
           pending.0 == result.token {
            recentPlacementDiagnostics.append(
                "\(Date().formatted(.iso8601)) status=\(status) window=\(result.windowID) writes=\(result.writes) actual=\(result.actual.map(Self.frameDescription) ?? "unavailable")"
            )
            if recentPlacementDiagnostics.count > 20 {
                recentPlacementDiagnostics.removeFirst(recentPlacementDiagnostics.count - 20)
            }
        }
        finishPlacement(
            for: result.windowID,
            generation: result.token,
            outcome: result.outcome
        )
    }

    private func isUserInteracting(with window: ManagedWindow) -> Bool {
        userInteractionWindowIDs.contains(window.id)
    }

    private func finishPlacement(
        for windowID: LiveWindowID,
        generation: UUID,
        outcome: WindowPlacementOutcome
    ) {
        guard placementGenerationByWindowID[windowID] == generation else { return }
        placementGenerationByWindowID.removeValue(forKey: windowID)
        placementSuppressionUntil[windowID] = Date().addingTimeInterval(retryPolicy.suppressionGrace)
        if let pending = placementCompletionByWindowID[windowID], pending.0 == generation {
            placementCompletionByWindowID.removeValue(forKey: windowID)
            pending.1(outcome)
        }
        // A completion may start another placement; only release the final one.
        if placementGenerationByWindowID[windowID] == nil { onPlacementSettled?(windowID) }
    }

    func frame(of window: ManagedWindow) -> CGRect? { frameProvider(window) }

    private static func quartzFrame(_ window: ManagedWindow) -> CGRect? {
        guard let pid = window.identity.processIdentifier,
              let number = window.identity.cgWindowID else { return window.observedFrame }
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] ?? []
        return rows.first {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
        }.flatMap {
            guard let bounds = $0[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
    }

    func hasPendingPlacement(to window: ManagedWindow) -> Bool {
        placementGenerationByWindowID[window.id] != nil
    }

    func isApplyingPlacement(to window: ManagedWindow) -> Bool {
        if placementGenerationByWindowID[window.id] != nil { return true }
        guard let until = placementSuppressionUntil[window.id] else { return false }
        if until > Date() {
            return true
        }
        placementSuppressionUntil.removeValue(forKey: window.id)
        return false
    }

    func isMinimized(_ window: ManagedWindow) -> Bool {
        window.isMinimized
    }

    func isFullScreen(_ window: ManagedWindow) -> Bool {
        window.isFullScreen
    }

    func retainWindows(_ windows: [ManagedWindow]) {
        let liveIDs = Set(windows.map(\.id))
        placementScheduler.retainWindows(liveIDs)
        focusExecutor.retainProcesses(Set(windows.compactMap { $0.identity.processIdentifier }))
        if windows.isEmpty { focusExecutor.cancel() }
        placementSuppressionUntil = placementSuppressionUntil.filter { liveIDs.contains($0.key) }
        userInteractionWindowIDs.formIntersection(liveIDs)
        let removed = placementGenerationByWindowID.keys.filter { !liveIDs.contains($0) }
        for id in removed {
            placementGenerationByWindowID.removeValue(forKey: id)
            placementCompletionByWindowID.removeValue(forKey: id)?.1(.superseded)
        }
    }

    private func recordPlacementDiagnostic(
        status: String,
        window: ManagedWindow,
        reason: WindowPlacementReason,
        target: CGRect,
        actual: CGRect?
    ) {
        let actualDescription = actual.map(Self.frameDescription) ?? "unavailable"
        recentPlacementDiagnostics.append(
            "\(Date().formatted(.iso8601)) status=\(status) reason=\(reason.rawValue) app=\(window.identity.bundleIdentifier) target=\(Self.frameDescription(target)) actual=\(actualDescription)"
        )
        if recentPlacementDiagnostics.count > 20 {
            recentPlacementDiagnostics.removeFirst(recentPlacementDiagnostics.count - 20)
        }
    }

    private static func frameDescription(_ frame: CGRect) -> String {
        "x:\(Int(frame.minX.rounded())) y:\(Int(frame.minY.rounded())) w:\(Int(frame.width.rounded())) h:\(Int(frame.height.rounded()))"
    }


}
