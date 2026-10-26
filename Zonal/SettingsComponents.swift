import AppKit
import SwiftUI
import UniformTypeIdentifiers


struct DisplayCaptureDraft: Identifiable {
    var id = UUID()
    var profileID: String
    var snapshot: DisplaySnapshot
    var setupName: String
}

enum SettingsDeletion: Identifiable {
    case zone(id: ZoneID, name: String)
    case profile(id: String, name: String)

    var id: String {
        switch self {
        case .zone(let id, _): "zone-\(id.rawValue)"
        case .profile(let id, _): "profile-\(id)"
        }
    }

    var title: String {
        switch self {
        case .zone(_, let name): "Delete \(name)?"
        case .profile(_, let name): "Delete \(name)?"
        }
    }

    var message: String {
        switch self {
        case .zone:
            "This removes the zone from every display profile and removes its shortcuts. Windows will fall back to the main zone."
        case .profile:
            "This removes the display profile and its saved window placements. This cannot be undone."
        }
    }
}

struct DisplayCaptureSheet: View {
    var snapshot: DisplaySnapshot
    @Binding var setupName: String
    var cancel: () -> Void
    var save: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Use Current Display Setup")
                    .font(.title2.weight(.semibold))
                Text("Confirm the arrangement and choose how this setup should be named.")
                    .foregroundStyle(.secondary)
            }

            DisplayArrangementPreview(snapshot: snapshot)
                .frame(height: 220)

            TextField("Setup name", text: $setupName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("\(snapshot.displays.count) \(snapshot.displays.count == 1 ? "display" : "displays") detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: { save(false) })
                Button("Save & Apply", action: { save(true) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct ProfileApplyPreviewSheet: View {
    var preview: ProfileTransitionPreview
    var cancel: () -> Void
    var apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Apply \(preview.profileName)?")
                    .font(.title2.weight(.semibold))
                Text("Review the effect before any windows move.")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                previewRow("Will move", value: preview.willMove, symbol: "arrow.up.left.and.arrow.down.right")
                previewRow("Already placed", value: preview.alreadyPlaced, symbol: "checkmark.circle")
                previewRow("Skipped", value: preview.skipped, symbol: "minus.circle")
                previewRow("Unmatched", value: preview.unmatched, symbol: "questionmark.diamond")
            }
            .padding(14)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if preview.unmatched > 0 {
                Label(
                    "Unmatched windows will be left untouched.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !preview.issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Why windows will be skipped")
                        .font(.headline)
                    ForEach(preview.issues) { issue in
                        HStack(alignment: .firstTextBaseline) {
                            Text(issue.appName)
                                .fontWeight(.medium)
                            Text(issue.reason.title)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply Profile", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func previewRow(_ title: String, value: Int, symbol: String) -> some View {
        GridRow {
            Label(title, systemImage: symbol)
            Text(value, format: .number)
                .font(.body.monospacedDigit().weight(.semibold))
        }
    }
}

struct DisplayArrangementPreview: View {
    var snapshot: DisplaySnapshot

    var body: some View {
        GeometryReader { proxy in
            let desktop = snapshot.desktopFrame
            let available = proxy.size.applyingInset(18)
            let scale = min(
                available.width / max(1, desktop.width),
                available.height / max(1, desktop.height)
            )
            let renderedSize = CGSize(
                width: desktop.width * scale,
                height: desktop.height * scale
            )
            let origin = CGPoint(
                x: (proxy.size.width - renderedSize.width) / 2,
                y: (proxy.size.height - renderedSize.height) / 2
            )

            ZStack(alignment: .topLeading) {
                ForEach(snapshot.displays, id: \.id) { display in
                    let frame = CGRect(
                        x: origin.x + (display.frame.minX - desktop.minX) * scale,
                        y: origin.y + (display.frame.minY - desktop.minY) * scale,
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    )
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(display.isBuiltIn ? 0.14 : 0.09))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                            VStack(spacing: 3) {
                                Text(display.name)
                                    .font(.callout.weight(.semibold))
                                Text("\(Int(display.frame.width)) × \(Int(display.frame.height)) · \(display.scale, specifier: "%.1f")×")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                        }
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityLabel("\(display.name), \(Int(display.frame.width)) by \(Int(display.frame.height))")
                }
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension CGSize {
    func applyingInset(_ inset: CGFloat) -> CGSize {
        CGSize(width: max(1, width - inset * 2), height: max(1, height - inset * 2))
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case zones
    case profiles
    case shortcuts
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .zones: "Zones"
        case .profiles: "Profiles"
        case .shortcuts: "Switching & Shortcuts"
        case .diagnostics: "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .zones: "rectangle.3.group"
        case .profiles: "display.2"
        case .shortcuts: "keyboard"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat
    var maxHeight: Bool
    @ViewBuilder var content: Content

    init(padding: CGFloat = 14, maxHeight: Bool = true, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: maxHeight ? .infinity : nil, alignment: .topLeading)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var panelFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.64)
    }
}

extension ZonalHealthLevel {
    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct ZoneCard: View {
    var zoneID: ZoneID
    @Binding var name: String
    @Binding var isMain: Bool
    @Binding var presentation: ZonePresentationOption
    @Binding var peekWidth: Double
    @Binding var peekDirection: ZonePeekDirection
    @Binding var tabBorderWidth: Double
    var canDelete: Bool
    var select: () -> Void
    var moveBefore: (ZoneID) -> Void
    @Binding var draggedZoneID: ZoneID?
    var deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.secondary)

                TextField("Zone", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    isMain = true
                } label: {
                    Label("Main", systemImage: isMain ? "largecircle.fill.circle" : "circle")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                        .foregroundStyle(isMain ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isMain ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(isMain ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.10), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("The main zone is the fallback for windows without a zone. Its appearance takes priority when zones share tabs.")

                Picker("Presentation", selection: $presentation) {
                    ForEach(ZonePresentationOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!canDelete)
            }
            if presentation == .tabShelf || presentation == .tabFrame {
                if presentation == .tabFrame {
                    HStack {
                        Slider(value: $tabBorderWidth, in: ZoneTabMetrics.borderWidthRange, step: 1) { Text("Frame border") }
                        Text("\(Int(tabBorderWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Text("Zones with the same frame and display share tabs automatically. The focused zone shows its full tab list, with one shortcut per other zone at the far end. The main zone’s appearance and border size take priority when it has tabs enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tabs follow the switcher’s most-recent-first order. Fitted windows share the space beside the tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if presentation == .peekStack {
                HStack {
                    Picker("Peek edge", selection: $peekDirection) {
                        ForEach(ZonePeekDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    Slider(value: $peekWidth, in: 8...160, step: 4) {
                        Text("Peek offset")
                    }
                    Text("\(Int(peekWidth)) pt")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                Text("Windows share one size; switching only changes their position. Peek strips use at most 40% of the zone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: select)
        .onDrag {
            draggedZoneID = zoneID
            return NSItemProvider(object: zoneID.rawValue as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            guard let draggedZoneID else { return false }
            moveBefore(draggedZoneID)
            self.draggedZoneID = nil
            return true
        }
    }
}

struct ProfileListRow: View {
    var profileID: String
    @Binding var name: String
    var isSelected: Bool
    var isMatched: Bool
    var isLastApplied: Bool
    var displayBindingSummary: String
    var canDelete: Bool
    var selectAction: () -> Void
    var moveBefore: (String) -> Void
    @Binding var draggedProfileID: String?
    var bindDisplaysAction: () -> Void
    var activateAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("Drag to reorder")
            VStack(alignment: .leading, spacing: 3) {
                TextField("Profile", text: $name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                Text(displayBindingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: bindDisplaysAction) {
                Label("Use Current Display Setup…", systemImage: "display.2")
            }
            .buttonStyle(.bordered)

            if isMatched {
                Label("Matched now", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if isLastApplied {
                Label("Last applied", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Button("Apply now", action: activateAction)
                .buttonStyle(.link)
            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.72 : 0.48), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: selectAction)
        .onDrag {
            draggedProfileID = profileID
            return NSItemProvider(object: profileID as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            guard let draggedProfileID else { return false }
            moveBefore(draggedProfileID)
            self.draggedProfileID = nil
            return true
        }
    }
}

struct ShortcutExpandableRow: View {
    var title: String
    var shortcut: String
    var isSelected: Bool
    @Binding var isEnabled: Bool
    @Binding var command: HotkeyCommandKind
    @Binding var zone: ZoneID
    var needsZone: Bool
    @Binding var direction: SwitcherArrowKey
    var needsDirection: Bool
    var zones: [Zone]
    var modifiers: HotkeyModifiers
    var key: HotkeyKey
    var recordShortcut: (HotkeyModifiers, HotkeyKey) -> Void
    var selectAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isEnabled ? "keyboard.fill" : "keyboard")
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(shortcut)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isSelected ? 0 : -90))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: selectAction)

            if isSelected {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("Enabled")
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: $isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Command")
                            .foregroundStyle(.secondary)
                        Picker("", selection: $command) {
                            ForEach(HotkeyCommandKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    if needsZone {
                        GridRow {
                            Text("Zone")
                                .foregroundStyle(.secondary)
                            Picker("", selection: $zone) {
                                ForEach(zones) { zone in
                                    Text(zone.name).tag(zone.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    if needsDirection {
                        GridRow {
                            Text("Direction")
                                .foregroundStyle(.secondary)
                            Picker("", selection: $direction) {
                                ForEach(SwitcherArrowKey.allCases) { direction in
                                    Text(direction.title).tag(direction)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    GridRow {
                        Text("Shortcut")
                            .foregroundStyle(.secondary)
                        HStack {
                            ShortcutRecorderView(
                                modifiers: modifiers,
                                key: key,
                                onRecord: recordShortcut
                            )
                            .frame(minWidth: 220)
                            Spacer()
                            Button(role: .destructive, action: deleteAction) {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(.leading, 30)

                Text("Select the recorder, then type the complete shortcut. Escape cancels. Zonal detects duplicates below; macOS or another app may still reserve the same shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.50), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.30) : Color.primary.opacity(0.08), lineWidth: 1)
        }
    }


}

struct PermissionRow: View {
    var title: String
    var detail: String
    var isGranted: Bool
    var requestAction: () -> Void
    var settingsAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isGranted ? .green : .yellow)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant Access", action: requestAction)
            }
            Button("Open Settings", action: settingsAction)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.50), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum HotkeyCommandKind: String, CaseIterable, Identifiable {
    case focusZone
    case moveFocusedWindow
    case moveFocusedWindowRelative
    case nextWindowInStack
    case previousWindowInStack
    case openGlobalSwitcher
    case openZoneSwitcher
    case undo
    case restore

    var id: String { rawValue }

    init(command: HotkeyCommand) {
        switch command {
        case .focusZone: self = .focusZone
        case .moveFocusedWindow: self = .moveFocusedWindow
        case .moveFocusedWindowRelative: self = .moveFocusedWindowRelative
        case .nextWindowInStack: self = .nextWindowInStack
        case .previousWindowInStack: self = .previousWindowInStack
        case .openGlobalSwitcher: self = .openGlobalSwitcher
        case .openZoneSwitcher: self = .openZoneSwitcher
        case .restore: self = .restore
        case .undo: self = .undo
        }
    }

    var title: String { command(zoneID: .center).title }

    func command(zoneID: ZoneID) -> HotkeyCommand {
        switch self {
        case .undo:
            return .undo
        case .restore:
            return .restore
        case .focusZone:
            return .focusZone(zoneID)
        case .moveFocusedWindow:
            return .moveFocusedWindow(zoneID)
        case .moveFocusedWindowRelative:
            return .moveFocusedWindowRelative(.right)
        case .nextWindowInStack:
            return .nextWindowInStack
        case .previousWindowInStack:
            return .previousWindowInStack
        case .openGlobalSwitcher:
            return .openGlobalSwitcher
        case .openZoneSwitcher:
            return .openZoneSwitcher
        }
    }
}

struct HotkeyKey: Hashable, Identifiable {
    var keyCode: Int64
    var label: String

    var id: Int64 { keyCode }

    static let common: [HotkeyKey] = [
        HotkeyKey(keyCode: 18, label: "1"),
        HotkeyKey(keyCode: 19, label: "2"),
        HotkeyKey(keyCode: 20, label: "3"),
        HotkeyKey(keyCode: 21, label: "4"),
        HotkeyKey(keyCode: 23, label: "5"),
        HotkeyKey(keyCode: 22, label: "6"),
        HotkeyKey(keyCode: 26, label: "7"),
        HotkeyKey(keyCode: 28, label: "8"),
        HotkeyKey(keyCode: 25, label: "9"),
        HotkeyKey(keyCode: 29, label: "0"),
        HotkeyKey(keyCode: 15, label: "R"),
        HotkeyKey(keyCode: 17, label: "T"),
        HotkeyKey(keyCode: 32, label: "U"),
        HotkeyKey(keyCode: 34, label: "I"),
        HotkeyKey(keyCode: 31, label: "O"),
        HotkeyKey(keyCode: 35, label: "P"),
        HotkeyKey(keyCode: 49, label: "Space"),
        HotkeyKey(keyCode: 48, label: "Tab"),
        HotkeyKey(keyCode: 123, label: "Left Arrow"),
        HotkeyKey(keyCode: 124, label: "Right Arrow"),
        HotkeyKey(keyCode: 125, label: "Down Arrow"),
        HotkeyKey(keyCode: 126, label: "Up Arrow")
    ]
}
