import AppKit
import Security

@MainActor
struct ZonalDoctor {
    func check(permissions: PermissionsController, loginState: LaunchAtLoginState,
               configuration: ZonalConfiguration, profileManager: ProfileManager,
               automationRunning: Bool) -> [ZonalHealthFinding] {
        var findings: [ZonalHealthFinding] = []
        func add(_ id: String, _ level: ZonalHealthLevel, _ title: String, _ detail: String) {
            findings.append(ZonalHealthFinding(id: id, level: level, title: title, detail: detail))
        }

        add(
            "accessibility",
            permissions.isAccessibilityTrusted ? .ok : .error,
            "Accessibility",
            permissions.isAccessibilityTrusted ? "Granted" : "Missing for this installed copy"
        )
        add(
            "input-monitoring",
            permissions.isInputMonitoringGranted ? .ok : .error,
            "Input Monitoring",
            permissions.isInputMonitoringGranted ? "Granted" : "Missing for this installed copy"
        )

        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        add(
            "installed-copy",
            bundleURL.path.hasPrefix("/Applications/") ? .ok : .warning,
            "Running copy",
            "\(bundleURL.path) · version \(version) (\(build))"
        )

        let copies = installedZonalCopies()
        add(
            "duplicate-copies",
            copies.count <= 1 ? .ok : .warning,
            "Installed copies",
            copies.isEmpty ? bundleURL.path : copies.map(\.path).joined(separator: " · ")
        )
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.sebmarste.zonal"
        )
        add(
            "running-instances",
            running.count <= 1 ? .ok : .error,
            "Running instances",
            running.count <= 1 ? "One Zonal process" : "\(running.count) Zonal processes are running"
        )

        findings.append(codeSignatureFinding(for: bundleURL))

        add(
            "login-item",
            (loginState == .enabled || loginState == .disabled) ? .ok : .warning,
            "Launch at login",
            loginState.detail
        )

        let snapshot = profileManager.currentSnapshot()
        add(
            "display-profile",
            profileManager.matchedProfile(for: snapshot) == nil ? .warning : .ok,
            "Display profile",
            profileManager.matchedProfile(for: snapshot)?.name
                ?? "No profile matches \(profileManager.setupName(for: snapshot))"
        )
        let otherManagers = runningWindowManagers()
        add(
            "other-window-managers",
            otherManagers.isEmpty ? .ok : .warning,
            "Other window managers",
            otherManagers.isEmpty ? "None detected" : otherManagers.joined(separator: ", ")
        )
        add(
            "outline",
            .ok,
            "Active outline",
            configuration.showActiveWindowOutline ? "Enabled" : "Disabled"
        )
        findings.append(ZonalDoctorPolicy().automationFinding(isRunning: automationRunning))
        return findings
    }

    private func installedZonalCopies() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let bundleIdentifier = Bundle.main.bundleIdentifier
        var found = Set<URL>()
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                if Bundle(url: entry)?.bundleIdentifier == bundleIdentifier {
                    found.insert(entry.resolvingSymlinksInPath())
                }
            }
        }
        found.insert(Bundle.main.bundleURL.resolvingSymlinksInPath())
        return found.sorted { $0.path < $1.path }
    }

    private func codeSignatureFinding(for bundleURL: URL) -> ZonalHealthFinding {
        var code: SecStaticCode?
        var information: CFDictionary?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code)
        guard created == errSecSuccess, let code else {
            return ZonalDoctorPolicy().signatureFinding(identifier: nil, team: nil, isValid: false)
        }
        let valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let values = information as? [String: Any] ?? [:]
        return ZonalDoctorPolicy().signatureFinding(
            identifier: values[kSecCodeInfoIdentifier as String] as? String,
            team: values[kSecCodeInfoTeamIdentifier as String] as? String,
            isValid: valid
        )
    }

    private func runningWindowManagers() -> [String] {
        let known = ["dinky", "aerospace", "yabai", "amethyst", "rectangle", "magnet", "loop"]
        return NSWorkspace.shared.runningApplications.compactMap(\.localizedName).filter { name in
            known.contains { name.localizedCaseInsensitiveContains($0) }
        }.sorted()
    }

}
