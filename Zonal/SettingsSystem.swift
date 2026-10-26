import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var systemAccess: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System")
                    .font(.headline)
                Spacer()
                if configuration.setupVersion < 1 {
                    Button("Set Up This Mac…") {
                        showSetupAssistant = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Toggle(
                "Launch Zonal at login",
                isOn: Binding(
                    get: { appContainer.launchAtLoginState.isRequested },
                    set: appContainer.setLaunchAtLoginEnabled
                )
            )
            .disabled(appContainer.launchAtLoginState == .unavailable)
            Text(appContainer.launchAtLoginState.detail)
                .font(.caption)
                .foregroundStyle(
                    appContainer.launchAtLoginState == .requiresApproval
                        ? Color.orange
                        : Color.secondary
                )
            if appContainer.launchAtLoginState == .registrationMissing {
                Button("Retry Launch at Login") { appContainer.setLaunchAtLoginEnabled(true) }
                    .buttonStyle(.link)
            }
            if appContainer.launchAtLoginState == .requiresApproval {
                Button("Open Login Items Settings") {
                    appContainer.openLoginItemsSettings()
                }
                .buttonStyle(.link)
            }
            if let errorMessage = appContainer.launchAtLoginErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            PermissionRow(
                title: "Accessibility",
                detail: "Required to observe, focus, resize, and place windows.",
                isGranted: appContainer.menuSnapshot.accessibilityTrusted,
                requestAction: appContainer.requestAccessibilityPermission,
                settingsAction: appContainer.openAccessibilitySettings
            )

            Divider()

            PermissionRow(
                title: "Input Monitoring",
                detail: "Required for global shortcuts and drag detection while other apps are active.",
                isGranted: appContainer.menuSnapshot.inputMonitoringGranted,
                requestAction: appContainer.requestInputMonitoringPermission,
                settingsAction: appContainer.openInputMonitoringSettings
            )

            Divider()

            Divider()

            Button {
                appContainer.quit()
            } label: {
                Label("Quit Zonal", systemImage: "power")
            }
            .buttonStyle(.bordered)
        }
    }


}
