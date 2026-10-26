import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var appContainer = AppContainer.shared
    @State var configuration: ZonalConfiguration
    @State var baselineConfiguration: ZonalConfiguration
    @State var pendingConfigurationWrite: DispatchWorkItem?
    @State var configurationSaveError: String?
    @State var pendingConfigurationOperations = PendingConfigurationOperations()
    @State var configurationBeforePendingCleanup: ZonalConfiguration?
    @State var selectedProfileID: String?
    @State var selectedZoneID: ZoneID?
    @State var selectedSection: SettingsSection = .general
    @State var selectedHotkeyID: UUID?
    @State var draggedZoneID: ZoneID?
    @State var draggedProfileID: String?
    @State var captureDraft: DisplayCaptureDraft?
    @State var profileApplyPreview: ProfileTransitionPreview?
    @State var bugReport: String?
    @State var showSetupAssistant: Bool
    @State var pendingDeletion: SettingsDeletion?
    @State var showWindowInspector = false
    @State var showAllRecentActions = false

    let onPendingEditsChanged: (Bool) -> Void
    let store: PersistenceStore
    let profileManager: ProfileManager

    init(store: PersistenceStore, initialSection: SettingsSection = .general, onPendingEditsChanged: @escaping (Bool) -> Void = { _ in }) {
        self.onPendingEditsChanged = onPendingEditsChanged
        self.store = store
        _selectedSection = State(initialValue: initialSection)
        self.profileManager = ProfileManager(store: store)
        let configuration = store.loadConfiguration()
        let selectedProfileID = configuration.activeProfileID ?? configuration.profiles.first?.id
        let selectedProfile = configuration.profiles.first { $0.id == selectedProfileID } ?? configuration.profiles.first
        _configuration = State(initialValue: configuration)
        _baselineConfiguration = State(initialValue: configuration)
        _configurationSaveError = State(initialValue: store.readOnlyReason)
        _selectedProfileID = State(initialValue: selectedProfileID)
        _selectedZoneID = State(initialValue: selectedProfile?.mainZoneID ?? selectedProfile?.zones.first?.id)
        _selectedHotkeyID = State(initialValue: configuration.hotkeys.first?.id)
        _showSetupAssistant = State(initialValue: configuration.setupVersion < 1 && store.readOnlyReason == nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            selectedSettingsPane
                .disabled(store.readOnlyReason != nil && selectedSection != .diagnostics)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            store.bootstrap()
            reload()
        }
        .onDisappear { flushPendingConfiguration() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            flushPendingConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingConfiguration()
        }
        .safeAreaInset(edge: .bottom) {
            if let configurationSaveError {
                HStack {
                    Label(configurationSaveError, systemImage: "exclamationmark.triangle")
                    Spacer()
                    if store.readOnlyReason == nil { Button("Retry") { persist() } }
                }
                .font(.callout)
                .padding()
                .background(.regularMaterial)
            }
        }
        .onChange(of: selectedProfileID) { _, _ in syncSelectedZoneToSelectedProfile() }
        .sheet(item: $captureDraft) { draft in
            DisplayCaptureSheet(
                snapshot: draft.snapshot,
                setupName: Binding(
                    get: { captureDraft?.setupName ?? draft.setupName },
                    set: { captureDraft?.setupName = $0 }
                ),
                cancel: { captureDraft = nil },
                save: { apply in
                    if let captureDraft {
                        saveCapturedSetup(captureDraft, apply: apply)
                    }
                    captureDraft = nil
                }
            )
        }
        .sheet(item: $profileApplyPreview) { preview in
            ProfileApplyPreviewSheet(
                preview: preview,
                cancel: { profileApplyPreview = nil },
                apply: {
                    applyProfileConfirmed(preview.profileID)
                    profileApplyPreview = nil
                }
            )
        }
        .sheet(isPresented: $showSetupAssistant) {
            SetupAssistantView(
                snapshot: profileManager.currentSnapshot(),
                launchAtLoginInitiallyEnabled: appContainer.launchAtLoginState.isRequested,
                replaceCommandTab: Binding(get: { !configuration.useNativeCommandTab }, set: {
                    configuration.useNativeCommandTab = !$0
                    persist()
                }),
                cancel: { showSetupAssistant = false },
                complete: completeSetup
            )
        }
        .sheet(isPresented: Binding(get: { bugReport != nil }, set: { if !$0 { bugReport = nil } })) {
            BugReportView(report: bugReport ?? "", detailedDiagnostics: { appContainer.detailedDiagnostics() })
        }
        .sheet(isPresented: $showWindowInspector) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Inspect Windows").font(.title2.bold())
                    Spacer()
                    Button("Done") { showWindowInspector = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    WindowInspectorView(appContainer: appContainer, zones: zoneCatalog)
                        .disabled(store.readOnlyReason != nil)
                }
            }
            .padding(24).frame(width: 900, height: 620)
        }
        .alert(item: $pendingDeletion) { deletion in
            Alert(
                title: Text(deletion.title),
                message: Text(deletion.message),
                primaryButton: .destructive(Text("Delete")) {
                    confirmDeletion(deletion)
                },
                secondaryButton: .cancel()
            )
        }
    }

    var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Zonal")

                Text("Zonal")
                    .font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.body.weight(selectedSection == section ? .semibold : .regular))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedSection == section ? .primary : .secondary)
                .background {
                    if selectedSection == section {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.quaternary)
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 54)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 220)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color.accentColor.opacity(0.045),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
        }
        .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
    }

    @ViewBuilder
    var selectedSettingsPane: some View {
        switch selectedSection {
        case .general:
            settingsPane(title: "General") {
                generalSection
            }
        case .zones:
            settingsPane(title: "Zones") {
                draggingSection
                zonesSection
            }
        case .profiles:
            settingsPane(title: "Profiles") {
                profilesSection
            }
        case .shortcuts:
            settingsPane(title: "Switching & Shortcuts") {
                switchingSection
                shortcutsSection
            }
        case .diagnostics:
            settingsPane(title: "Troubleshooting") {
                diagnosticsSection
            }
        }
    }

    func settingsPane<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.horizontal, 4)
                content()
            }
            .padding(.top, 30)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}
