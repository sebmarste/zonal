import AppKit
import SwiftUI

extension SettingsView {
    var diagnosticsSection: some View {
        VStack(spacing: 12) {
            Panel(maxHeight: false) { troubleshootingStatus }
            Panel(maxHeight: false) {
                Text("Window tools").font(.headline)
                HStack {
                    Button("Rescan Windows") { appContainer.rescanWindows() }
                    Button(HotkeyCommand.restore.title) { appContainer.restoreNow() }
                    Button("Inspect Windows…") { showWindowInspector = true }
                }
                .disabled(store.readOnlyReason != nil)
                Text("Rescan refreshes the window list. Restore moves recognized windows to their saved placements.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = appContainer.windowScanStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel(maxHeight: false) {
                Text("Report a problem").font(.headline)
                Text("Review, edit, or copy a report before opening a report on GitHub. Nothing is sent automatically; detailed diagnostics are optional.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Create Bug Report…") {
                    bugReport = SupportReport.draft(diagnostics: appContainer.privacySafeDiagnostics())
                }.buttonStyle(.borderedProminent)
            }
            Panel(maxHeight: false) {
                Text("Last restore").font(.headline)
                let records = store.loadRestoreHistory()
                if let latest = records.first {
                    restoreHistoryRow(latest)
                    if records.count > 1 {
                        DisclosureGroup("Earlier restores (\(records.count - 1))") {
                            ForEach(records.dropFirst()) { record in
                                restoreHistoryRow(record).padding(.top, 6)
                            }
                        }
                    }
                } else {
                    Text("No restore attempts recorded yet.").foregroundStyle(.secondary)
                }
            }
            Panel(maxHeight: false) {
                DisclosureGroup("Advanced Diagnostics") {
                    Toggle("Show window interaction diagnostics", isOn: Binding(
                        get: { configuration.showInteractionDiagnostics },
                        set: { configuration.showInteractionDiagnostics = $0; persist() }
                    ))
                    .disabled(store.readOnlyReason != nil)
                    Text("Shows an indicator when Zonal classifies a move, resize, or zone drop. Use this when investigating drag behavior; recent events are available in the optional detailed bug report.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var troubleshootingStatus: some View {
        let status = appContainer.menuSnapshot
        let snapshot = profileManager.currentSnapshot()
        let matched = profileManager.matchedProfile(for: snapshot)
        let additional = appContainer.healthFindings.filter {
            !["accessibility", "input-monitoring", "display-profile"].contains($0.id)
        }
        let needsAttention = !status.accessibilityTrusted || !status.inputMonitoringGranted
            || !status.keyboardCaptureAvailable || !status.trackingActive || matched == nil
            || additional.contains { $0.level != .ok } || store.readOnlyReason != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(needsAttention ? "Needs attention" : "Basic checks are healthy",
                      systemImage: needsAttention ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.headline)
                Spacer()
                Button("Check Again") {
                    appContainer.recheckPermissions()
                    appContainer.runHealthCheck()
                }
            }
            if !status.accessibilityTrusted || !status.inputMonitoringGranted {
                HStack {
                    Text("Allow Accessibility and Input Monitoring to manage windows and use global shortcuts.")
                    Spacer()
                    Button("Permissions…") { selectedSection = .general }
                }
            }
            if status.accessibilityTrusted && status.inputMonitoringGranted
                && (!status.keyboardCaptureAvailable || !status.trackingActive) {
                Text("Window tracking or keyboard capture is unavailable. Check Again after granting permissions; restart Zonal if macOS requests it.")
            }
            if matched == nil {
                HStack {
                    Text("This display setup has no matching profile. Capture it before restoring windows.")
                    Spacer()
                    Button("Configure Displays…") { selectedSection = .profiles }
                }
            }
            ForEach(additional.filter { $0.level != .ok }) { healthFindingRow($0) }
            DisclosureGroup("Status details") {
                VStack(alignment: .leading, spacing: 7) {
                    LabeledContent("Accessibility", value: status.accessibilityTrusted ? "Granted" : "Missing")
                    LabeledContent("Input Monitoring", value: status.inputMonitoringGranted ? "Granted" : "Missing")
                    LabeledContent("Keyboard capture", value: status.keyboardCaptureAvailable ? "Active" : "Unavailable")
                    LabeledContent("Window tracking", value: status.trackingActive ? "Active" : "Unavailable")
                    LabeledContent("Display setup", value: profileManager.setupName(for: snapshot))
                    LabeledContent("Matched profile", value: matched?.name ?? "Not configured")
                    ForEach(additional.filter { $0.level == .ok }) { healthFindingRow($0) }
                }.padding(.top, 6)
            }
        }
        .font(.callout)
    }

    func healthFindingRow(_ finding: ZonalHealthFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.level.systemImage).foregroundStyle(finding.level.color)
            Text(finding.title).fontWeight(.medium)
            Text(finding.detail).foregroundStyle(.secondary).textSelection(.enabled)
        }.font(.caption)
    }

    func restoreHistoryRow(_ record: RestoreRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if record.unmatched > 0 {
                    Text("\(record.unmatched) remembered windows were unavailable.")
                }
                ForEach(record.issues) { issue in
                    Text("\(issue.appName): \(issue.reason.title)")
                }
                if record.issues.isEmpty && record.unmatched == 0 {
                    Text("No window-specific issues were recorded.")
                }
            }.font(.caption).padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(record.profileName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                Text("\(record.moved) moved · \(record.unchanged) unchanged · \(record.skipped) skipped · \(record.failed) failed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
