import AppKit
import CoreGraphics
import Foundation

struct ZoneID: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let main = ZoneID(rawValue: "main")
    static let left = ZoneID(rawValue: "left")
    static let center = ZoneID(rawValue: "center")
    static let right = ZoneID(rawValue: "right")
}

struct DisplayRoleID: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    static let workspace = DisplayRoleID(rawValue: "workspace")
}

struct NormalizedFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedFrame(x: 0, y: 0, width: 1, height: 1)

    func rect(in displayFrame: CGRect) -> CGRect {
        let safeX = max(0, min(1, x))
        let safeY = max(0, min(1, y))
        let safeWidth = max(0.05, min(1 - safeX, width))
        let safeHeight = max(0.05, min(1 - safeY, height))
        let minX = (displayFrame.minX + displayFrame.width * CGFloat(safeX)).rounded()
        let minY = (displayFrame.minY + displayFrame.height * CGFloat(safeY)).rounded()
        let maxX = (displayFrame.minX + displayFrame.width * CGFloat(safeX + safeWidth)).rounded()
        let maxY = (displayFrame.minY + displayFrame.height * CGFloat(safeY + safeHeight)).rounded()

        return CGRect(
            x: minX,
            y: minY,
            width: max(1, maxX - minX),
            height: max(1, maxY - minY)
        )
    }

    static func relativeFrame(for frame: CGRect, in container: CGRect) -> NormalizedFrame {
        guard container.width > 0, container.height > 0 else { return .full }
        return NormalizedFrame(
            x: Double((frame.minX - container.minX) / container.width),
            y: Double((frame.minY - container.minY) / container.height),
            width: Double(frame.width / container.width),
            height: Double(frame.height / container.height)
        ).clamped()
    }

    func clamped() -> NormalizedFrame {
        let safeX = max(0, min(0.95, x))
        let safeY = max(0, min(0.95, y))
        return NormalizedFrame(
            x: safeX,
            y: safeY,
            width: max(0.05, min(1 - safeX, width)),
            height: max(0.05, min(1 - safeY, height))
        )
    }

    func roundedToPercentStep() -> NormalizedFrame {
        NormalizedFrame(
            x: x.roundedToPercentStep(),
            y: y.roundedToPercentStep(),
            width: width.roundedToPercentStep(),
            height: height.roundedToPercentStep()
        ).clamped()
    }
}

private extension Double {
    func roundedToPercentStep() -> Double {
        (self * 100).rounded() / 100
    }
}

enum ZonePresentationOption: String, CaseIterable {
    case overlap = "Overlap"
    case peekStack = "Peek stack"
    case tabShelf = "Tab shelf"
    case tabFrame = "Tab frame"

    init(zone: Zone) {
        switch zone.windowPresentation {
        case .overlap: self = .overlap
        case .peekStack: self = .peekStack
        case .tabs: self = zone.tabStyle == .shelf ? .tabShelf : .tabFrame
        }
    }

    func apply(to zone: inout Zone) {
        switch self {
        case .overlap: zone.windowPresentation = .overlap
        case .peekStack: zone.windowPresentation = .peekStack
        case .tabShelf, .tabFrame:
            zone.windowPresentation = .tabs
            zone.tabStyle = self == .tabShelf ? .shelf : .frame
        }
    }
}

enum ZoneWindowPresentation: String, Codable, CaseIterable, Identifiable {
    case overlap
    case peekStack = "accordion"
    case tabs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overlap: ZonePresentationOption.overlap.rawValue
        case .peekStack: ZonePresentationOption.peekStack.rawValue
        case .tabs: "Tabs"
        }
    }
}

enum ZoneTabEdge: String, Codable, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isVertical: Bool { self == .left || self == .right }
}

enum ZoneTabStyle: String, Codable, CaseIterable, Identifiable {
    case shelf, frame
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: ZonePresentationOption.tabShelf.rawValue
        case .frame: ZonePresentationOption.tabFrame.rawValue
        }
    }
}

enum ZoneTabMetrics {
    static let defaultBorderWidth: Double = 7
    static let borderWidthRange: ClosedRange<Double> = 0...24
    static let minimumPadding: CGFloat = 4

    static func clampedBorderWidth(_ width: Double) -> Double {
        min(borderWidthRange.upperBound, max(borderWidthRange.lowerBound, width))
    }
}

enum ZonePeekDirection: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Zone: Codable, Equatable, Identifiable {
    var id: ZoneID
    var name: String
    var frame: NormalizedFrame
    var displayRoleID: DisplayRoleID?
    var windowPresentation: ZoneWindowPresentation
    var peekWidth: Double
    var peekDirection: ZonePeekDirection
    var tabStyle: ZoneTabStyle
    var tabBorderWidth: Double

    init(
        id: ZoneID,
        name: String,
        frame: NormalizedFrame,
        displayRoleID: DisplayRoleID? = nil,
        windowPresentation: ZoneWindowPresentation = .overlap,
        peekWidth: Double = 48,
        peekDirection: ZonePeekDirection = .left,
        tabStyle: ZoneTabStyle = .frame,
        tabBorderWidth: Double = ZoneTabMetrics.defaultBorderWidth
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.displayRoleID = displayRoleID
        self.windowPresentation = windowPresentation
        self.peekWidth = peekWidth
        self.peekDirection = peekDirection
        self.tabStyle = tabStyle
        self.tabBorderWidth = ZoneTabMetrics.clampedBorderWidth(tabBorderWidth)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case frame
        case displayRoleID
        case windowPresentation
        case peekWidth, peekDirection, tabStyle, tabBorderWidth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ZoneID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        frame = try container.decode(NormalizedFrame.self, forKey: .frame)
        displayRoleID = try container.decodeIfPresent(DisplayRoleID.self, forKey: .displayRoleID)
        windowPresentation = try container.decode(
            ZoneWindowPresentation.self,
            forKey: .windowPresentation
        )
        peekWidth = min(160, max(8, try container.decode(Double.self, forKey: .peekWidth)))
        peekDirection = try container.decode(ZonePeekDirection.self, forKey: .peekDirection)
        tabStyle = try container.decode(ZoneTabStyle.self, forKey: .tabStyle)
        tabBorderWidth = ZoneTabMetrics.clampedBorderWidth(
            try container.decode(Double.self, forKey: .tabBorderWidth))
    }
}

struct ZoneNameResolver {
    func name(for zoneID: ZoneID, in zones: [Zone]) -> String {
        if let configured = zones.first(where: { $0.id == zoneID })?.name
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        let fallback = zoneID.rawValue
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Zone" : fallback.capitalized
    }
}

struct DisplayDescriptor: Codable, Equatable, Hashable, Identifiable {
    var id: String { persistentID }
    var persistentID: String
    var name: String
    var width: Int
    var height: Int
    var scale: Double
    var rotation: Double
    var isBuiltIn: Bool
}

struct DisplayRole: Codable, Equatable, Identifiable {
    var id: DisplayRoleID
    var name: String
    var descriptor: DisplayDescriptor
}

struct DisplaySetupBinding: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var displays: [DisplayDescriptor]
    var relativeFrames: [String: NormalizedFrame]
    var mainDisplayPersistentID: String?

    init(
        id: UUID = UUID(),
        name: String,
        displays: [DisplayDescriptor],
        relativeFrames: [String: NormalizedFrame],
        mainDisplayPersistentID: String?
    ) {
        self.id = id
        self.name = name
        self.displays = displays
        self.relativeFrames = relativeFrames
        self.mainDisplayPersistentID = mainDisplayPersistentID
    }
}

struct DisplayProfile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var mainZoneID: ZoneID
    var setupBindings: [DisplaySetupBinding]
    var displayRoles: [DisplayRole]
    var zones: [Zone]
    var zoneSpacing: Double

    static let zoneSpacingRange: ClosedRange<Double> = 0...32

    init(
        id: String,
        name: String,
        mainZoneID: ZoneID,
        setupBindings: [DisplaySetupBinding] = [],
        displayRoles: [DisplayRole] = [],
        zones: [Zone],
        zoneSpacing: Double = 0
    ) {
        self.id = id
        self.name = name
        self.mainZoneID = mainZoneID
        self.setupBindings = setupBindings
        self.displayRoles = displayRoles
        self.zones = zones
        self.zoneSpacing = zoneSpacing
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mainZoneID, setupBindings, displayRoles, zones, zoneSpacing
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        mainZoneID = try values.decode(ZoneID.self, forKey: .mainZoneID)
        setupBindings = try values.decode([DisplaySetupBinding].self, forKey: .setupBindings)
        displayRoles = try values.decode([DisplayRole].self, forKey: .displayRoles)
        zones = try values.decode([Zone].self, forKey: .zones)
        zoneSpacing = try values.decodeIfPresent(Double.self, forKey: .zoneSpacing) ?? 0
    }
}


struct DisplaySignature: Codable, Equatable, Hashable {
    var displayCount: Int
    var displays: [Display]

    struct Display: Codable, Equatable, Hashable {
        var width: Int
        var height: Int
        var scale: Double
    }
}

enum MenuBarMode: String, Codable, CaseIterable, Identifiable {
    case minimal
    case extended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimal: "Minimal"
        case .extended: "Extended"
        }
    }
}

enum DragZoneActivationMode: String, Codable, CaseIterable, Identifiable {
    case always
    case shiftKey
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .shiftKey: "Hold Shift"
        case .off: "Off"
        }
    }

    func isActive(shiftKeyPressed: Bool) -> Bool {
        switch self {
        case .always: true
        case .shiftKey: shiftKeyPressed
        case .off: false
        }
    }



    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case followSystem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .followSystem: "Follow System"
        }
    }
}

enum ActiveWindowOutlineColor: String, Codable, CaseIterable, Identifiable {
    case accent
    case blue
    case purple
    case orange
    case green

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .accent: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .orange: .systemOrange
        case .green: .systemGreen
        }
    }
}

struct WindowOutlineStyle: Equatable {
    var color: ActiveWindowOutlineColor = .accent
    var width: CGFloat = 3
    var zoneWidth: CGFloat { min(2, width) }

    init() {}
    init(configuration: ZonalConfiguration) {
        color = configuration.activeWindowOutlineColor
        width = CGFloat(min(8, max(1, configuration.activeWindowOutlineWidth)))
    }
}

enum ZonalHealthLevel: String, Codable, Equatable {
    case ok
    case warning
    case error
}

struct ZonalHealthFinding: Codable, Equatable, Identifiable {
    var id: String
    var level: ZonalHealthLevel
    var title: String
    var detail: String
}

struct WindowDefaultZoneRule: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var zoneID: ZoneID

    var id: String { bundleIdentifier }
}

enum OverlappingZoneTabs: String, Codable, CaseIterable, Identifiable {
    case currentZoneOnly
    case zoneShortcuts
    case allWindows

    var id: Self { self }
    var title: String {
        switch self {
        case .currentZoneOnly: "Current zone only"
        case .zoneShortcuts: "Zone shortcuts"
        case .allWindows: "All windows"
        }
    }
}

struct ZonalConfiguration: Codable, Equatable {
    // An absent setting in the current format retains the original shortcut presentation.
    var overlappingZoneTabs: OverlappingZoneTabs?

    var tabEdge: ZoneTabEdge = .top
    var tabShowsNames = true
    var schemaVersion: Int
    var setupVersion: Int
    var activeProfileID: String?
    var profiles: [DisplayProfile]
    var hotkeys: [HotkeyBinding]
    var useNativeCommandTab: Bool
    var menuBarMode: MenuBarMode
    var theme: AppTheme
    var dragZoneActivationMode: DragZoneActivationMode
    var showInteractionDiagnostics: Bool
    var showActiveWindowOutline: Bool
    var activeWindowOutlineColor: ActiveWindowOutlineColor
    var activeWindowOutlineWidth: Double
    var useNativeCommandTabInFullScreen: Bool
    var behavior: WindowBehaviorSettings = .init()
    var excludedBundleIdentifiers: [String]
    var windowDefaultZoneRules: [WindowDefaultZoneRule]

    static let `default` = ZonalConfiguration(
        schemaVersion: 5,
        setupVersion: 0,
        activeProfileID: DefaultProfiles.main.id,
        profiles: [DefaultProfiles.main],
        hotkeys: HotkeyBinding.defaults,
        useNativeCommandTab: false,
        menuBarMode: .minimal,
        theme: .followSystem,
        dragZoneActivationMode: .always,
        showInteractionDiagnostics: false,
        showActiveWindowOutline: true,
        activeWindowOutlineColor: .accent,
        activeWindowOutlineWidth: 3,
        useNativeCommandTabInFullScreen: true,
        excludedBundleIdentifiers: [],
        windowDefaultZoneRules: []
    )

    init(
        schemaVersion: Int = 5,
        setupVersion: Int = 1,
        activeProfileID: String?,
        profiles: [DisplayProfile],
        hotkeys: [HotkeyBinding] = HotkeyBinding.defaults,
        useNativeCommandTab: Bool = false,
        menuBarMode: MenuBarMode = .minimal,
        theme: AppTheme = .followSystem,
        dragZoneActivationMode: DragZoneActivationMode = .always,
        showInteractionDiagnostics: Bool = false,
        showActiveWindowOutline: Bool = true,
        activeWindowOutlineColor: ActiveWindowOutlineColor = .accent,
        activeWindowOutlineWidth: Double = 3,
        useNativeCommandTabInFullScreen: Bool = true,
        excludedBundleIdentifiers: [String] = [],
        windowDefaultZoneRules: [WindowDefaultZoneRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.setupVersion = setupVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.hotkeys = hotkeys
        self.useNativeCommandTab = useNativeCommandTab
        self.menuBarMode = menuBarMode
        self.theme = theme
        self.dragZoneActivationMode = dragZoneActivationMode
        self.showInteractionDiagnostics = showInteractionDiagnostics
        self.showActiveWindowOutline = showActiveWindowOutline
        self.activeWindowOutlineColor = activeWindowOutlineColor
        self.activeWindowOutlineWidth = activeWindowOutlineWidth
        self.useNativeCommandTabInFullScreen = useNativeCommandTabInFullScreen
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.windowDefaultZoneRules = windowDefaultZoneRules
    }

}

struct DisplaySnapshot: Codable, Equatable {
    var displays: [Display]

    struct Display: Codable, Equatable {
        var id: UInt32
        var frame: CGRect
        var visibleFrame: CGRect
        var scale: Double
        var persistentID: String = ""
        var name: String = "Display"
        var rotation: Double = 0
        var isBuiltIn: Bool = false

        var placementFrame: CGRect {
            visibleFrame
        }

        var descriptor: DisplayDescriptor {
            DisplayDescriptor(
                persistentID: persistentID.isEmpty ? "display-\(id)" : persistentID,
                name: name,
                width: Int(frame.width.rounded()),
                height: Int(frame.height.rounded()),
                scale: scale,
                rotation: rotation,
                isBuiltIn: isBuiltIn
            )
        }
    }

    var primaryDisplay: Display? {
        displays.first { CGDisplayIsMain($0.id) != 0 } ?? displays.first
    }

    func display(containing point: CGPoint) -> Display? {
        displays.first { $0.frame.contains(point) }
    }

    func display(containingOrNearest point: CGPoint) -> Display? {
        display(containing: point) ?? displays.min { lhs, rhs in
            lhs.frame.distance(to: point) < rhs.frame.distance(to: point)
        }
    }

    var hasUltrawide: Bool {
        displays.contains { display in
            let width = Int(display.frame.width.rounded())
            let height = Int(display.frame.height.rounded())
            let ratio = display.frame.width / max(display.frame.height, 1)
            return (width >= 5000 && height >= 1300) || ratio >= 3.2
        }
    }

    func display(persistentID: String) -> Display? {
        displays.first { display in
            let candidate = display.persistentID.isEmpty ? "display-\(display.id)" : display.persistentID
            return candidate == persistentID
        }
    }

    var desktopFrame: CGRect {
        displays.map(\.frame).reduce(.null) { partial, frame in
            partial.isNull ? frame : partial.union(frame)
        }
    }
}

private extension CGRect {
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return hypot(dx, dy)
    }
}

enum LiveWindowID: Codable, Equatable, Hashable, CustomStringConvertible {
    case quartz(processIdentifier: Int32, windowNumber: UInt32)
    case session(processIdentifier: Int32, id: UUID)

    var description: String {
        switch self {
        case .quartz(let processIdentifier, let windowNumber):
            "\(processIdentifier):cg:\(windowNumber)"
        case .session(let processIdentifier, let id):
            "\(processIdentifier):session:\(id.uuidString)"
        }

    }

    var sortKey: String { description }
}

enum WindowIDResolutionSource: String, Codable, Equatable {
    case direct
    case publicHeuristic
    case sessionOnly
}

struct FocusEventRecord: Equatable {
    var sequence: UInt64
    var windowID: LiveWindowID
}

struct FocusEventSequencer {
    private(set) var sequence: UInt64 = 0

    mutating func record(_ windowID: LiveWindowID) -> FocusEventRecord {
        sequence &+= 1
        return FocusEventRecord(sequence: sequence, windowID: windowID)
    }
}

struct AssignmentFocusTarget: Equatable {
    var assignmentID: UUID
    var zoneID: ZoneID
}

enum DeferredFocusTarget: Equatable {
    case liveWindow(LiveWindowID)
    case assignment(AssignmentFocusTarget)
}

struct DeferredFocusEvent: Equatable {
    var sequence: UInt64
    var target: DeferredFocusTarget
}

struct FocusHistoryProjection: Equatable {
    var state: ZoneStackState
    var compactedBaseline: ZoneStackState
    var remainingEvents: [DeferredFocusEvent]
}

struct FocusHistoryProjector {
    func project(
        baseline: ZoneStackState,
        events: [DeferredFocusEvent],
        assignmentByWindowID: [LiveWindowID: AssignmentFocusTarget]
    ) -> FocusHistoryProjection {
        var projectedReducer = WindowHistoryReducer(state: baseline)
        var compactedReducer = WindowHistoryReducer(state: baseline)
        var encounteredUnresolvedEvent = false
        var remainingEvents: [DeferredFocusEvent] = []
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let target: AssignmentFocusTarget?
            switch event.target {
            case .liveWindow(let windowID):
                target = assignmentByWindowID[windowID]
            case .assignment(let assignment):
                target = assignment
            }
            guard let target else {
                encounteredUnresolvedEvent = true
                remainingEvents.append(event)
                continue
            }
            projectedReducer.recordFocus(
                assignmentID: target.assignmentID,
                zoneID: target.zoneID
            )
            if encounteredUnresolvedEvent {
                remainingEvents.append(event)
            } else {
                compactedReducer.recordFocus(
                    assignmentID: target.assignmentID,
                    zoneID: target.zoneID
                )
            }
        }
        return FocusHistoryProjection(
            state: projectedReducer.state,
            compactedBaseline: compactedReducer.state,
            remainingEvents: remainingEvents
        )
    }

    func replay(
        baseline: ZoneStackState,
        events: [DeferredFocusEvent],
        assignmentByWindowID: [LiveWindowID: AssignmentFocusTarget]
    ) -> ZoneStackState {
        project(
            baseline: baseline,
            events: events,
            assignmentByWindowID: assignmentByWindowID
        ).state
    }
}

struct WindowAbsencePolicy: Equatable {
    var completeScansRequiredForRemoval = 3

    func shouldRemove(consecutiveCompleteAbsences: Int) -> Bool {
        consecutiveCompleteAbsences >= completeScansRequiredForRemoval
    }
}

struct SpaceEpochPolicy {
    func resolvedEpoch(
        isOnCurrentSpace: Bool,
        isMinimized: Bool,
        previousEpoch: UInt64?,
        currentEpoch: UInt64
    ) -> UInt64? {
        if isOnCurrentSpace {
            return currentEpoch
        }
        if isMinimized, previousEpoch == currentEpoch {
            return currentEpoch
        }
        return previousEpoch
    }

    func isIncluded(
        windowEpoch: UInt64?,
        isOnCurrentSpace: Bool,
        isMinimized: Bool,
        currentEpoch: UInt64
    ) -> Bool {
        windowEpoch == currentEpoch && (isOnCurrentSpace || isMinimized)
    }
}

struct PersistentWindowFingerprint: Codable, Equatable, Hashable {
    var bundleIdentifier: String
    var stableIdentifier: String?
    var documentURL: String?
    var axRole: String?
    var axSubrole: String?
    var titleHint: String?
}

enum WindowMatchResult {
    case exact(ManagedWindow)
    case confident(ManagedWindow)
    case ambiguous
    case unmatched
}

struct WindowIdentity: Codable, Hashable {
    var bundleIdentifier: String
    var processIdentifier: Int32?
    var cgWindowID: UInt32?
    var axRole: String?
    var axSubrole: String?
    var observedOrder: Int
    var stableIdentifier: String?
    var documentURL: String?
    var titleHint: String?
    var sessionID: UUID?

    init(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        cgWindowID: UInt32?,
        axRole: String?,
        axSubrole: String?,
        observedOrder: Int,
        stableIdentifier: String? = nil,
        documentURL: String? = nil,
        titleHint: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.cgWindowID = cgWindowID
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.observedOrder = observedOrder
        self.stableIdentifier = stableIdentifier
        self.documentURL = documentURL
        self.titleHint = titleHint
        self.sessionID = sessionID
    }

    var fingerprint: PersistentWindowFingerprint {
        PersistentWindowFingerprint(
            bundleIdentifier: bundleIdentifier,
            stableIdentifier: stableIdentifier,
            documentURL: documentURL,
            axRole: axRole,
            axSubrole: axSubrole,
            titleHint: titleHint
        )
    }

    /// Live hints are only trustworthy while the owning application process is
    /// still the same. They let reconciliation keep Quartz-less sibling
    /// windows attached to their assignments without persisting session IDs.
    func matchesSameLiveWindow(as other: WindowIdentity) -> Bool {
        guard bundleIdentifier == other.bundleIdentifier,
              processIdentifier == other.processIdentifier else {
            return false
        }
        if let cgWindowID, let otherWindowID = other.cgWindowID {
            return cgWindowID == otherWindowID
        }
        if let sessionID, let otherSessionID = other.sessionID {
            return sessionID == otherSessionID
        }
        return false
    }

    static func == (lhs: WindowIdentity, rhs: WindowIdentity) -> Bool {
        guard lhs.bundleIdentifier == rhs.bundleIdentifier else { return false }
        if lhs.cgWindowID != nil || rhs.cgWindowID != nil {
            return lhs.processIdentifier == rhs.processIdentifier
                && lhs.cgWindowID == rhs.cgWindowID
        }
        if lhs.sessionID != nil || rhs.sessionID != nil {
            return lhs.processIdentifier == rhs.processIdentifier
                && lhs.sessionID == rhs.sessionID
        }
        if lhs.stableIdentifier != nil || rhs.stableIdentifier != nil {
            return lhs.stableIdentifier == rhs.stableIdentifier
        }
        if lhs.documentURL != nil || rhs.documentURL != nil {
            return lhs.documentURL == rhs.documentURL
        }
        guard lhs.cgWindowID == nil,
              rhs.cgWindowID == nil,
              lhs.stableIdentifier == nil,
              rhs.stableIdentifier == nil,
              lhs.documentURL == nil,
              rhs.documentURL == nil else {
            return false
        }
        return lhs.processIdentifier == rhs.processIdentifier
            && lhs.axRole == rhs.axRole
            && lhs.axSubrole == rhs.axSubrole
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
        if let cgWindowID {
            hasher.combine(processIdentifier)
            hasher.combine(cgWindowID)
        } else if let sessionID {
            hasher.combine(processIdentifier)
            hasher.combine(sessionID)
        } else if let stableIdentifier {
            hasher.combine(stableIdentifier)
        } else if let documentURL {
            hasher.combine(documentURL)
        } else {
            hasher.combine(processIdentifier)
            hasher.combine(axRole)
            hasher.combine(axSubrole)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case processIdentifier
        case cgWindowID
        case axRole
        case axSubrole
        case observedOrder
        case stableIdentifier
        case documentURL
        case titleHint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        processIdentifier = try container.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        cgWindowID = try container.decodeIfPresent(UInt32.self, forKey: .cgWindowID)
        axRole = try container.decodeIfPresent(String.self, forKey: .axRole)
        axSubrole = try container.decodeIfPresent(String.self, forKey: .axSubrole)
        observedOrder = try container.decode(Int.self, forKey: .observedOrder)
        stableIdentifier = try container.decodeIfPresent(String.self, forKey: .stableIdentifier)
        documentURL = try container.decodeIfPresent(String.self, forKey: .documentURL)
        titleHint = try container.decodeIfPresent(String.self, forKey: .titleHint)
        sessionID = nil
    }
}

enum WindowPlacement: Codable, Equatable {
    case zoneFit(zoneID: ZoneID)
    case custom(
        zoneID: ZoneID,
        displayRoleID: DisplayRoleID,
        normalizedDisplayFrame: NormalizedFrame
    )
    case unplaced(zoneID: ZoneID)

    var zoneID: ZoneID {
        switch self {
        case .zoneFit(let zoneID), .unplaced(let zoneID):
            return zoneID
        case .custom(let zoneID, _, _):
            return zoneID
        }
    }
}

enum WindowAssignmentRetention: String, Codable, Equatable {
    case session
    case durable
}

enum WindowManagementMode: String, Codable, Equatable {
    case managed
    case ignored
}

struct SavedCustomPlacement: Codable, Equatable {
    var size: CGSize
    // Fractions of the free space around a window: 0 = leading, 0.5 = center, 1 = trailing.
    var relativePosition: CGPoint
}

struct WindowAssignment: Codable, Equatable, Identifiable {
    var id: UUID
    var identity: WindowIdentity
    var fingerprint: PersistentWindowFingerprint
    var zoneID: ZoneID
    var placementsByProfileID: [String: WindowPlacement]
    var savedCustomPlacementsByProfileID: [String: SavedCustomPlacement] = [:]
    var retention: WindowAssignmentRetention
    var managementMode: WindowManagementMode
    var updatedAt: Date

    func fitsZone(in profileID: String) -> Bool {
        if let placement = placementsByProfileID[profileID] {
            if case .zoneFit = placement { return true }
            return false
        }
        // Carry fitting intent across profiles, but never infer it from a custom size.
        return placementsByProfileID.values.allSatisfy { if case .zoneFit = $0 { return true }; return false }
    }

    init(
        id: UUID,
        identity: WindowIdentity,
        zoneID: ZoneID,
        placementsByProfileID: [String: WindowPlacement] = [:],
        retention: WindowAssignmentRetention = .durable,
        managementMode: WindowManagementMode = .managed,
        updatedAt: Date
    ) {
        self.id = id
        self.identity = identity
        self.fingerprint = identity.fingerprint
        self.zoneID = zoneID
        self.placementsByProfileID = placementsByProfileID
        self.retention = retention
        self.managementMode = managementMode
        self.updatedAt = updatedAt
    }

    init(
        id: UUID,
        identity: WindowIdentity,
        fingerprint: PersistentWindowFingerprint,
        zoneID: ZoneID,
        placementsByProfileID: [String: WindowPlacement],
        retention: WindowAssignmentRetention = .durable,
        managementMode: WindowManagementMode = .managed,
        updatedAt: Date
    ) {
        self.id = id
        self.identity = identity
        self.fingerprint = fingerprint
        self.zoneID = zoneID
        self.placementsByProfileID = placementsByProfileID
        self.retention = retention
        self.managementMode = managementMode
        self.updatedAt = updatedAt
    }

}

struct WindowActionSnapshot: Codable, Equatable {
    var identity: WindowIdentity
    var frame: CGRect
    var assignment: WindowAssignment?
}

struct WindowUndoEntry: Codable, Equatable {
    var identity: WindowIdentity
    var frame: CGRect
    var assignmentSnapshot: WindowActionSnapshot?
}

struct WindowUndoTransaction: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var entries: [WindowUndoEntry]
}

struct WindowActionStateRestoration: Equatable {
    var assignments: [WindowAssignment]
    var history: ZoneStackState
}

struct WindowActionStateRestorer {
    func restore(
        snapshotAssignment: WindowAssignment?,
        liveIdentity: WindowIdentity,
        liveFingerprint: PersistentWindowFingerprint,
        assignments: [WindowAssignment],
        history: ZoneStackState,
        now: Date
    ) -> WindowActionStateRestoration {
        var assignments = assignments
        var history = history
        let currentIndex = assignments.firstIndex {
            $0.identity.matchesSameLiveWindow(as: liveIdentity)
                || $0.id == snapshotAssignment?.id
        }
        let currentAssignment = currentIndex.map { assignments[$0] }
        if var restoredAssignment = snapshotAssignment {
            restoredAssignment.identity = liveIdentity
            restoredAssignment.fingerprint = liveFingerprint
            restoredAssignment.updatedAt = now
            if let currentIndex {
                assignments[currentIndex] = restoredAssignment
            } else {
                assignments.append(restoredAssignment)
            }
            if let currentAssignment {
                var reducer = WindowHistoryReducer(state: history)
                reducer.moveAssignment(
                    restoredAssignment.id,
                    from: currentAssignment.zoneID,
                    to: restoredAssignment.zoneID
                )
                reducer.prune(validAssignmentIDs: Set(assignments.map(\.id)))
                history = reducer.state
            }
        } else if let currentIndex {
            assignments.remove(at: currentIndex)
            var reducer = WindowHistoryReducer(state: history)
            reducer.prune(validAssignmentIDs: Set(assignments.map(\.id)))
            history = reducer.state
        }
        return WindowActionStateRestoration(assignments: assignments, history: history)
    }
}

struct ManagedWindow: Identifiable {
    var id: LiveWindowID
    var identity: WindowIdentity
    var appName: String
    var title: String?
    var icon: NSImage?
    var element: AXUIElement
    var isOnCurrentSpace: Bool = true
    var isMinimized: Bool = false
    var spaceEpoch: UInt64?
    var idResolutionSource: WindowIDResolutionSource = .sessionOnly
    var isProvisional: Bool = false
    var observedFrame: CGRect? = nil
    var isFullScreen: Bool = false

    var fingerprint: PersistentWindowFingerprint {
        identity.fingerprint
    }
}

enum WindowPlacementKind: String, Equatable {
    case fitted
    case custom
    case notPlaced

    var title: String {
        switch self {
        case .fitted: "Fitted to zone"
        case .custom: "Custom position"
        case .notPlaced: "Not placed yet"
        }
    }
}

struct WindowAssignmentSummary: Identifiable, Equatable {
    var id: UUID
    var bundleIdentifier: String
    var appName: String
    var title: String?
    var zoneID: ZoneID
    var zoneName: String
    var placementKind: WindowPlacementKind
    var isLive: Bool
    var isExcluded: Bool
    var managementMode: WindowManagementMode
    var isZonalUtility: Bool
    var updatedAt: Date
}

struct ZoneFrame: Equatable {
    var zoneID: ZoneID
    var frame: CGRect
    var displayRoleID: DisplayRoleID?

    init(zoneID: ZoneID, frame: CGRect, displayRoleID: DisplayRoleID? = nil) {
        self.zoneID = zoneID
        self.frame = frame
        self.displayRoleID = displayRoleID
    }
}

struct ZoneStackState: Codable, Equatable {
    var schemaVersion: Int = 2
    var globalRecency: [UUID] = []
    var activeAssignmentByZone: [ZoneID: UUID] = [:]
    var assignmentRecencyByZone: [ZoneID: [UUID]] = [:]
    static let empty = ZoneStackState()
}

struct WindowHistoryReducer {
    private(set) var state: ZoneStackState

    init(state: ZoneStackState) {
        self.state = state
    }

    mutating func recordFocus(assignmentID: UUID, zoneID: ZoneID) {
        state.globalRecency.removeAll { $0 == assignmentID }
        state.globalRecency.insert(assignmentID, at: 0)
        var zoneHistory = state.assignmentRecencyByZone[zoneID] ?? []
        zoneHistory.removeAll { $0 == assignmentID }
        zoneHistory.insert(assignmentID, at: 0)
        state.assignmentRecencyByZone[zoneID] = zoneHistory
        state.activeAssignmentByZone[zoneID] = assignmentID
    }

    mutating func prune(validAssignmentIDs: Set<UUID>) {
        state.globalRecency.removeAll { !validAssignmentIDs.contains($0) }
        for zoneID in Array(state.assignmentRecencyByZone.keys) {
            state.assignmentRecencyByZone[zoneID]?.removeAll {
                !validAssignmentIDs.contains($0)
            }
            if state.assignmentRecencyByZone[zoneID]?.isEmpty == true {
                state.assignmentRecencyByZone.removeValue(forKey: zoneID)
            }
            if let active = state.activeAssignmentByZone[zoneID],
               !validAssignmentIDs.contains(active) {
                state.activeAssignmentByZone.removeValue(forKey: zoneID)
            }
        }
    }

    mutating func moveAssignment(
        _ assignmentID: UUID,
        from sourceZoneID: ZoneID,
        to destinationZoneID: ZoneID
    ) {
        guard sourceZoneID != destinationZoneID else { return }
        state.assignmentRecencyByZone[sourceZoneID]?.removeAll { $0 == assignmentID }
        if state.activeAssignmentByZone[sourceZoneID] == assignmentID {
            state.activeAssignmentByZone.removeValue(forKey: sourceZoneID)
        }
        var destinationHistory = state.assignmentRecencyByZone[destinationZoneID] ?? []
        destinationHistory.removeAll { $0 == assignmentID }
        destinationHistory.insert(assignmentID, at: 0)
        state.assignmentRecencyByZone[destinationZoneID] = destinationHistory
        state.activeAssignmentByZone[destinationZoneID] = assignmentID
    }

    mutating func replaceAssignmentIDs(
        _ replacements: [UUID: UUID],
        assignmentZoneIDs: [UUID: ZoneID] = [:]
    ) {
        func replaced(_ ids: [UUID], zoneID: ZoneID? = nil) -> [UUID] {
            var seen = Set<UUID>()
            return ids.compactMap { id in
                let replacement = replacements[id] ?? id
                if let zoneID,
                   let assignmentZoneID = assignmentZoneIDs[replacement],
                   assignmentZoneID != zoneID {
                    return nil
                }
                return seen.insert(replacement).inserted ? replacement : nil
            }
        }

        state.globalRecency = replaced(state.globalRecency)
        for zoneID in Array(state.assignmentRecencyByZone.keys) {
            state.assignmentRecencyByZone[zoneID] = replaced(
                state.assignmentRecencyByZone[zoneID] ?? [],
                zoneID: zoneID
            )
        }
        for (zoneID, assignmentID) in state.activeAssignmentByZone {
            let replacement = replacements[assignmentID] ?? assignmentID
            if let assignmentZoneID = assignmentZoneIDs[replacement],
               assignmentZoneID != zoneID {
                state.activeAssignmentByZone.removeValue(forKey: zoneID)
            } else if replacement != assignmentID {
                state.activeAssignmentByZone[zoneID] = replacement
            }
        }
    }
}

struct WindowAssignmentCanonicalizationResult {
    var assignments: [WindowAssignment]
    var replacements: [UUID: UUID]
}

struct WindowAssignmentCanonicalizer {
    func canonicalize(
        assignments: [WindowAssignment],
        liveIdentities: [WindowIdentity],
        globalRecency: [UUID]
    ) -> WindowAssignmentCanonicalizationResult {
        var assignments = assignments
        var replacements: [UUID: UUID] = [:]
        let rank = Dictionary(
            uniqueKeysWithValues: globalRecency.enumerated().map {
                ($0.element, $0.offset)
            }
        )

        for identity in liveIdentities {
            let matches = assignments.indices.filter {
                assignments[$0].identity.matchesSameLiveWindow(as: identity)
            }
            guard matches.count > 1 else { continue }
            let winnerIndex = matches.min { lhs, rhs in
                let lhsRank = rank[assignments[lhs].id] ?? Int.max
                let rhsRank = rank[assignments[rhs].id] ?? Int.max
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return assignments[lhs].updatedAt > assignments[rhs].updatedAt
            } ?? matches[0]
            var winner = assignments[winnerIndex]
            let loserIDs = matches
                .filter { $0 != winnerIndex }
                .map { assignments[$0].id }

            for index in matches where index != winnerIndex {
                guard assignments[index].zoneID == winner.zoneID else { continue }
                for (profileID, placement) in assignments[index].placementsByProfileID
                where winner.placementsByProfileID[profileID] == nil {
                    winner.placementsByProfileID[profileID] = placement
                }
                for (profileID, frame) in assignments[index].savedCustomPlacementsByProfileID
                where winner.savedCustomPlacementsByProfileID[profileID] == nil {
                    winner.savedCustomPlacementsByProfileID[profileID] = frame
                }
            }
            assignments[winnerIndex] = winner
            for loserID in loserIDs {
                replacements[loserID] = winner.id
            }
            assignments.removeAll { loserIDs.contains($0.id) }
        }

        return WindowAssignmentCanonicalizationResult(
            assignments: assignments,
            replacements: replacements
        )
    }
}

struct WindowPlacementRecoveryCandidate {
    var assignmentID: UUID
    var targetFrame: CGRect
}

struct WindowPlacementRecoveryMatcher {
    var maximumNormalizedError: CGFloat = 0.12
    var minimumWinnerMargin: CGFloat = 0.05

    func assignmentID(
        for windowFrame: CGRect,
        candidates: [WindowPlacementRecoveryCandidate]
    ) -> UUID? {
        let scored = candidates.map { candidate in
            (candidate.assignmentID, normalizedError(windowFrame, candidate.targetFrame))
        }.sorted { $0.1 < $1.1 }
        guard let best = scored.first,
              best.1 <= maximumNormalizedError else {
            return nil
        }
        if scored.count > 1,
           scored[1].1 - best.1 < minimumWinnerMargin {
            return nil
        }
        return best.0
    }

    private func normalizedError(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let horizontalScale = max(rhs.width, 200)
        let verticalScale = max(rhs.height, 200)
        return max(
            abs(lhs.minX - rhs.minX) / horizontalScale,
            abs(lhs.minY - rhs.minY) / verticalScale,
            abs(lhs.width - rhs.width) / horizontalScale,
            abs(lhs.height - rhs.height) / verticalScale
        )
    }
}

enum SwitcherMode: Equatable {
    case allWindows
    case byZone

    var title: String { self == .allWindows ? "All Windows" : "By Zone" }
}

enum SwitcherArrowKey: String, Codable, Equatable, Hashable, CaseIterable, Identifiable {
    case left
    case right
    case down
    case up

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum SwitcherArrowAction: Equatable {
    case none
    case selectWindow(Int)
    case selectVerticalWindow(Int)
    case selectZone(SwitcherArrowKey)
    case assignZone(SwitcherArrowKey)
}

struct SwitcherArrowCommandPolicy {
    func action(
        for key: SwitcherArrowKey,
        shift: Bool,
        mode: SwitcherMode
    ) -> SwitcherArrowAction {
        guard mode == .byZone else {
            switch key {
            case .left, .up:
                return .selectWindow(-1)
            case .right, .down:
                return .selectWindow(1)
            }
        }

        if shift {
            return .assignZone(key)
        }
        switch key {
        case .up:
            return .selectVerticalWindow(-1)
        case .down:
            return .selectVerticalWindow(1)
        case .left, .right:
            return .selectZone(key)
        }
    }
}

struct SwitcherMRUOrder {
    func orderedAssignmentIDs(
        available: [UUID],
        current: UUID?,
        history: [UUID]
    ) -> [UUID] {
        let availableSet = Set(available)
        var seen = Set<UUID>()
        var result: [UUID] = []

        func append(_ assignmentID: UUID?) {
            guard let assignmentID,
                  availableSet.contains(assignmentID),
                  seen.insert(assignmentID).inserted else {
                return
            }
            result.append(assignmentID)
        }

        append(current)
        history.forEach { append($0) }
        available.forEach { append($0) }
        return result
    }
}

struct SwitcherSelectionPolicy {
    func initialAssignmentID(in orderedAssignmentIDs: [UUID]) -> UUID? {
        orderedAssignmentIDs.count > 1
            ? orderedAssignmentIDs[1]
            : orderedAssignmentIDs.first
    }
}

struct SwitcherSelectionRecovery {
    func assignmentID(
        current: UUID?,
        mode: SwitcherMode,
        zones: [SwitcherZone],
        selectedZoneID: ZoneID
    ) -> UUID? {
        let allItems = zones.flatMap(\.items)
        if let current, allItems.contains(where: { $0.assignmentID == current }) {
            return current
        }
        switch mode {
        case .allWindows:
            return allItems.first?.assignmentID
        case .byZone:
            return zones.first { $0.id == selectedZoneID }?.items.first?.assignmentID
        }
    }
}

struct SwitcherActivityPolicy {
    func activeAssignmentIDs(
        state: ZoneStackState,
        focusedAssignmentID: UUID?,
        focusedZoneID: ZoneID?
    ) -> Set<UUID> {
        var activeByZone = state.activeAssignmentByZone
        if let focusedAssignmentID, let focusedZoneID {
            activeByZone[focusedZoneID] = focusedAssignmentID
        }
        return Set(activeByZone.values)
    }
}

struct SwitcherItem: Identifiable, Equatable {
    var id: WindowIdentity { identity }
    var assignmentID: UUID
    var identity: WindowIdentity
    var appName: String
    var title: String?
    var icon: NSImage?
    var zoneID: ZoneID
    var zoneName: String
    var zoneFrame: NormalizedFrame?
    var isActive: Bool
    var isZonalUtility: Bool = false

    static func == (lhs: SwitcherItem, rhs: SwitcherItem) -> Bool {
        lhs.assignmentID == rhs.assignmentID
            && lhs.identity == rhs.identity
            && lhs.appName == rhs.appName
            && lhs.title == rhs.title
            && lhs.zoneID == rhs.zoneID
            && lhs.zoneName == rhs.zoneName
            && lhs.zoneFrame == rhs.zoneFrame
            && lhs.isActive == rhs.isActive
            && lhs.isZonalUtility == rhs.isZonalUtility
    }
}

struct SwitcherZone: Identifiable, Equatable {
    var id: ZoneID
    var name: String
    var frame: NormalizedFrame
    var items: [SwitcherItem]
}

struct WorkspaceSnapshotModel: Equatable {
    var showSwitcherShortcutGuide = true
    var nextWindowShortcutKeys = ["Tab"]
    var mode: SwitcherMode
    var zones: [SwitcherZone]
    var zoneColumns: [[ZoneID]]
    var selectedZoneID: ZoneID
    var selectedWindowID: WindowIdentity?
    var outlineStyle = WindowOutlineStyle()
}

struct SwitcherColumnCycleScope {
    func items(
        zones: [SwitcherZone],
        columns: [[ZoneID]],
        selectedZoneID: ZoneID
    ) -> [SwitcherItem] {
        guard let column = columns.first(where: { $0.contains(selectedZoneID) }) else {
            return zones.first { $0.id == selectedZoneID }?.items ?? []
        }
        return column.flatMap { zoneID in
            zones.first { $0.id == zoneID }?.items ?? []
        }
    }
}

enum ZonalCommand {
    case focusZone(ZoneID)
    case moveFocusedWindow(ZoneID)
    case moveFocusedWindowRelative(SwitcherArrowKey)
    case nextWindowInStack
    case previousWindowInStack
    case openGlobalSwitcher
    case openZoneSwitcher
    case switcherNext
    case switcherPrevious
    case switcherVerticalWindow(Int)
    case switcherMoveZone(SwitcherArrowKey)
    case switcherAssignZone(SwitcherArrowKey)
    case switcherAppendFilter(String)
    case switcherDeleteFilterCharacter
    case confirmSwitcher
    case cancelSwitcher
    case restore
    case undo
}

struct SwitcherModifierReleasePolicy {
    func shouldConfirm(
        hasPendingReleaseModifier: Bool,
        modifierIsStillPressed: Bool
    ) -> Bool {
        hasPendingReleaseModifier && !modifierIsStillPressed
    }
}

struct WindowRescanPolicy: Equatable {
    var followUpDelays: [TimeInterval] = [0.2, 0.7, 1.5]
}

struct WindowEventRefreshPolicy: Equatable {
    var debounceDelay: TimeInterval = 0.15
    var minimumInterval: TimeInterval = 1.0
    var recoveryInterval: TimeInterval = 5.0

    func delay(lastRefreshAt: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let lastRefreshAt else { return debounceDelay }
        let remainingInterval = minimumInterval - max(0, now - lastRefreshAt)
        return max(debounceDelay, remainingInterval)
    }
}

struct WindowInclusionPolicy {
    func isTransientHost(
        subrole: String?,
        stableIdentifier: String?,
        titleHint: String?
    ) -> Bool {
        subrole == "AXDialog"
            && stableIdentifier == "_NS:8"
            && titleHint == "window"
    }
}

struct HotkeyModifiers: Codable, Equatable, Hashable {
    var command: Bool
    var control: Bool
    var option: Bool
    var shift: Bool

    static let controlOption = HotkeyModifiers(command: false, control: true, option: true, shift: false)
    static let controlOptionShift = HotkeyModifiers(command: false, control: true, option: true, shift: true)
    static let commandOnly = HotkeyModifiers(command: true, control: false, option: false, shift: false)

    var displayString: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        return parts.isEmpty ? "No modifiers" : parts.joined(separator: " + ")
    }
}

enum HotkeyCommand: Codable, Equatable, Hashable {
    case focusZone(ZoneID)
    case moveFocusedWindow(ZoneID)
    case moveFocusedWindowRelative(SwitcherArrowKey)
    case nextWindowInStack
    case previousWindowInStack
    case openGlobalSwitcher
    case openZoneSwitcher
    case restore
    case undo

    var title: String {
        switch self {
        case .focusZone: "Focus Zone"
        case .moveFocusedWindow: "Move Window to Zone"
        case .moveFocusedWindowRelative: "Move Window by Direction"
        case .nextWindowInStack: "Next Window in Zone"
        case .previousWindowInStack: "Previous Window in Zone"
        case .openGlobalSwitcher: SwitcherMode.allWindows.title
        case .openZoneSwitcher: SwitcherMode.byZone.title
        case .restore: "Restore Window Positions"
        case .undo: "Undo Last Window Action"
        }
    }

    var zonalCommand: ZonalCommand {
        switch self {
        case .focusZone(let zoneID):
            return .focusZone(zoneID)
        case .moveFocusedWindow(let zoneID):
            return .moveFocusedWindow(zoneID)
        case .moveFocusedWindowRelative(let direction):
            return .moveFocusedWindowRelative(direction)
        case .nextWindowInStack:
            return .nextWindowInStack
        case .previousWindowInStack:
            return .previousWindowInStack
        case .openGlobalSwitcher:
            return .openGlobalSwitcher
        case .openZoneSwitcher:
            return .openZoneSwitcher
        case .undo:
            return .undo
        case .restore:
            return .restore
        }
    }
}

struct HotkeyBinding: Codable, Equatable, Identifiable {
    var id: UUID
    var command: HotkeyCommand
    var keyCode: Int64
    var keyLabel: String
    var modifiers: HotkeyModifiers
    var isEnabled: Bool

    // Tab always cycles an open switcher. Only advertise modifiers for a usable
    // Tab binding; a rebound opening shortcut is not a cycling shortcut.
    static func nextWindowShortcutKeys(mode: SwitcherMode, bindings: [HotkeyBinding],
                                       useNativeCommandTab: Bool) -> [String] {
        let command: HotkeyCommand = mode == .allWindows ? .openGlobalSwitcher : .openZoneSwitcher
        guard let binding = bindings.first(where: {
            $0.isEnabled && $0.command == command && $0.keyCode == 48
                && !(useNativeCommandTab && $0.modifiers.command && command == .openGlobalSwitcher)
        }) else { return ["Tab"] }
        var keys: [String] = []
        if binding.modifiers.control { keys.append("⌃") }
        if binding.modifiers.option { keys.append("⌥") }
        if binding.modifiers.shift { return ["Tab"] } // Shift-Tab cycles backwards.
        if binding.modifiers.command { keys.append("⌘") }
        return keys + ["Tab"]
    }

    static let defaults: [HotkeyBinding] = [
        HotkeyBinding(command: .focusZone(.left), keyCode: 18, keyLabel: "1", modifiers: .controlOption),
        HotkeyBinding(command: .focusZone(.center), keyCode: 19, keyLabel: "2", modifiers: .controlOption),
        HotkeyBinding(command: .focusZone(.right), keyCode: 20, keyLabel: "3", modifiers: .controlOption),
        HotkeyBinding(command: .moveFocusedWindow(.left), keyCode: 18, keyLabel: "1", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindow(.center), keyCode: 19, keyLabel: "2", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindow(.right), keyCode: 20, keyLabel: "3", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindowRelative(.left), keyCode: 123, keyLabel: "Left Arrow", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindowRelative(.right), keyCode: 124, keyLabel: "Right Arrow", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindowRelative(.down), keyCode: 125, keyLabel: "Down Arrow", modifiers: .controlOptionShift),
        HotkeyBinding(command: .moveFocusedWindowRelative(.up), keyCode: 126, keyLabel: "Up Arrow", modifiers: .controlOptionShift),
        HotkeyBinding(command: .nextWindowInStack, keyCode: 125, keyLabel: "Down Arrow", modifiers: .controlOption),
        HotkeyBinding(command: .previousWindowInStack, keyCode: 126, keyLabel: "Up Arrow", modifiers: .controlOption),
        HotkeyBinding(command: .openGlobalSwitcher, keyCode: 48, keyLabel: "Tab", modifiers: .commandOnly),
        HotkeyBinding(
            command: .openZoneSwitcher,
            keyCode: 48,
            keyLabel: "Tab",
            modifiers: HotkeyModifiers(command: false, control: false, option: true, shift: false)
        )
    ]

    init(
        id: UUID = UUID(),
        command: HotkeyCommand,
        keyCode: Int64,
        keyLabel: String,
        modifiers: HotkeyModifiers,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.command = command
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }
}
