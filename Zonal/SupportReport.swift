import AppKit
import SwiftUI

// An allowlist: no arbitrary runtime strings, window identities, names, or paths.
enum SupportReport {
    struct RestoreCounts {
        var moved: Int
        var unchanged: Int
        var skipped: Int
        var failed: Int
    }

    static let issuesURL = URL(string: "https://github.com/sebmarste/zonal/issues/new")!

    static func diagnostics(version: String, build: String, system: String,
                            accessibility: Bool, inputMonitoring: Bool, keyboardCapture: Bool,
                            tracking: Bool, displayCount: Int, profileCount: Int, zoneCount: Int,
                            windowCount: Int, restoreCounts: [RestoreCounts]) -> String {
        """
        Zonal \(version) (\(build))
        macOS: \(system)
        Accessibility: \(accessibility)
        Input Monitoring: \(inputMonitoring)
        Keyboard capture: \(keyboardCapture)
        Window tracking: \(tracking)
        Displays: \(displayCount), profiles: \(profileCount), zones: \(zoneCount), windows: \(windowCount)
        Recent restore outcomes:
        \(restoreCounts.map { "moved=\($0.moved) unchanged=\($0.unchanged) skipped=\($0.skipped) failed=\($0.failed)" }.joined(separator: "\n"))
        """
    }

    static func draft(diagnostics: String) -> String {
        """
        ## What happened?
        Describe the problem here.

        ## Steps to reproduce
        1.

        ## Expected behavior

        ## Diagnostics
        ```text
        \(diagnostics)
        ```
        """
    }

    static func issueURL(report: String) -> URL? {
        var components = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: report)]
        guard let url = components.url, url.absoluteString.utf8.count <= 8_000 else { return nil }
        return url
    }
}

struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State var report: String
    var detailedDiagnostics: () -> String
    @State private var addedDetails = false
    @State private var copiedLongReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Bug Report").font(.title2.bold())
            Text("Edit the description and remove anything private. Opening GitHub sends the draft in a browser URL, which may stay in browser history. You submit the issue yourself.")
                .foregroundStyle(.secondary)
            TextEditor(text: $report).font(.system(.body, design: .monospaced))
                .accessibilityLabel("Bug report draft")
            DisclosureGroup("Additional diagnostics for difficult problems") {
                Text("Detailed diagnostics may include your username, application identifiers, display and profile names. Review the appended text before sharing. Never attach your entire Application Support folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Append Detailed Diagnostics") {
                    report += "\n\n## Detailed diagnostics (review before sharing)\n```text\n" + detailedDiagnostics() + "\n```\n"
                    addedDetails = true
                }.disabled(addedDetails)
            }
            if copiedLongReport {
                Text("The report is too long for a link. It was copied: paste it into the GitHub issue body.").font(.callout)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy Report") { copyReport() }
                Button("Open Report on GitHub") {
                    copyReport()
                    let url = SupportReport.issueURL(report: report)
                    copiedLongReport = url == nil
                    NSWorkspace.shared.open(url ?? SupportReport.issuesURL)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 760, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
