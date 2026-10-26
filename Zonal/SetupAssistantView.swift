import SwiftUI

enum WorkspaceTemplate: String, CaseIterable, Identifiable {
    case singleFocus
    case focusReference
    case threeColumns
    case layeredFocus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleFocus: "One Focus Zone"
        case .focusReference: "Focus + Reference"
        case .threeColumns: "Three Columns"
        case .layeredFocus: "Layered Focus"
        }
    }

    var detail: String {
        switch self {
        case .singleFocus: "A simple full-display home for every window."
        case .focusReference: "Primary work with a supporting area beside it."
        case .threeColumns: "Reference, focus, and communication on a wide display."
        case .layeredFocus: "Overlapping full-display zones for Focus, Reference, and Communication. Switch between them without rearranging your layout."
        }
    }

    var zones: [Zone] {
        switch self {
        case .singleFocus:
            [Zone(id: .center, name: "Focus", frame: .full)]
        case .focusReference:
            [
                Zone(
                    id: .left,
                    name: "Reference",
                    frame: NormalizedFrame(x: 0, y: 0, width: 0.32, height: 1)
                ),
                Zone(
                    id: .center,
                    name: "Focus",
                    frame: NormalizedFrame(x: 0.32, y: 0, width: 0.68, height: 1)
                ),
            ]
        case .threeColumns:
            [
                Zone(
                    id: .left,
                    name: "Reference",
                    frame: NormalizedFrame(x: 0, y: 0, width: 0.22, height: 1)
                ),
                Zone(
                    id: .center,
                    name: "Focus",
                    frame: NormalizedFrame(x: 0.22, y: 0, width: 0.56, height: 1)
                ),
                Zone(
                    id: .right,
                    name: "Communication",
                    frame: NormalizedFrame(x: 0.78, y: 0, width: 0.22, height: 1)
                ),
            ]
        case .layeredFocus:
            [
                Zone(id: .center, name: "Focus", frame: .full),
                Zone(id: .left, name: "Reference", frame: .full),
                Zone(id: .right, name: "Communication", frame: .full),
            ]
        }
    }

    var mainZoneID: ZoneID { .center }
}

struct SetupAssistantView: View {
    @ObservedObject private var appContainer = AppContainer.shared
    var snapshot: DisplaySnapshot
    var cancel: () -> Void
    var complete: (WorkspaceTemplate, Bool, Bool) -> Void

    @State private var selectedTemplate: WorkspaceTemplate
    @Binding var replaceCommandTab: Bool
    @State private var launchAtLogin = false
    @State private var step = 0

    init(
        snapshot: DisplaySnapshot,
        launchAtLoginInitiallyEnabled: Bool,
        replaceCommandTab: Binding<Bool>,
        cancel: @escaping () -> Void,
        complete: @escaping (WorkspaceTemplate, Bool, Bool) -> Void
    ) {
        self.snapshot = snapshot
        self._replaceCommandTab = replaceCommandTab
        self.cancel = cancel
        self.complete = complete
        _selectedTemplate = State(initialValue: snapshot.hasUltrawide ? .threeColumns : .focusReference)
        _launchAtLogin = State(initialValue: launchAtLoginInitiallyEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Text(replaceCommandTab
                 ? "Command–Tab uses Zonal by default once permissions are granted. Change this on the next step or in Settings → Switching & Shortcuts."
                 : "Command–Tab currently uses macOS. You can change this on the next step or in Settings → Switching & Shortcuts.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                if step == 0 { templateStep } else { behaviorStep }
            }
            .frame(height: 420)

            Divider()
            HStack {
                Button("Not Now", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == 0 ? "Continue" : "Create Profile") {
                    if step == 0 {
                        step = 1
                    } else {
                        complete(selectedTemplate, replaceCommandTab, launchAtLogin)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 700)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set Up Zonal")
                .font(.largeTitle.weight(.semibold))
            Text(
                step == 0
                    ? "Choose a starting layout for the displays connected now."
                    : "Choose how you want to switch windows."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisplayArrangementPreview(snapshot: snapshot)
                .frame(height: 150)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(WorkspaceTemplate.allCases) { template in
                    Button {
                        selectedTemplate = template
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            TemplatePreview(zones: template.zones)
                                .frame(height: 58)
                            Text(template.title)
                                .font(.headline)
                            Text(template.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                        .background(
                            selectedTemplate == template
                                ? Color.accentColor.opacity(0.13)
                                : Color(nsColor: .controlBackgroundColor).opacity(0.58),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    selectedTemplate == template ? Color.accentColor : Color.primary.opacity(0.10),
                                    lineWidth: selectedTemplate == template ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selectedTemplate == template ? "Selected" : "")
                }
            }

            Text("Templates only create a starting point. Zone names and positions remain fully editable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var behaviorStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(maxHeight: false) {
                Text("Permissions and keyboard shortcuts").font(.headline)
                PermissionRow(title: "Accessibility", detail: "Observe, focus, and place windows.",
                    isGranted: appContainer.menuSnapshot.accessibilityTrusted,
                    requestAction: appContainer.requestAccessibilityPermission,
                    settingsAction: appContainer.openAccessibilitySettings)
                PermissionRow(title: "Input Monitoring", detail: "Global shortcuts and drag detection.",
                    isGranted: appContainer.menuSnapshot.inputMonitoringGranted,
                    requestAction: appContainer.requestInputMonitoringPermission,
                    settingsAction: appContainer.openInputMonitoringSettings)
                Text(appContainer.menuSnapshot.keyboardCaptureAvailable
                     ? "Keyboard shortcuts are ready. Your switching choice is active."
                     : "Waiting for keyboard shortcut access. macOS keeps handling Command–Tab until Zonal can capture it. If macOS asks you to restart Zonal after granting permission, do so; your choice is saved.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Recheck Permissions") { appContainer.recheckPermissions() }
            }
            Panel(maxHeight: false) {
                Text("Your daily shortcuts")
                    .font(.headline)
                LabeledContent(SwitcherMode.byZone.title, value: "Option–Tab")
                LabeledContent("Next window in zone", value: "Control–Option–Down Arrow")
                LabeledContent("Previous window in zone", value: "Control–Option–Up Arrow")
            }

            Panel(maxHeight: false) {
                Toggle("Use Zonal for Command–Tab", isOn: $replaceCommandTab)
                Text(
                    replaceCommandTab
                        ? "Command–Tab will cycle every managed window, including multiple windows from the same app."
                        : "Command–Tab will keep switching macOS apps. Zonal’s By Zone switcher remains available with Option–Tab."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Panel(maxHeight: false) {
                Toggle("Launch Zonal at login", isOn: $launchAtLogin)
                Text("Start Zonal automatically after you sign in. You can change this later in General settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                "Zonal will remember this exact display setup and restore assigned windows when it returns.",
                systemImage: "display.2"
            )
            .font(.callout)
        }
    }
}

private struct TemplatePreview: View {
    var zones: [Zone]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quinary)
                ForEach(zones) { zone in
                    let rect = zone.frame.rect(in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 4, dy: 4))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
