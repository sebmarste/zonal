import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

final class ConfigurationTests: XCTestCase {
    func testOverlappingTabModesRoundTripAndDefaultWhenAbsent() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let defaults = ZonalConfiguration.default
        let data = try encoder.encode(defaults)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["overlappingZoneTabs"])
        XCTAssertEqual(try decoder.decode(ZonalConfiguration.self, from: data).overlappingZoneTabs ?? .zoneShortcuts,
                       .zoneShortcuts)
        for mode in OverlappingZoneTabs.allCases {
            var configuration = defaults
            configuration.overlappingZoneTabs = mode
            XCTAssertEqual(try decoder.decode(ZonalConfiguration.self, from: encoder.encode(configuration)), configuration)
            XCTAssertTrue(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: defaults, current: configuration))
        }
        var invalid = json
        invalid["overlappingZoneTabs"] = "unknown"
        XCTAssertThrowsError(try decoder.decode(ZonalConfiguration.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testTerminologyRenamesPreserveSerializedSettings() throws {
        XCTAssertEqual(try JSONDecoder().decode(ZoneWindowPresentation.self,
            from: Data("\"accordion\"".utf8)), .peekStack)
        XCTAssertEqual(String(data: try JSONEncoder().encode(ZoneWindowPresentation.peekStack),
                              encoding: .utf8), "\"accordion\"")
        var behavior = WindowBehaviorSettings()
        behavior.showSwitcherShortcutGuide = false
        let data = try JSONEncoder().encode(behavior)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["showSwitcherHotkeys"] as? Bool, false)
        XCTAssertNil(json["showSwitcherShortcutGuide"])
        XCTAssertFalse(try JSONDecoder().decode(WindowBehaviorSettings.self, from: data).showSwitcherShortcutGuide)
        XCTAssertEqual(RestoreTrigger.manual.actionTitle, "Restore Window Positions")
        XCTAssertEqual(RestoreTrigger.manual.logLabel, "manual")
    }

    func testSwitcherGuideUsesUsableTabBindingsAndFallsBackToTab() {
        var bindings = HotkeyBinding.defaults
        func keys(_ mode: SwitcherMode = .allWindows, native: Bool = false) -> [String] {
            HotkeyBinding.nextWindowShortcutKeys(mode: mode, bindings: bindings, useNativeCommandTab: native)
        }
        XCTAssertEqual(keys(), ["⌘", "Tab"])
        XCTAssertEqual(keys(.byZone), ["⌥", "Tab"])
        XCTAssertEqual(keys(native: true), ["Tab"])
        let index = bindings.firstIndex { $0.command == .openGlobalSwitcher }!
        bindings[index].keyCode = 49
        bindings[index].keyLabel = "Space"
        XCTAssertEqual(keys(), ["Tab"])
        bindings[index].keyCode = 48
        bindings[index].modifiers = .controlOption
        XCTAssertEqual(keys(), ["⌃", "⌥", "Tab"])
        bindings[index].modifiers.shift = true
        XCTAssertEqual(keys(), ["Tab"])
        bindings[index].isEnabled = false
        XCTAssertEqual(keys(), ["Tab"])
    }

    func testDevelopmentStorageAndAutomationAreIsolatedButOwnershipIsShared() {
        let release = ZonalStoragePaths.supportDirectory(bundleIdentifier: "com.sebmarste.zonal")
        let development = ZonalStoragePaths.supportDirectory(bundleIdentifier: "com.sebmarste.zonal.dev")
        XCTAssertNotEqual(release, development)
        XCTAssertEqual(development.lastPathComponent, "Zonal Development")
        XCTAssertEqual(ZonalStoragePaths.supportDirectory(bundleIdentifier: nil), development)
        XCTAssertEqual(ZonalStoragePaths.instanceLock, release.appendingPathComponent("instance.lock"))
        XCTAssertEqual(LocalAutomationProtocol.directoryURL, ZonalStoragePaths.current.appendingPathComponent("Automation", isDirectory: true))
        XCTAssertEqual(PersistenceStore().supportDirectory, ZonalStoragePaths.current)
    }



    func testCosmeticConfigurationChangesDoNotReconcileWindows() {
        let previous = ZonalConfiguration.default
        var current = previous
        current.theme = .dark
        current.profiles[0].name = "New name"
        current.profiles[0].zones[0].name = "New zone name"
        current.hotkeys = []
        current.behavior.feedbackMode = .errorsOnly
        XCTAssertFalse(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: previous, current: current))
    }

    func testWorkspaceConfigurationChangesRequireReconciliation() {
        let previous = ZonalConfiguration.default
        let policy = ConfigurationRuntimePolicy()
        XCTAssertTrue(policy.requiresWorkspaceReconciliation(previous: nil, current: previous))
        var current = previous
        current.profiles[0].zones[0].frame = NormalizedFrame(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertTrue(policy.requiresWorkspaceReconciliation(previous: previous, current: current))
        current = previous
        current.excludedBundleIdentifiers = ["com.example.App"]
        XCTAssertTrue(policy.requiresWorkspaceReconciliation(previous: previous, current: current))
        current = previous
        current.windowDefaultZoneRules = [WindowDefaultZoneRule(bundleIdentifier: "com.example.App", zoneID: .main)]
        XCTAssertTrue(policy.requiresWorkspaceReconciliation(previous: previous, current: current))
        current = previous
        current.activeProfileID = nil
        XCTAssertTrue(policy.requiresWorkspaceReconciliation(previous: previous, current: current))
    }

    func testLaunchAtLoginStatesDistinguishRegistrationFromApproval() {
        XCTAssertFalse(LaunchAtLoginState.disabled.isRequested)
        XCTAssertTrue(LaunchAtLoginState.enabled.isRequested)
        XCTAssertTrue(LaunchAtLoginState.requiresApproval.isRequested)
        XCTAssertFalse(LaunchAtLoginState.unavailable.isRequested)

        XCTAssertTrue(LaunchAtLoginState.requiresApproval.detail.contains("System Settings"))
        XCTAssertTrue(LaunchAtLoginState.unavailable.detail.contains("unavailable"))
    }

    func testProfileManagerUsesInjectedDisplayProvider() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = DisplaySnapshot(displays: [
            DisplaySnapshot.Display(
                id: 99,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                visibleFrame: CGRect(x: 0, y: 24, width: 800, height: 576),
                scale: 2,
                persistentID: "fixture-display"
            )
        ])
        let manager = ProfileManager(
            store: PersistenceStore(supportDirectory: directory),
            displayProvider: FixedDisplayProvider(snapshot: snapshot)
        )

        XCTAssertEqual(manager.currentSnapshot(), snapshot)
    }

    func testAutomationCommandParsingIsDeterministic() {
        let assignmentID = UUID()

        XCTAssertEqual(
            LocalAutomationCommand(name: "focus-assignment", arguments: [assignmentID.uuidString]),
            .focusAssignment(assignmentID)
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "move-focused", arguments: ["left"]),
            .moveFocused("left")
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "move-focused-relative", arguments: ["right"]),
            .moveFocusedRelative(.right)
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "focus-zone", arguments: ["main"]),
            .focusZone("main")
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "move-focused-relative", arguments: ["diagonal"]),
            .invalid("move-focused-relative requires left, right, up, or down")
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "apply-profile", arguments: []),
            .invalid("apply-profile requires a profile ID")
        )
        XCTAssertEqual(
            LocalAutomationCommand(name: "not-a-command", arguments: []),
            .unknown
        )
        XCTAssertEqual(LocalAutomationCommand(name: "zones", arguments: []), .read(.zones))
        XCTAssertEqual(LocalAutomationCommand(name: "debug-state", arguments: []), .read(.debugState))
        XCTAssertEqual(LocalAutomationCommand(name: "doctor", arguments: []), .doctor)
        XCTAssertEqual(LocalAutomationCommand(name: "switcher-metrics", arguments: []), .switcherMetrics)
        XCTAssertEqual(
            LocalAutomationCommand(name: "reset-switcher-metrics", arguments: []),
            .resetSwitcherMetrics
        )
    }

    func testAutomationZoneReferencesPreferIDsAndRequireUniqueNames() {
        let zones = [
            Zone(id: "writing", name: "Focus", frame: .full),
            Zone(id: "calls", name: "Focus", frame: .full),
            Zone(id: "focus", name: "Résumé", frame: .full),
        ]
        let resolver = ZoneReferenceResolver()

        XCTAssertEqual(resolver.resolve("focus", in: zones), .resolved("focus"))
        XCTAssertEqual(resolver.resolve("resume", in: zones), .resolved("focus"))
        XCTAssertEqual(resolver.resolve("FOCUS", in: zones), .ambiguous(["writing", "calls"]))
        XCTAssertEqual(resolver.resolve("missing", in: zones), .notFound)
    }

    func testAutomationResponseUsesVersionedCommandSpecificEnvelope() throws {
        let response = LocalAutomationResponse(
            apiVersion: 2,
            requestID: "request-1",
            command: "move-focused",
            ok: true,
            message: "Focused window move accepted",
            result: LocalAutomationResult(
                state: .accepted,
                zone: LocalAutomationZoneReference(id: "writing", name: "Writing")
            ),
            error: nil
        )

        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["requestId"] as? String, "request-1")
        XCTAssertNil(object["windows"])
        XCTAssertEqual(try JSONDecoder().decode(LocalAutomationResponse.self, from: data), response)
    }

    func testConfigurationEditorRepairsSharedZonesAndObsoleteHotkeys() {
        let first = DisplayProfile(
            id: "first",
            name: "First",
            mainZoneID: .left,
            zones: [Zone(id: .left, name: "Left", frame: .full)]
        )
        let second = DisplayProfile(
            id: "second",
            name: "Second",
            mainZoneID: .right,
            zones: [Zone(id: .right, name: "Right", frame: .full)]
        )
        let input = ZonalConfiguration(
            schemaVersion: 5,
            activeProfileID: "missing",
            profiles: [first, second],
            hotkeys: [
                HotkeyBinding(command: .restore, keyCode: 1, keyLabel: "S", modifiers: .controlOption),
                HotkeyBinding(command: .openGlobalSwitcher, keyCode: 2, keyLabel: "D", modifiers: .controlOption)
            ]
        )

        let result = ConfigurationEditor().sanitized(input)

        XCTAssertEqual(Set(result.profiles[0].zones.map(\.id)), [.left, .right])
        XCTAssertEqual(Set(result.profiles[1].zones.map(\.id)), [.left, .right])
        XCTAssertEqual(result.activeProfileID, "first")
        XCTAssertFalse(result.hotkeys.contains { if case .restore = $0.command { return true }; return false })
        XCTAssertTrue(result.hotkeys.contains { if case .openGlobalSwitcher = $0.command { return true }; return false })

    }

    func testOutlineCoordinatesConvertFromAccessibilityToAppKit() {
        let converted = WindowOutlineCoordinatePolicy().appKitFrame(
            for: CGRect(x: 20, y: 100, width: 400, height: 300),
            mainScreenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(converted, CGRect(x: 20, y: 500, width: 400, height: 300))
    }

    func testExplicitNoOpProfileApplySaysItIsAlreadyCurrent() {
        let content = RestoreToastPolicy().content(
            for: .profileApply,
            profileName: "Ultrawide",
            summary: RestoreRunSummary(moved: 0, unchanged: 3, skipped: 0)
        )

        XCTAssertEqual(content?.title, "Ultrawide")
        XCTAssertEqual(content?.detail, "Already up to date")
        XCTAssertNil(content?.actionTitle)
    }

    func testEmptySelectedZoneNeverBorrowsAWindowFromAnotherZone() {
        let leftItem = switcherItem(assignmentID: UUID(), windowID: 10, zoneID: .left)
        let emptyZone = ZoneID(rawValue: "empty")
        let zones = [
            SwitcherZone(id: .left, name: "Left", frame: .full, items: [leftItem]),
            SwitcherZone(id: emptyZone, name: "Empty", frame: .full, items: [])
        ]
        let recovery = SwitcherSelectionRecovery()

        XCTAssertNil(
            recovery.assignmentID(
                current: nil,
                mode: .byZone,
                zones: zones,
                selectedZoneID: emptyZone
            )
        )
        XCTAssertEqual(
            recovery.assignmentID(
                current: nil,
                mode: .allWindows,
                zones: zones,
                selectedZoneID: emptyZone
            ),
            leftItem.assignmentID
        )
    }

    func testRepeatedGlobalSwitchTogglesBetweenTheTwoMostRecentWindows() {
        let chatGPT = UUID()
        let arc = UUID()
        let older = UUID()
        var reducer = WindowHistoryReducer(
            state: ZoneStackState(globalRecency: [chatGPT, arc, older])
        )
        let order = SwitcherMRUOrder()
        let selection = SwitcherSelectionPolicy()

        let fromChatGPT = order.orderedAssignmentIDs(
            available: [older, arc, chatGPT],
            current: chatGPT,
            history: reducer.state.globalRecency
        )
        XCTAssertEqual(fromChatGPT, [chatGPT, arc, older])
        XCTAssertEqual(selection.initialAssignmentID(in: fromChatGPT), arc)

        reducer.recordFocus(assignmentID: arc, zoneID: .main)
        let fromArc = order.orderedAssignmentIDs(
            available: [older, arc, chatGPT],
            current: arc,
            history: reducer.state.globalRecency
        )
        XCTAssertEqual(fromArc, [arc, chatGPT, older])
        XCTAssertEqual(selection.initialAssignmentID(in: fromArc), chatGPT)
    }

    func testDefaultConfigurationStartsWithMainProfileAndMainZone() {
        let configuration = ZonalConfiguration.default

        XCTAssertEqual(configuration.activeProfileID, "main")
        XCTAssertEqual(configuration.profiles.first?.id, "main")
        XCTAssertEqual(configuration.profiles.first?.mainZoneID, .main)
        XCTAssertEqual(configuration.profiles.first?.zones.first?.frame, .full)
    }

    func testConfigurationRoundTripsAsJSON() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()

        var configuration = store.loadConfiguration()
        configuration.profiles[0].id = "ultrawide"
        configuration.activeProfileID = "ultrawide"
        store.saveConfiguration(configuration)

        XCTAssertEqual(store.loadConfiguration(forceReload: true).activeProfileID, "ultrawide")
        XCTAssertEqual(store.configURL.lastPathComponent, "zonal-config.json")
    }



    func testExtendedMenuBarModeRoundTrips() throws {
        var configuration = ZonalConfiguration.default
        configuration.menuBarMode = .extended

        let decoded = try JSONDecoder().decode(
            ZonalConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )

        XCTAssertEqual(decoded.menuBarMode, .extended)
    }

    func testHotZoneResolverUsesSmallTopBiasedPointerTriggerArea() {
        let resolver = HotZoneResolver()
        let zones = [
            ZoneFrame(zoneID: .left, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
            ZoneFrame(zoneID: .right, frame: CGRect(x: 200, y: 0, width: 200, height: 200))
        ]
        let rightTarget = resolver.dropTargets(for: zones).first { $0.zoneID == .right }?.frame ?? .null

        XCTAssertEqual(
            resolver.targetZone(for: rightTarget.center, zones: zones),
            .right
        )
        XCTAssertNil(
            resolver.targetZone(for: CGPoint(x: 250, y: 180), zones: zones)
        )
    }

    func testZoneEditorTargetsCanUseSymmetricTopPadding() {
        let resolver = HotZoneResolver(topOffset: 16, edgePadding: 16)
        let zone = ZoneFrame(
            zoneID: .main,
            frame: CGRect(x: 10, y: 20, width: 500, height: 300)
        )

        let target = resolver.dropTargets(for: [zone])[0].frame

        XCTAssertEqual(target.minY, zone.frame.minY + 16)
    }

    func testConfiguredZoneNameWinsOverRawIdentifierEverywhere() {
        let zones = [
            Zone(id: .center, name: "Writing", frame: .full)
        ]

        XCTAssertEqual(
            ZoneNameResolver().name(for: .center, in: zones),
            "Writing"
        )
        XCTAssertEqual(
            ZoneNameResolver().name(for: ZoneID(rawValue: "review_queue"), in: zones),
            "Review Queue"
        )
    }

    func testDisplaySnapshotFindsDisplayContainingPoint() {
        let displays = [
            DisplaySnapshot.Display(
                id: 1,
                frame: CGRect(x: -400, y: 0, width: 400, height: 300),
                visibleFrame: CGRect(x: -400, y: 0, width: 400, height: 280),
                scale: 2
            ),
            DisplaySnapshot.Display(
                id: 2,
                frame: CGRect(x: 0, y: 0, width: 500, height: 300),
                visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 280),
                scale: 2
            )
        ]
        let snapshot = DisplaySnapshot(displays: displays)

        XCTAssertEqual(snapshot.display(containing: CGPoint(x: -100, y: 120))?.id, 1)
        XCTAssertEqual(snapshot.display(containing: CGPoint(x: 250, y: 120))?.id, 2)
        XCTAssertNil(snapshot.display(containing: CGPoint(x: 600, y: 120)))
    }

    func testProfileManagerRequiresCapturedDisplaySetup() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let manager = ProfileManager(store: store)
        let snapshot = DisplaySnapshot(displays: [
            DisplaySnapshot.Display(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: CGRect(x: 0, y: 24, width: 1512, height: 958),
                scale: 2,
                persistentID: "built-in",
                name: "Built-in",
                rotation: 0,
                isBuiltIn: true
            )
        ])

        XCTAssertNil(manager.matchedProfile(for: snapshot))

        var configuration = store.loadConfiguration()
        configuration.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        configuration.profiles[0].displayRoles = manager.roles(for: snapshot)
        store.saveConfiguration(configuration)

        XCTAssertEqual(manager.matchedProfile(for: snapshot)?.id, configuration.profiles[0].id)
    }

    func testProfileManagerPrefersActiveProfileWhenSetupBindingsOverlap() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let manager = ProfileManager(store: store)
        let display = DisplaySnapshot.Display(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1056),
            scale: 2,
            persistentID: "shared-display",
            name: "Display",
            rotation: 0,
            isBuiltIn: false
        )
        let snapshot = DisplaySnapshot(displays: [display])
        let binding = manager.setupBinding(for: snapshot)
        let roles = manager.roles(for: snapshot)
        let first = DisplayProfile(
            id: "first",
            name: "First",
            mainZoneID: .main,
            setupBindings: [binding],
            displayRoles: roles,
            zones: [Zone(id: .main, name: "Main", frame: .full, displayRoleID: .workspace)]
        )
        let active = DisplayProfile(
            id: "active",
            name: "Active",
            mainZoneID: .main,
            setupBindings: [binding],
            displayRoles: roles,
            zones: [Zone(id: .main, name: "Main", frame: .full, displayRoleID: .workspace)]
        )
        var configuration = store.loadConfiguration()
        configuration.profiles = [first, active]
        configuration.activeProfileID = active.id
        store.saveConfiguration(configuration)

        let before = try Data(contentsOf: store.configURL)
        XCTAssertEqual(manager.matchedProfile(for: snapshot)?.id, active.id)
        XCTAssertEqual(manager.matchingProfiles(for: snapshot).map(\.id), [first.id, active.id])
        XCTAssertEqual(try Data(contentsOf: store.configURL), before)
        let laptop = DisplaySnapshot(displays: [.init(id: 2,
            frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
            visibleFrame: CGRect(x: 0, y: 30, width: 1800, height: 1139), scale: 2,
            persistentID: "laptop", isBuiltIn: true)])
        var laptopProfile = first
        laptopProfile.id = "laptop"
        laptopProfile.setupBindings = [manager.setupBinding(for: laptop)]
        configuration.profiles.append(laptopProfile)
        configuration.activeProfileID = laptopProfile.id
        store.saveConfiguration(configuration)
        XCTAssertEqual(manager.matchingProfiles(for: snapshot).map(\.id), [first.id, active.id])
        XCTAssertEqual(manager.matchedProfile(for: snapshot)?.id, first.id,
                       "Selection reflects the actual matching profile, not a last-applied laptop profile")
        XCTAssertEqual(manager.matchingProfiles(for: laptop).map(\.id), [laptopProfile.id])
        XCTAssertTrue(manager.matchingProfiles(for: DisplaySnapshot(displays: [])).isEmpty)
    }

    @MainActor
    func testStatusMenuListsMatchingProfilesWithCheckedSelectionAndStableIDs() throws {
        var snapshot = StatusMenuSnapshot(accessibilityTrusted: true, inputMonitoringGranted: true,
            keyboardCaptureAvailable: true, trackingActive: true, displaySetupName: "Ultrawide",
            matchedProfileName: "Layout", matchingProfiles: [
                .init(id: "three-way", name: "Layout", isSelected: true),
                .init(id: "halves", name: "Layout", isSelected: false)
            ])
        let controller = StatusItemController()
        let menu = controller.makeExtendedMenu(snapshot: snapshot)
        let profiles = menu.items.filter { $0.representedObject is String }
        XCTAssertEqual(profiles.map { $0.representedObject as? String }, ["three-way", "halves"])
        XCTAssertEqual(profiles.map(\.state), [.on, .off])
        XCTAssertTrue(profiles.allSatisfy { $0.target === controller && $0.action != nil && $0.keyEquivalent.isEmpty })
        XCTAssertEqual(profiles.map(\.title), ["Layout", "Layout"], "Duplicate names must still select by ID")
        let previous = snapshot
        snapshot.matchingProfiles[0].isSelected = false
        snapshot.matchingProfiles[1].isSelected = true
        XCTAssertNotEqual(snapshot, previous, "The menu must refresh even when profile names are identical")
        let updated = controller.makeExtendedMenu(snapshot: snapshot)
        XCTAssertEqual(updated.items.filter { $0.representedObject is String }.map(\.state), [.off, .on])
        snapshot.matchingProfiles = []
        let unmatched = controller.makeExtendedMenu(snapshot: snapshot)
        XCTAssertTrue(unmatched.items.filter { $0.representedObject is String }.isEmpty)
        let placeholder = try XCTUnwrap(unmatched.items.first { $0.title == "No matching profiles" })
        XCTAssertFalse(placeholder.isEnabled)
    }

    func testProfileManagerNeverRoutesAnUnresolvedRoleToThePrimaryDisplay() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manager = ProfileManager(store: PersistenceStore(supportDirectory: directory))
        let primary = DisplaySnapshot.Display(
            id: 1,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 24, width: 1512, height: 958),
            scale: 2,
            persistentID: "built-in",
            name: "Built-in",
            rotation: 0,
            isBuiltIn: true
        )
        let snapshot = DisplaySnapshot(displays: [primary])
        let unresolvedRole = DisplayRole(
            id: .workspace,
            name: "External",
            descriptor: DisplayDescriptor(
                persistentID: "missing-external",
                name: "External",
                width: 1512,
                height: 982,
                scale: 1,
                rotation: 0,
                isBuiltIn: false
            )
        )
        let profile = DisplayProfile(
            id: "external",
            name: "External",
            mainZoneID: .main,
            displayRoles: [unresolvedRole],
            zones: [Zone(id: .main, name: "Main", frame: .full, displayRoleID: .workspace)]
        )

        XCTAssertNil(manager.display(for: .workspace, profile: profile, snapshot: snapshot))
        XCTAssertNil(manager.display(for: "missing-role", profile: profile, snapshot: snapshot))

        let unboundProfile = DisplayProfile(
            id: "unbound",
            name: "Unbound",
            mainZoneID: .main,
            zones: [Zone(id: .main, name: "Main", frame: .full)]
        )
        XCTAssertEqual(manager.display(for: nil, profile: unboundProfile, snapshot: snapshot), primary)
    }



    func testThemesRoundTripAndMapToAppKitAppearances() throws {
        for theme in AppTheme.allCases {
            var configuration = ZonalConfiguration.default
            configuration.theme = theme

            let decoded = try JSONDecoder().decode(
                ZonalConfiguration.self,
                from: JSONEncoder().encode(configuration)
            )

            XCTAssertEqual(decoded.theme, theme)
        }
        XCTAssertEqual(AppTheme.light.appearanceName, .aqua)
        XCTAssertEqual(AppTheme.dark.appearanceName, .darkAqua)
        XCTAssertNil(AppTheme.followSystem.appearanceName)
    }

    func testConfigurationEditorSanitizesWindowRulesAndExclusions() {
        var configuration = ZonalConfiguration.default
        configuration.excludedBundleIdentifiers = ["com.example.Editor", "", "com.example.Editor"]
        configuration.windowDefaultZoneRules = [
            WindowDefaultZoneRule(bundleIdentifier: "com.example.Editor", zoneID: .main),
            WindowDefaultZoneRule(bundleIdentifier: "com.example.Editor", zoneID: .left),
            WindowDefaultZoneRule(bundleIdentifier: "com.example.Invalid", zoneID: .left),
            WindowDefaultZoneRule(bundleIdentifier: "", zoneID: .main)
        ]

        let result = ConfigurationEditor().sanitized(configuration)

        XCTAssertEqual(result.schemaVersion, 5)
        XCTAssertEqual(result.excludedBundleIdentifiers, ["com.example.Editor"])
        XCTAssertEqual(
            result.windowDefaultZoneRules,
            [WindowDefaultZoneRule(bundleIdentifier: "com.example.Editor", zoneID: .main)]
        )
    }


}
