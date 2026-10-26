import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WindowInspectorView: View {
    @ObservedObject var appContainer: AppContainer
    var zones: [Zone]

    var body: some View {
        let _ = appContainer.windowManagementRevision
        let summaries = appContainer.windowAssignmentSummaries()
        let live = summaries.filter { $0.isLive && !$0.isExcluded }
        let remembered = summaries.filter { !$0.isLive && !$0.isExcluded }

        VStack(alignment: .leading, spacing: 12) {
            Panel(maxHeight: false) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current Space")
                            .font(.headline)
                        Text("See each window’s zone, move or fit a window, or ignore it. App defaults and ignored apps are in General → Application Rules.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appContainer.rescanWindows()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                if live.isEmpty {
                    ContentUnavailableView(
                        "No Managed Windows",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text("Open a window on the current Space or check system access in General.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(live) { summary in
                        WindowAssignmentRow(
                            summary: summary,
                            zones: zones,
                            move: { zoneID in
                                appContainer.updateWindowAssignment(summary.id, zoneID: zoneID, fitToZone: true)
                            },
                            fit: {
                                appContainer.updateWindowAssignment(summary.id, zoneID: summary.zoneID, fitToZone: true)
                            },
                            setManagementMode: {
                                appContainer.setWindowManagementMode($0, assignmentID: summary.id)
                            },
                            forget: nil
                        )
                    }
                }
            }

            Panel(maxHeight: false) {
                Text("Remembered Windows")
                    .font(.headline)
                Text("Zonal remembers these windows so they can return to their zones when they reopen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if remembered.isEmpty {
                    Text("No unavailable windows are remembered.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remembered) { summary in
                        WindowAssignmentRow(
                            summary: summary,
                            zones: zones,
                            move: { zoneID in
                                appContainer.updateWindowAssignment(summary.id, zoneID: zoneID, fitToZone: true)
                            },
                            fit: {
                                appContainer.updateWindowAssignment(summary.id, zoneID: summary.zoneID, fitToZone: true)
                            },
                            setManagementMode: {
                                appContainer.setWindowManagementMode($0, assignmentID: summary.id)
                            },
                            forget: { appContainer.forgetWindowAssignment(summary.id) }
                        )
                    }
                }
            }

        }
    }
}

private struct WindowAssignmentRow: View {
    var summary: WindowAssignmentSummary
    var zones: [Zone]
    var move: (ZoneID) -> Void
    var fit: () -> Void
    var setManagementMode: (WindowManagementMode) -> Void
    var forget: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 38, height: 38)
                .overlay {
                    Text(String(summary.appName.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.isZonalUtility ? "Zonal Settings" : summary.appName)
                        .font(.body.weight(.semibold))
                    if summary.isZonalUtility {
                        Text("Utility Window")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quinary, in: Capsule())
                    }
                }
                if let title = summary.title,
                   !title.isEmpty,
                   title != summary.appName {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(summary.isLive ? summary.placementKind.title : "Last seen \(summary.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Zone", selection: Binding(
                get: { summary.zoneID },
                set: { zoneID in move(zoneID) }
            )) {
                ForEach(zones) { zone in
                    Text(zone.name).tag(zone.id)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            if summary.placementKind != .fitted {
                Button(ZoneTabAction.fit.title, action: fit)
                    .buttonStyle(.bordered)
            }

            Menu {
                Button(summary.managementMode == .ignored ? "Manage Window" : "Ignore Window") {
                    setManagementMode(summary.managementMode == .ignored ? .managed : .ignored)
                }
                if let forget {
                    Button("Forget Window", role: .destructive, action: forget)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More actions for \(summary.appName)")
        }
        .padding(10)
        .opacity(summary.managementMode == .ignored ? 0.62 : 1)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}


struct ApplicationRulesView: View {
    @Binding var configuration: ZonalConfiguration
    var zones: [Zone]
    var commit: () -> Void
    @State private var addedApplications = Set<String>()
    @State private var selectionError: String?

    var body: some View {
        let identifiers = Set(configuration.excludedBundleIdentifiers)
            .union(configuration.windowDefaultZoneRules.map(\.bundleIdentifier))
            .union(addedApplications).sorted { applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Application Rules").font(.headline)
                Spacer()
                Button("Add Application…", action: chooseApplication)
            }
            Text("Choose a default zone for new windows, or ignore an app in Zonal. Existing window placements are kept.")
                .font(.caption).foregroundStyle(.secondary)
            if identifiers.isEmpty { Text("All apps use automatic placement.").foregroundStyle(.secondary) }
            ForEach(identifiers, id: \.self) { identifier in
                HStack {
                    Text(applicationName(identifier)).help(identifier)
                    Spacer()
                    Picker("Default zone", selection: Binding<ZoneID?>(
                        get: { configuration.windowDefaultZoneRules.first { $0.bundleIdentifier == identifier }?.zoneID },
                        set: { zone in
                            configuration.windowDefaultZoneRules.removeAll { $0.bundleIdentifier == identifier }
                            if let zone { configuration.windowDefaultZoneRules.append(WindowDefaultZoneRule(bundleIdentifier: identifier, zoneID: zone)) }
                            commit()
                        })) {
                        Text("Automatic").tag(ZoneID?.none)
                        ForEach(zones) { Text($0.name).tag(ZoneID?.some($0.id)) }
                    }
                    .disabled(configuration.excludedBundleIdentifiers.contains(identifier))
                    Toggle("Ignore App", isOn: Binding(
                        get: { configuration.excludedBundleIdentifiers.contains(identifier) },
                        set: { excluded in
                            addedApplications.insert(identifier)
                            configuration.excludedBundleIdentifiers.removeAll { $0 == identifier }
                            if excluded { configuration.excludedBundleIdentifiers.append(identifier) }
                            commit()
                        }))
                    Button("Reset") {
                        configuration.windowDefaultZoneRules.removeAll { $0.bundleIdentifier == identifier }
                        configuration.excludedBundleIdentifiers.removeAll { $0 == identifier }
                        addedApplications.remove(identifier)
                        commit()
                    }
                    .help("Restore automatic placement and include this app in Zonal")
                }
            }
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.red) }
        }
    }

    private func applicationName(_ identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let identifier = Bundle(url: url)?.bundleIdentifier else {
                selectionError = "This application has no bundle identifier. Choose another app."
                return
            }
            selectionError = nil
            addedApplications.insert(identifier)
        }
    }
}
