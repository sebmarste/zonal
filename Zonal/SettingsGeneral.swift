import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var generalSection: some View {
        VStack(spacing: 12) {
            Panel(maxHeight: false) { systemAccess }
            Panel(maxHeight: false) {
                ApplicationRulesView(configuration: $configuration, zones: zoneCatalog, commit: { persist() })
            }
            Text("Appearance")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            appearanceSection
            Text("Recovery")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Panel(maxHeight: false) { behaviorSection }
            Panel(maxHeight: false) { recentActionsSection }
        }
    }

    var appearanceSection: some View {
        VStack(spacing: 12) {
            Panel(maxHeight: false) { themeSection }
            Panel(maxHeight: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tabs").font(.headline)
                    Picker("Tab edge", selection: Binding(get: { configuration.tabEdge },
                        set: { configuration.tabEdge = $0; persist() })) {
                        ForEach(ZoneTabEdge.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Tab labels", selection: Binding(get: { configuration.tabShowsNames },
                        set: { configuration.tabShowsNames = $0; persist() })) {
                        Text("Icons and full names").tag(true)
                        Text("Icons only").tag(false)
                    }
                    Picker("Overlapping zone tabs", selection: Binding(
                        get: { configuration.overlappingZoneTabs ?? .zoneShortcuts },
                        set: { configuration.overlappingZoneTabs = $0; persist() })) {
                        ForEach(OverlappingZoneTabs.allCases) { Text($0.title).tag($0) }
                    }
                    Text("For zones with identical frames on the same display. All windows combines their most-recent-first history; the leading icon follows the active window’s zone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Applies to tabs in every zone and display profile.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(maxHeight: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notifications").font(.headline)
                    Picker("Show", selection: behaviorBinding(\.feedbackMode)) {
                        ForEach(FeedbackMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Position", selection: behaviorBinding(\.feedbackCorner)) {
                        ForEach(FloatingHUDCorner.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        }
    }

    var switchingSection: some View {
        Panel(maxHeight: false) {
            VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Command–Tab",
                selection: Binding(
                    get: { configuration.useNativeCommandTab },
                    set: {
                        configuration.useNativeCommandTab = $0
                        persist()
                    }
                )
            ) {
                Text(SwitcherMode.allWindows.title).tag(false)
                Text("macOS Apps").tag(true)
            }
            .pickerStyle(.segmented)
            Text(
                configuration.useNativeCommandTab
                    ? "macOS keeps Command–Tab. Option–Tab opens Zonal for the current zone."
                    : "Zonal uses Command–Tab for every managed window, including multiple windows from one app."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(
                "Use macOS Command–Tab when a full-screen Space cannot be linked",
                isOn: Binding(
                    get: { configuration.useNativeCommandTabInFullScreen },
                    set: {
                        configuration.useNativeCommandTabInFullScreen = $0
                        persist()
                    }
                )
            )
            .disabled(configuration.useNativeCommandTab)

                Toggle("Show shortcut guide", isOn: behaviorBinding(\.showSwitcherShortcutGuide))
                Text("Show the shortcut guide beneath the window switcher.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("Both switchers show managed windows in the current macOS Space.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Switcher displays", selection: behaviorBinding(\.switcherDisplayScope)) {
                    ForEach(SwitcherDisplayScope.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }

    var draggingSection: some View {
        Panel(maxHeight: false) {
            VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Zone targets while dragging",
                selection: Binding(
                    get: { configuration.dragZoneActivationMode },
                    set: {
                        configuration.dragZoneActivationMode = $0
                        persist()
                    }
                )
            ) {
                ForEach(DragZoneActivationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(
                configuration.dragZoneActivationMode == .shiftKey
                    ? "Hold Shift while dragging a window to show Zonal targets. You can press or release it at any point during the drag."
                    : configuration.dragZoneActivationMode == .always
                        ? "Zonal targets appear whenever a window is dragged."
                        : "Dragging keeps custom positions without showing Zonal targets or fitting windows to zones."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            }
        }
    }

    func behaviorBinding<Value>(_ keyPath: WritableKeyPath<WindowBehaviorSettings, Value>) -> Binding<Value> {
        Binding(get: { configuration.behavior[keyPath: keyPath] },
                set: { configuration.behavior[keyPath: keyPath] = $0; persist() })
    }

    var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatically restore saved placements").font(.headline)
            Toggle("When Zonal starts", isOn: behaviorBinding(\.restoreOnLaunch))
            Toggle("After wake or unlock", isOn: behaviorBinding(\.restoreOnWake))
            Toggle("When displays change", isOn: behaviorBinding(\.restoreOnDisplayChange))
            Toggle("When the current Space changes", isOn: behaviorBinding(\.restoreOnSpaceChange))
            Text("Restore moves recognized windows to their saved positions. If Zonal cannot identify a window reliably, it leaves it alone. Dragging a window updates its saved position. These options control automatic restores; Restore Window Positions is always available.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var recentActionsSection: some View {
        let actions = appContainer.recentWindowActions
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent window actions").font(.headline)
                Spacer()
                Button("Undo Last Action") { appContainer.undoLastWindowAction() }
                    .disabled(!appContainer.canUndoLastWindowAction)
            }
            Text("Undo runs newest first. Configure an Undo shortcut in Switching & Shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
            if actions.isEmpty {
                Text("No window actions to undo.").foregroundStyle(.secondary)
            }
            ForEach(Array(actions.prefix(showAllRecentActions ? actions.count : 5))) { action in
                HStack {
                    Text(action.name)
                    Spacer()
                    Text("\(action.entries.count) window(s)").foregroundStyle(.secondary)
                    Text(action.createdAt, style: .time).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if actions.count > 5 {
                Button(showAllRecentActions ? "Show Less" : "Show More") {
                    showAllRecentActions.toggle()
                }
                .buttonStyle(.link)
            }
        }
    }

    var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)

            Picker(
                "Theme",
                selection: Binding(
                    get: { configuration.theme },
                    set: {
                        configuration.theme = $0
                        persist()
                    }
                )
            ) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text("Choose Zonal's appearance or keep it in sync with macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle(
                "Outline the active window",
                isOn: Binding(
                    get: { configuration.showActiveWindowOutline },
                    set: {
                        configuration.showActiveWindowOutline = $0
                        persist()
                    }
                )
            )
            HStack {
                Picker(
                    "Color",
                    selection: Binding(
                        get: { configuration.activeWindowOutlineColor },
                        set: {
                            configuration.activeWindowOutlineColor = $0
                            persist()
                        }
                    )
                ) {
                    ForEach(ActiveWindowOutlineColor.allCases) { color in
                        Text(color.title).tag(color)
                    }
                }
                Slider(
                    value: Binding(
                        get: { configuration.activeWindowOutlineWidth },
                        set: {
                            configuration.activeWindowOutlineWidth = $0
                            persist()
                        }
                    ),
                    in: 1...8,
                    step: 1
                )
                Text("\(Int(configuration.activeWindowOutlineWidth)) pt")
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            Picker("Outline pulse", selection: Binding(
                get: { configuration.behavior.outlinePulseMode },
                set: { configuration.behavior.outlinePulseMode = $0; persist() }
            )) {
                ForEach(OutlinePulseMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(!configuration.showActiveWindowOutline)
            Text("Color and thickness also style the active zone in the window switcher. Active tabs use a subtle fill.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }


}
