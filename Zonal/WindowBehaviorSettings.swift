import Foundation

enum FeedbackMode: String, Codable, CaseIterable, Identifiable {
    case actionsAndErrors, errorsOnly
    var id: String { rawValue }
    var title: String { self == .errorsOnly ? "Errors only" : "Actions and errors" }
}

enum SwitcherDisplayScope: String, Codable, CaseIterable, Identifiable {
    case allDisplays, focusedDisplay
    var id: String { rawValue }
    var title: String { self == .allDisplays ? "All displays in this Space" : "Focused display only" }
}

enum OutlinePulseMode: String, Codable, CaseIterable, Identifiable {
    case off, switcherOnly, allFocusedWindows
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .switcherOnly: "Only after window switcher"
        case .allFocusedWindows: "All focused windows"
        }
    }
}

struct WindowDisplayScopePolicy {
    func includedWindowIDs(scope: SwitcherDisplayScope, focused: LiveWindowID?,
                           frames: [LiveWindowID: CGRect], displays: [CGRect]) -> Set<LiveWindowID>? {
        guard scope == .focusedDisplay, let focused, let focusFrame = frames[focused],
              let target = displayIndex(for: focusFrame, displays: displays) else { return nil }
        return Set(frames.compactMap { id, frame in displayIndex(for: frame, displays: displays) == target ? id : nil })
    }

    private func displayIndex(for frame: CGRect, displays: [CGRect]) -> Int? {
        displays.indices.filter { displays[$0].intersects(frame) }.max {
            let left = displays[$0].intersection(frame)
            let right = displays[$1].intersection(frame)
            return left.width * left.height < right.width * right.height
        }
    }
}

struct WindowBehaviorSettings: Codable, Equatable {
    var feedbackMode: FeedbackMode = .actionsAndErrors
    var feedbackCorner: FloatingHUDCorner = .bottomTrailing
    var showSwitcherShortcutGuide = true
    var switcherDisplayScope: SwitcherDisplayScope = .allDisplays
    var outlinePulseMode: OutlinePulseMode = .switcherOnly
    var restoreOnLaunch = true
    var restoreOnWake = true
    var restoreOnDisplayChange = true
    var restoreOnSpaceChange = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case feedbackMode, feedbackCorner, switcherDisplayScope, outlinePulseMode
        case showSwitcherShortcutGuide = "showSwitcherHotkeys"
        case restoreOnLaunch, restoreOnWake, restoreOnDisplayChange, restoreOnSpaceChange
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showSwitcherShortcutGuide = try values.decodeIfPresent(Bool.self, forKey: .showSwitcherShortcutGuide) ?? true
        feedbackMode = try values.decode(FeedbackMode.self, forKey: .feedbackMode)
        feedbackCorner = try values.decode(FloatingHUDCorner.self, forKey: .feedbackCorner)
        switcherDisplayScope = try values.decode(SwitcherDisplayScope.self, forKey: .switcherDisplayScope)
        outlinePulseMode = try values.decode(OutlinePulseMode.self, forKey: .outlinePulseMode)
        restoreOnLaunch = try values.decode(Bool.self, forKey: .restoreOnLaunch)
        restoreOnWake = try values.decode(Bool.self, forKey: .restoreOnWake)
        restoreOnDisplayChange = try values.decode(Bool.self, forKey: .restoreOnDisplayChange)
        restoreOnSpaceChange = try values.decode(Bool.self, forKey: .restoreOnSpaceChange)
    }

    func allows(_ trigger: RestoreTrigger) -> Bool {
        switch trigger {
        case .launch: restoreOnLaunch
        case .systemResume: restoreOnWake
        case .displayChange: restoreOnDisplayChange
        case .spaceChange: restoreOnSpaceChange
        default: true
        }
    }

    func shows(_ content: WindowActionNotification) -> Bool {
        feedbackMode == .actionsAndErrors || content.tone == .warning
    }
}
