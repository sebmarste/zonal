import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import Zonal

final class ConfigurationTests: XCTestCase {
    func testAppCommandSearchUsesEveryTokenAndFullPath() {
        let command = AppCommandPath(indices: [2, 3], titles: ["File", "Export PDF…"])
        XCTAssertEqual(command.display, "File › Export PDF…")
        XCTAssertTrue(command.matches("pdf FILE"))
        XCTAssertFalse(command.matches("pdf edit"))
        XCTAssertNotEqual(command, AppCommandPath(indices: [2, 4], titles: command.titles))
        XCTAssertNotEqual(command, AppCommandPath(indices: command.indices, titles: ["File", "Delete"]))
    }

    func testAppCommandsShortcutRoundTripsWithoutZones() throws {
        let command = HotkeyCommand.openAppCommands
        XCTAssertEqual(try JSONDecoder().decode(HotkeyCommand.self, from: JSONEncoder().encode(command)), command)
        XCTAssertEqual(HotkeyCommandKind(command: command).command(zoneID: .center), command)
    }

    func testNativeAppMenuCapturesSearchButLeavesNavigationWithAppKit() throws {
        var snapshot = HotkeyCaptureSnapshot(appCommandsActive: true)
        for code in [53, 36, 123, 124, 125, 126] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
            XCTAssertFalse(snapshot.captures(event))
        }
        let typing = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let letters: [UniChar] = [97]
        typing.keyboardSetUnicodeString(stringLength: 1, unicodeString: letters)
        XCTAssertTrue(snapshot.captures(typing))
        snapshot.update(HotkeyCaptureSnapshot(appCommandsActive: true, appCommandsFiltering: true))
        let enter = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        XCTAssertTrue(snapshot.captures(enter))
        for code in [125, 126] {
            let arrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
            XCTAssertTrue(snapshot.captures(arrow))
        }
        snapshot.update(HotkeyCaptureSnapshot())
        XCTAssertFalse(snapshot.captures(typing))
    }

    func testMainStackClockDefaultsOffAndPersists() throws {
        var configuration = ZonalConfiguration.default
        let data = try JSONEncoder().encode(configuration.behavior)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "showMainStackClock")
        XCTAssertFalse(try JSONDecoder().decode(WindowBehaviorSettings.self,
            from: JSONSerialization.data(withJSONObject: json)).showMainStackClock)
        configuration.behavior.showMainStackClock = true
        XCTAssertEqual(try JSONDecoder().decode(ZonalConfiguration.self,
            from: JSONEncoder().encode(configuration)), configuration)
    }

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
        current.behavior.showMainStackClock = true
        XCTAssertFalse(ConfigurationRuntimePolicy().requiresWorkspaceReconciliation(previous: previous, current: current))
        current.profiles[0].tabAppearance = current.tabAppearance(for: current.profiles[0])
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

    func testExactAssignmentFitRejectsMissingAndInvalidIDs() {
        let id = UUID()
        XCTAssertEqual(LocalAutomationCommand(name: "fit-assignment", arguments: [id.uuidString]), .fitAssignment(id))
        for arguments in [[], ["main"], ["not-a-uuid"]] {
            XCTAssertEqual(LocalAutomationCommand(name: "fit-assignment", arguments: arguments),
                           .invalid("fit-assignment requires an assignment UUID"))
        }
    }

    func testAutomationCommandParsingIsDeterministic() {
        XCTAssertEqual(LocalAutomationCommand(name: "app-menus", arguments: []), .appMenus)
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

// Fake AX attributes: no Accessibility permission or live app is involved.
private final class CommandMenuFixture {
    let pid: pid_t = 910001
    let window = AXUIElementCreateApplication(910002)
    let bar = AXUIElementCreateApplication(910003)
    let file = AXUIElementCreateApplication(910004)
    let menu = AXUIElementCreateApplication(910005)
    let first = AXUIElementCreateApplication(910006)
    let second = AXUIElementCreateApplication(910007)
    var current = true
    var windowCurrent = true
    var focusedPIDs: [pid_t] = []
    var enabled = true
    var omitCategoryEnabled = false
    var menuReadDelay: TimeInterval = 0
    var replacement: AXUIElement?
    var presses: [AXUIElement] = []
    var outcome: AXError = .success
    var onPress: (() -> Void)?
    lazy var reader = AppCommandReader(pid: pid, window: window, attribute: { [unowned self] element, name in
        if name == kAXFocusedApplicationAttribute {
            let pid = self.focusedPIDs.isEmpty ? (self.current ? self.pid : 910099) : self.focusedPIDs.removeFirst()
            return AXUIElementCreateApplication(pid)
        }
        if name == kAXFocusedWindowAttribute { return self.windowCurrent ? self.window : AXUIElementCreateApplication(910098) }
        if name == kAXMenuBarAttribute { Thread.sleep(forTimeInterval: self.menuReadDelay); return self.bar }
        if name == kAXChildrenAttribute {
            if CFEqual(element, self.bar) { return [self.file] as CFArray }
            if CFEqual(element, self.file) { return [self.menu] as CFArray }
            if CFEqual(element, self.menu) { return [self.first, self.replacement ?? self.second] as CFArray }
            return [] as CFArray
        }
        if name == kAXRoleAttribute { return (CFEqual(element, self.menu) ? kAXMenuRole : kAXMenuItemRole) as CFString }
        if name == kAXTitleAttribute { return (CFEqual(element, self.file) ? "File" : "Duplicate") as CFString }
        if name == kAXEnabledAttribute {
            if self.omitCategoryEnabled && CFEqual(element, self.file) { return nil }
            return (self.enabled ? kCFBooleanTrue : kCFBooleanFalse)
        }
        if name == kAXMenuItemCmdCharAttribute { return "d" as CFString }
        if name == kAXMenuItemCmdModifiersAttribute { return NSNumber(value: 3) }
        return nil
    }, press: { [unowned self] element in self.presses.append(element); self.onPress?(); return self.outcome }, diagnosticWindowID: { _ in nil })
}

extension ConfigurationTests {
    func testAppCommandsPreserveDuplicateIdentityAndShortcutModifiers() throws {
        let fixture = CommandMenuFixture()
        let (roots, complete) = fixture.reader.read()
        XCTAssertTrue(complete)
        let commands = try XCTUnwrap(roots.first).children
        XCTAssertEqual(commands.count, 2)
        XCTAssertNotEqual(commands[0].path, commands[1].path)
        XCTAssertEqual(commands[1].shortcut, "⌥⇧⌘D")
        XCTAssertNil(fixture.reader.execute(commands[1]))
        XCTAssertEqual(fixture.presses.count, 1)
        XCTAssertTrue(CFEqual(fixture.presses[0], fixture.second))
    }

    func testAppCommandsRejectFocusChangesDisabledAndReplacedElements() throws {
        for failure in 0..<3 {
            let fixture = CommandMenuFixture()
            let command = try XCTUnwrap(fixture.reader.read().0.first?.children.last)
            if failure == 0 { fixture.current = false }
            if failure == 1 { fixture.enabled = false }
            if failure == 2 { fixture.replacement = AXUIElementCreateApplication(910008) }
            XCTAssertNotNil(fixture.reader.execute(command))
            XCTAssertTrue(fixture.presses.isEmpty)
        }
    }

    func testAppCommandTimeoutNeverRetries() throws {
        let fixture = CommandMenuFixture()
        let command = try XCTUnwrap(fixture.reader.read().0.first?.children.last)
        fixture.outcome = .cannotComplete
        XCTAssertNotNil(fixture.reader.execute(command))
        XCTAssertEqual(fixture.presses.count, 1)
    }
}

extension ConfigurationTests {
    func testAXCategoryWithoutEnabledAttributeStillExposesEnabledCommands() throws {
        let fixture = CommandMenuFixture()
        fixture.omitCategoryEnabled = true
        let roots = fixture.reader.read().0
        XCTAssertTrue(try XCTUnwrap(roots.first).enabled)
        XCTAssertTrue(try XCTUnwrap(roots.first?.children.first).enabled)
        XCTAssertNil(fixture.reader.execute(try XCTUnwrap(roots.first?.children.first)))
        XCTAssertEqual(fixture.presses.count, 1)
    }

    @MainActor
    func testNativeContextMenuReversesSectionsButNeverTheirContents() throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        root.addItem(ZoneTabMenuItem(title: "Move to Right") {})
        root.addItem(ZoneTabMenuItem(title: "Fit to Zone") {})
        root.addItem(ZoneTabMenuItem(title: "Close Window") {})
        let session = TabContextMenuSession(menu: root, reader: nil)
        session.setNodes(fixture.reader.read().0, complete: true)
        // A reader-less background-tab menu still provides all captured Zonal actions.
        XCTAssertNotNil(root.items.first?.view)
        XCTAssertEqual(root.items.filter { $0.isEnabled && $0.view == nil }.map(\.title), ["Move to Right", "Fit to Zone", "Close Window"])
        session.opensUpward = true; session.rebuild()
        XCTAssertNotNil(root.items.last?.view)
        XCTAssertEqual(root.items.filter { $0.isEnabled && $0.view == nil }.map(\.title), ["Move to Right", "Fit to Zone", "Close Window"])
        XCTAssertEqual(TabContextMenuPolicy.sections(opensUpward: false), [.search, .zonal, .app])
        XCTAssertEqual(TabContextMenuPolicy.sections(opensUpward: true), [.app, .zonal, .search])
        XCTAssertTrue(TabContextMenuPolicy.opensUpward(at: CGPoint(x: 100, y: 5), visibleFrame: CGRect(x: 0,y: 0,width: 800,height: 800), menuHeight: 300))
        XCTAssertFalse(TabContextMenuPolicy.opensUpward(at: CGPoint(x: 100, y: 795), visibleFrame: CGRect(x: 0,y: 0,width: 800,height: 800), menuHeight: 300))
    }

    @MainActor
    func testNativeContextMenuHasRealSubmenusAndSearchesFullPaths() async throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        var fits = 0
        root.addItem(ZoneTabMenuItem(title: "Fit to Zone") { fits += 1 })
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        let category = try XCTUnwrap(root.items.first { $0.submenu != nil })
        XCTAssertEqual(category.submenu?.items.count, 2)
        XCTAssertTrue(category.isEnabled)
        session.setQuery("file duplicate")
        let results = session.results.rows.compactMap(\.item).filter { $0.isEnabled && $0.action != nil }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.title == "File › Duplicate" && ($0 as? ZoneTabMenuItem)?.displayedShortcut == "⌥⇧⌘D" })
        session.setQuery("fit")
        XCTAssertEqual(session.results.selectedItem?.title, "Fit to Zone")
        session.setQuery("")
        XCTAssertNotNil(root.items.first { $0.submenu != nil })
        session.setQuery("fit")
        session.input(key: 36, text: nil, flags: [])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(fits, 1)
    }
}

extension ConfigurationTests {
    @MainActor
    func testUpwardNativeMenuKeepsAppCategoryOrder() throws {
        let fixture = CommandMenuFixture()
        var roots = fixture.reader.read().0
        var edit = try XCTUnwrap(roots.first)
        edit.path = AppCommandPath(indices: [1], titles: ["Edit"])
        roots.append(edit)
        let root = NSMenu()
        root.addItem(ZoneTabMenuItem(title: "Fit to Zone") {})
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.opensUpward = true
        session.setNodes(roots, complete: true)
        XCTAssertEqual(root.items.compactMap { $0.submenu?.title }, ["File", "Edit"])
        XCTAssertNotNil(root.items.last?.view)
    }
}


extension ConfigurationTests {
    @MainActor
    func testContextMenuSnapshotDoesNotMutateDuringTracking() throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        root.addItem(ZoneTabMenuItem(title: "Fit to Zone") {})
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        let original = root.items
        let height = root.size.height
        session.menuWillOpen(root)
        session.setNodes([], complete: false)
        XCTAssertEqual(root.items.map(ObjectIdentifier.init), original.map(ObjectIdentifier.init))
        XCTAssertEqual(root.size.height, height)
        XCTAssertEqual(root.items.compactMap { $0.submenu?.title }, ["File"])
        session.cancel()
    }

    @MainActor
    func testSearchHeightFitsResultsAndCapsLongListsInBothDirections() throws {
        let fixture = CommandMenuFixture()
        for upward in [false, true] {
            let root = NSMenu()
            for title in ["Fit to Zone", "Move Left", "Move Right", "Close Window"] {
                root.addItem(ZoneTabMenuItem(title: title) {})
            }
            let session = TabContextMenuSession(menu: root, reader: fixture.reader)
            session.opensUpward = upward
            session.setNodes(fixture.reader.read().0, complete: false)
            let height = root.size.height
            let anchor = upward ? root.items.last : root.items.first
            session.setQuery("file duplicate")
            XCTAssertEqual(session.results.frame.height, 48)
            XCTAssertLessThan(root.size.height, height)
            let twoResultsHeight = root.size.height
            for query in ["fit", "no such command"] {
                session.setQuery(query)
                XCTAssertEqual(session.results.frame.height, 24)
                XCTAssertLessThan(root.size.height, twoResultsHeight)
                XCTAssertTrue((upward ? root.items.last : root.items.first) === anchor)
            }
            session.maximumResultsHeight = 24
            session.setQuery("file duplicate")
            XCTAssertEqual(session.results.contentHeight, 48)
            XCTAssertEqual(session.results.frame.height, 24)
            XCTAssertNotNil(session.results.selectedItem)
            session.setQuery("")
            XCTAssertEqual(root.size.height, height, accuracy: 0.5)
            XCTAssertFalse(root.items.contains { $0.title.localizedCaseInsensitiveContains("dynamic") })
        }
    }

    @MainActor
    func testAppleCategoryIsExcludedWithoutDroppingOtherCategories() throws {
        let fixture = CommandMenuFixture()
        let file = try XCTUnwrap(fixture.reader.read().0.first)
        var apple = file
        apple.path = AppCommandPath(indices: [99], titles: ["Apple"])
        let root = NSMenu()
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.setNodes([file, apple], complete: false)
        XCTAssertEqual(root.items.compactMap { $0.submenu?.title }, ["File"])
        session.setQuery("duplicate")
        XCTAssertEqual(session.results.rows.filter(\.enabled).count, 2)
        XCTAssertTrue(session.results.rows.filter(\.enabled).allSatisfy { $0.title.hasPrefix("File ›") })
        apple.path.titles = ["\u{F8FF}"]
        XCTAssertTrue(apple.isAppleMenu)
        XCTAssertFalse(file.isAppleMenu)
    }

    @MainActor
    func testSearchSelectsEnabledResultAndReturnInvokesOnlyThatHandlerOnce() async throws {
        let root = NSMenu()
        var firstCalls = 0
        var secondCalls = 0
        let disabled = ZoneTabMenuItem(title: "Action unavailable") { XCTFail("Disabled action invoked") }
        disabled.isEnabled = false
        root.addItem(disabled)
        root.addItem(ZoneTabMenuItem(title: "Action first") { firstCalls += 1 })
        root.addItem(ZoneTabMenuItem(title: "Action second") { secondCalls += 1 })
        let session = TabContextMenuSession(menu: root, reader: nil)
        session.setQuery("Action")
        XCTAssertEqual(session.results.selectedItem?.title, "Action first")
        session.input(key: 125, text: nil, flags: [])
        XCTAssertEqual(session.results.selectedItem?.title, "Action second")
        session.input(key: 126, text: nil, flags: [])
        XCTAssertEqual(session.results.selectedItem?.title, "Action first")
        session.setQuery("no matching item")
        XCTAssertNil(session.results.selectedItem)
        session.input(key: 36, text: nil, flags: [])
        session.setQuery("Action")
        session.input(key: 125, text: nil, flags: [])
        session.input(key: 36, text: nil, flags: [])
        session.input(key: 36, text: nil, flags: [])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(firstCalls, 0)
        XCTAssertEqual(secondCalls, 1)
    }

    @MainActor
    func testMenuPreparationCompletesBeforeTrackingWithWholeSnapshot() async throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        let ready = expectation(description: "Prepared menu")
        session.prepare {
            XCTAssertFalse(session.isPreparing)
            XCTAssertFalse(session.isTracking)
            XCTAssertEqual(root.items.compactMap { $0.submenu?.title }, ["File"])
            XCTAssertEqual(root.items.first { $0.submenu != nil }?.submenu?.items.count, 2)
            ready.fulfill()
        }
        XCTAssertTrue(session.isPreparing)
        await fulfillment(of: [ready], timeout: 3)
    }
}


extension ConfigurationTests {
    @MainActor
    func testSearchReturnExecutesExactAppResultAfterMenuDismissal() async throws {
        let fixture = CommandMenuFixture()
        let pressed = expectation(description: "Exact app command pressed")
        fixture.onPress = { pressed.fulfill() }
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        session.setQuery("file duplicate")
        session.input(key: 125, text: nil, flags: [])
        session.input(key: 36, text: nil, flags: [])
        session.input(key: 36, text: nil, flags: [])
        await fulfillment(of: [pressed], timeout: 3)
        XCTAssertEqual(fixture.presses.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(fixture.presses.first), fixture.second))
    }

    @MainActor
    func testPreparationCannotPresentAfterContextChanges() async {
        let fixture = CommandMenuFixture()
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        let closed = expectation(description: "Changed context cancels preparation")
        session.canPresent = { false }
        session.onClose = { closed.fulfill() }
        session.prepare { XCTFail("Stale prepared menu presented") }
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertFalse(session.isPreparing)
        XCTAssertFalse(session.isTracking)
    }
}


extension ConfigurationTests {
    @MainActor
    func testDynamicSearchReopensFrozenMenuAtSameAnchorWithoutEndingSession() throws {
        let fixture = CommandMenuFixture()
        for upward in [false, true] {
            let root = NSMenu()
            for title in ["Fit to Zone", "Move Left", "Move Right", "Close Window"] {
                root.addItem(ZoneTabMenuItem(title: title) {})
            }
            let session = TabContextMenuSession(menu: root, reader: fixture.reader)
            var inventoryUpdates = 0
            session.onInventory = { _ in inventoryUpdates += 1 }
            session.setNodes(fixture.reader.read().0, complete: true)
            let point = CGPoint(x: 200, y: upward ? 5 : 795)
            var heights: [CGFloat] = []
            var closes = 0
            session.onClose = { closes += 1 }
            let queries: [String?] = ["file duplicate", "fit", "", nil]
            session.popUp = { [weak session] menu, anchor, actualPoint in
                guard let session else { XCTFail("Session lost"); return }
                XCTAssertEqual(actualPoint, point)
                XCTAssertEqual(session.opensUpward, upward)
                XCTAssertTrue(anchor === (upward ? menu.items.last : menu.items.first))
                heights.append(menu.size.height)
                session.menuWillOpen(menu)
                if let query = queries[heights.count - 1] {
                    let before = menu.items.map(ObjectIdentifier.init)
                    session.setQuery(query)
                    XCTAssertEqual(menu.items.map(ObjectIdentifier.init), before)
                }
                session.menuDidClose(menu)
            }
            session.present(at: point, visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800))
            XCTAssertEqual(heights.count, 4)
            XCTAssertLessThan(heights[1], heights[0])
            XCTAssertLessThan(heights[2], heights[1])
            XCTAssertEqual(heights[3], heights[0])
            XCTAssertEqual(inventoryUpdates, 1)
            XCTAssertEqual(closes, 1)
            XCTAssertTrue(fixture.presses.isEmpty)
        }
    }

    @MainActor
    func testQueryReopenStopsIfCapturedContextChanges() {
        let fixture = CommandMenuFixture()
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        var current = true
        var opens = 0
        var closes = 0
        session.canPresent = { current }
        session.onClose = { closes += 1 }
        session.popUp = { [weak session] menu, _, _ in
            guard let session else { return }
            opens += 1
            session.menuWillOpen(menu)
            session.setQuery("find")
            current = false
            session.menuDidClose(menu)
        }
        session.present(at: CGPoint(x: 100, y: 5), visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(session.isTracking)
        XCTAssertTrue(fixture.presses.isEmpty)
    }

    @MainActor
    func testCommandIconsSurviveSearchAndAppearInResultCells() throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        let fit = ZoneTabMenuItem(title: "Fit to Zone") {}
        fit.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        root.addItem(fit)
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        XCTAssertNotNil(root.items.first { $0.submenu != nil }?.image)
        XCTAssertTrue(try XCTUnwrap(root.items.first { $0.submenu != nil }?.submenu).items.allSatisfy { $0.image != nil })
        session.setQuery("file duplicate")
        let result = try XCTUnwrap(session.results.selectedItem)
        let cell = try XCTUnwrap(session.results.tableView(session.results.table, viewFor: nil, row: 0) as? NSTableCellView)
        XCTAssertNotNil(result.image)
        XCTAssertTrue(cell.imageView?.image === result.image)
        session.setQuery("fit")
        XCTAssertTrue(session.results.selectedItem === fit)
        XCTAssertTrue(session.results.selectedItem?.image === fit.image)
        XCTAssertEqual(AppCommandSymbol.name(path: .init(indices: [], titles: ["Edit", "Find…"]), isMenu: false), "magnifyingglass")
        XCTAssertNil(AppCommandSymbol.name(path: .init(indices: [], titles: ["File", "Unrecognized action"]), isMenu: false))
    }
}


extension ConfigurationTests {
    @MainActor
    func testFastQueryAndReturnUsesLatestResultsBeforeMenuReopens() async throws {
        let fixture = CommandMenuFixture()
        let pressed = expectation(description: "Latest search result executes")
        fixture.onPress = { pressed.fulfill() }
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        var opens = 0
        var closes = 0
        session.onClose = { closes += 1 }
        session.popUp = { [weak session] menu, _, _ in
            guard let session else { return }
            opens += 1
            session.menuWillOpen(menu)
            session.setQuery("does not match")
            session.setQuery("file duplicate")
            session.input(key: 125, text: nil, flags: [])
            session.input(key: 36, text: nil, flags: [])
            session.input(key: 36, text: nil, flags: [])
            session.menuDidClose(menu)
        }
        session.present(at: CGPoint(x: 100, y: 5), visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800))
        await fulfillment(of: [pressed], timeout: 3)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(fixture.presses.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(fixture.presses.first), fixture.second))
    }
}


extension ConfigurationTests {
    func testReadinessWaitAllowsMenuFocusButRejectsExternalAppOrSiblingWindow() {
        let fixture = CommandMenuFixture()
        let menuPID = ProcessInfo.processInfo.processIdentifier
        fixture.focusedPIDs = [menuPID, menuPID, fixture.pid]
        XCTAssertTrue(fixture.reader.waitForContext(transitionPID: menuPID))
        fixture.focusedPIDs = [menuPID, menuPID, fixture.pid]
        XCTAssertTrue(fixture.reader.waitForContext(transitionPID: 910095))
        XCTAssertTrue(fixture.presses.isEmpty)
        fixture.current = false
        XCTAssertFalse(fixture.reader.waitForContext(transitionPID: menuPID))
        fixture.current = true
        fixture.windowCurrent = false
        XCTAssertFalse(fixture.reader.waitForContext(transitionPID: menuPID))
        XCTAssertTrue(fixture.presses.isEmpty)
    }

    func testFocusPolicyAllowsOnlyExpectedOpeningTransitionAndOwnMenu() {
        XCTAssertTrue(AppCommandFocusPolicy.allowsApp(active: 20, target: 20, opening: 10, preparing: false, menuOwnsFocus: false))
        XCTAssertTrue(AppCommandFocusPolicy.allowsApp(active: 10, target: 20, opening: 10, preparing: true, menuOwnsFocus: false))
        XCTAssertFalse(AppCommandFocusPolicy.allowsApp(active: 10, target: 20, opening: 10, preparing: false, menuOwnsFocus: false))
        XCTAssertFalse(AppCommandFocusPolicy.allowsApp(active: 30, target: 20, opening: 10, preparing: true, menuOwnsFocus: false))
        XCTAssertTrue(AppCommandFocusPolicy.allowsApp(active: 30, target: 20, opening: 10, preparing: false, menuOwnsFocus: true))
        XCTAssertFalse(AppCommandFocusPolicy.allowsApp(active: nil, target: 20, opening: nil, preparing: true, menuOwnsFocus: false))
    }

    @MainActor
    func testMenuSearchControlsCannotRequestKeyboardOrPanelFocus() {
        let session = TabContextMenuSession(menu: NSMenu(), reader: nil)
        XCTAssertFalse(session.search.acceptsFirstResponder)
        XCTAssertFalse(session.search.needsPanelToBecomeKey)
        XCTAssertTrue(session.search.acceptsFirstMouse(for: nil))
        XCTAssertFalse(session.results.acceptsFirstResponder)
        XCTAssertFalse(session.results.needsPanelToBecomeKey)
        XCTAssertFalse(session.results.table.acceptsFirstResponder)
        XCTAssertFalse(session.results.table.needsPanelToBecomeKey)
        XCTAssertTrue(session.results.table.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testBackgroundMenuFocusesExactContextBeforeReadingCommands() async {
        let fixture = CommandMenuFixture()
        fixture.current = false
        fixture.windowCurrent = false
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        var focusRequests = 0
        session.focusBeforeRead = { completion in
            focusRequests += 1
            fixture.current = true
            fixture.windowCurrent = true
            completion()
        }
        let ready = expectation(description: "Verified focused menus")
        session.prepare {
            XCTAssertEqual(focusRequests, 1)
            XCTAssertEqual(session.menu.items.compactMap { $0.submenu?.title }, ["File"])
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(fixture.presses.isEmpty)
    }

    @MainActor
    func testUnconfirmedFocusNeverOpensMenuOrExecutesCommand() async {
        let fixture = CommandMenuFixture()
        fixture.current = false
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        let failed = expectation(description: "Focus failure reported")
        session.onPreparationFailure = { failed.fulfill() }
        session.prepare { XCTFail("Unverified context presented") }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(session.isPreparing)
        XCTAssertTrue(fixture.presses.isEmpty)
    }

    @MainActor
    func testCancelledNativeFocusCannotLeaveMenuPreparingForever() async {
        let fixture = CommandMenuFixture()
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        session.preparationTimeoutDuration = .milliseconds(20)
        session.focusBeforeRead = { _ in }
        var cancellations = 0
        session.cancelFocus = { cancellations += 1 }
        let failed = expectation(description: "Unfinished focus times out")
        session.onPreparationFailure = { failed.fulfill() }
        session.prepare { XCTFail("Unverified context presented") }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.isPreparing)
        XCTAssertTrue(fixture.presses.isEmpty)
    }
}

extension ConfigurationTests {
    @MainActor
    func testMenuIconsShareCanvasWithoutMutatingSourcesOrStretching() throws {
        let wide = NSImage(size: NSSize(width: 20, height: 10), flipped: false) { bounds in
            NSColor.red.setFill(); bounds.fill(); return true
        }
        let app = NSImage(size: NSSize(width: 1024, height: 1024))
        let symbol = try XCTUnwrap(NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil))
        let images = try [wide, app, symbol].map { try XCTUnwrap(TabMenuAppearance.icon($0)) }
        XCTAssertTrue(images.allSatisfy { $0.size == NSSize(width: 16, height: 16) })
        XCTAssertEqual(app.size, NSSize(width: 1024, height: 1024))
        XCTAssertEqual(wide.size, NSSize(width: 20, height: 10))
        XCTAssertEqual(images[2].isTemplate, symbol.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(images[0].tiffRepresentation)))
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent, 0.95)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 0)).alphaComponent, 0.01)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 1)).alphaComponent, 0.01)
    }

    @MainActor
    func testNativeMenuUsesSeparateShortcutMetadataAndUniformIconCanvases() throws {
        let fixture = CommandMenuFixture()
        let root = NSMenu()
        let fit = ZoneTabMenuItem(title: "Fit to Zone") {}
        fit.image = NSImage(size: NSSize(width: 20, height: 14))
        root.addItem(fit)
        let session = TabContextMenuSession(menu: root, reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        let category = try XCTUnwrap(root.items.first { $0.submenu != nil })
        XCTAssertEqual(category.image?.size, fit.image?.size)
        XCTAssertEqual(fit.image?.size, NSSize(width: 16, height: 16))
        let command = try XCTUnwrap(category.submenu?.items.first as? ZoneTabMenuItem)
        XCTAssertEqual(command.title, "Duplicate")
        XCTAssertEqual(command.keyEquivalent, "d")
        XCTAssertEqual(command.keyEquivalentModifierMask, [.option, .shift, .command])
        XCTAssertEqual(command.displayedShortcut, "⌥⇧⌘D")
        session.setQuery("file duplicate")
        XCTAssertEqual(session.results.rows.first?.title, "File › Duplicate")
        XCTAssertEqual(session.results.rows.first?.shortcut, "⌥⇧⌘D")
        XCTAssertEqual(session.results.selectedItem?.image?.size, fit.image?.size)
    }

    @MainActor
    func testSearchRowsAlignIconsTitlesAndShortcutRightEdgesAcrossWidths() throws {
        let fit = ZoneTabMenuItem(title: "Fit to Zone") {}
        let copy = ZoneTabMenuItem(title: "Edit › Copy a very long selection with a descriptive name") {}
        copy.displayedShortcut = "⌘C"
        let duplicate = ZoneTabMenuItem(title: "File › Duplicate") {}
        duplicate.displayedShortcut = "⌥⇧⌘D"
        let results = TabMenuResultsView()
        results.setRows([fit, copy, duplicate].map { .init(item: $0) })
        for width in [320.0, 480.0] {
            var cells: [TabMenuResultCell] = []
            for index in 0..<3 {
                let cell = try XCTUnwrap(results.tableView(results.table, viewFor: nil, row: index) as? TabMenuResultCell)
                let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
                cell.frame = host.bounds
                host.addSubview(cell)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.imageView?.frame, NSRect(x: 10, y: 4, width: 16, height: 16))
                let title = try XCTUnwrap(cell.textField)
                let titleRect = title.alignmentRect(forFrame: title.frame)
                let shortcutRect = cell.shortcut.alignmentRect(forFrame: cell.shortcut.frame)
                XCTAssertEqual(titleRect.minX, 34, accuracy: 0.5)
                XCTAssertEqual(shortcutRect.maxX, width - 20, accuracy: 0.5)
                XCTAssertEqual(cell.shortcut.alignment, .right)
                XCTAssertLessThanOrEqual(titleRect.maxX, shortcutRect.minX - 15.5)
                cells.append(cell)
            }
            XCTAssertEqual(cells[1].shortcut.frame.maxX, cells[2].shortcut.frame.maxX)
            XCTAssertEqual(cells[1].textField?.stringValue, copy.title)
            XCTAssertEqual(cells[2].shortcut.stringValue, "⌥⇧⌘D")
        }
    }

    func testShortcutMetadataUsesCarbonGlyphsAndExplicitModifierMasks() {
        XCTAssertEqual(AppCommandReader.shortcutModifiers(0), [.command])
        XCTAssertEqual(AppCommandReader.shortcutModifiers(13), [.control, .shift])
        XCTAssertEqual(AppCommandReader.shortcutKey(character: "D", glyph: 0).key, "d")
        XCTAssertEqual(AppCommandReader.shortcutKey(character: "", glyph: 100).key, "\u{F702}")
        XCTAssertEqual(AppCommandReader.glyph(2), "⇥")
        XCTAssertEqual(AppCommandReader.glyph(9), "Space")
        XCTAssertEqual(AppCommandReader.glyph(99), "⇪")
        XCTAssertEqual(AppCommandReader.glyph(107), "⇟")
        XCTAssertEqual(AppCommandReader.glyph(111), "F1")
        XCTAssertEqual(AppCommandReader.glyph(115), "F5")
        XCTAssertEqual(AppCommandReader.glyph(119), "F9")
        XCTAssertEqual(AppCommandReader.glyph(146), "F19")
        XCTAssertEqual(AppCommandReader.shortcutKey(character: "", glyph: 999).key, "")
    }
}


extension ConfigurationTests {
    @MainActor
    func testAppMenusHaveNoHoverTooltipsButKeepAccessiblePathsAndShortcuts() throws {
        let fixture = CommandMenuFixture()
        let menu = NSMenu()
        let session = TabContextMenuSession(menu: menu, reader: fixture.reader)
        session.setNodes(fixture.reader.read().0, complete: true)
        let category = try XCTUnwrap(menu.items.first { $0.submenu != nil })
        XCTAssertNil(category.toolTip)
        XCTAssertTrue(try XCTUnwrap(category.submenu).items.allSatisfy { $0.toolTip == nil })
        session.setQuery("file duplicate")
        let cell = try XCTUnwrap(session.results.tableView(session.results.table, viewFor: nil, row: 0))
        XCTAssertNil(cell.toolTip)
        XCTAssertTrue(cell.subviews.allSatisfy { $0.toolTip == nil })
        XCTAssertTrue(cell.subviews.compactMap { $0 as? NSTextField }.allSatisfy { !$0.allowsExpansionToolTips })
        XCTAssertEqual(cell.accessibilityLabel(), "File › Duplicate    ⌥⇧⌘D")
        XCTAssertFalse(session.results.tableView(session.results.table, shouldShowCellExpansionFor: nil, row: 0))
    }
}


extension ConfigurationTests {
    @MainActor
    func testConfirmedFocusDeadlineDoesNotCancelSlowFirstMenuDiscovery() async {
        let fixture = CommandMenuFixture()
        fixture.menuReadDelay = 0.15
        let session = TabContextMenuSession(menu: NSMenu(), reader: fixture.reader)
        session.preparationTimeoutDuration = .milliseconds(40)
        session.onPreparationFailure = { XCTFail("Confirmed focus mislabeled as a focus timeout during menu discovery") }
        let ready = expectation(description: "Cold menu discovery completes after focus deadline")
        session.prepare {
            XCTAssertFalse(session.isPreparing)
            XCTAssertEqual(session.menu.items.compactMap { $0.submenu?.title }, ["File"])
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 2)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(fixture.presses.isEmpty)
    }
}


extension ConfigurationTests {
    @MainActor
    func testCompactMenuViewportShowsWholeRowsAndLastRowWithoutClipping() {
        let results = TabMenuResultsView()
        let items = (0..<30).map { ZoneTabMenuItem(title: "Command \($0)") {} }
        var rows = items.map { TabMenuResultsView.Row(item: $0) }
        rows.insert(.init(item: nil), at: 5)
        results.setRows(rows)
        results.fit(maximumHeight: 167)
        results.layoutSubtreeIfNeeded()
        XCTAssertEqual(results.table.style, .plain)
        XCTAssertFalse(results.automaticallyAdjustsContentInsets)
        XCTAssertEqual(results.contentHeight, results.table.rect(ofRow: rows.count - 1).maxY)
        XCTAssertTrue(rows.indices.contains { abs(results.table.rect(ofRow: $0).maxY - results.contentSize.height) < 0.5 })
        XCTAssertTrue(results.table.visibleRect.contains(results.table.rect(ofRow: 0)))
        for _ in 0..<40 { results.move(1) }
        XCTAssertTrue(results.selectedItem === items.last)
        XCTAssertTrue(results.table.visibleRect.contains(results.table.rect(ofRow: rows.count - 1)))
        XCTAssertLessThanOrEqual(results.table.visibleRect.maxY, results.table.bounds.maxY + 0.5)
        results.setRows([.init(item: items[0])])
        results.fit(maximumHeight: 167)
        results.layoutSubtreeIfNeeded()
        XCTAssertEqual(results.frame.height, 24)
        XCTAssertEqual(results.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertTrue(results.table.visibleRect.contains(results.table.rect(ofRow: 0)))
    }

    @MainActor
    func testCompactSearchHeaderAndRowsKeepContentInsideBounds() throws {
        let fixture = CommandMenuFixture()
        for upward in [false, true] {
            let menu = NSMenu()
            menu.addItem(ZoneTabMenuItem(title: "Fit to Zone") {})
            let session = TabContextMenuSession(menu: menu, reader: fixture.reader)
            session.opensUpward = upward
            session.setNodes(fixture.reader.read().0, complete: true)
            let header = try XCTUnwrap(upward ? menu.items.last?.view : menu.items.first?.view)
            XCTAssertEqual(header.frame.height, 34)
            XCTAssertTrue(header.bounds.contains(session.search.frame))
            XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 2)
            session.setQuery("duplicate")
            XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
            let cell = try XCTUnwrap(session.results.tableView(session.results.table, viewFor: nil, row: 0) as? TabMenuResultCell)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            cell.frame = host.bounds; host.addSubview(cell); host.layoutSubtreeIfNeeded()
            for child in cell.subviews { XCTAssertTrue(cell.bounds.contains(child.frame)) }
            XCTAssertTrue(cell.shortcut.frame.maxX <= cell.bounds.maxX - 16)
        }
    }
}


extension ConfigurationTests {
    @MainActor
    func testNativeSpacingHasNoExtraInsetAndKeepsSearchSeparatorOutside() throws {
        let results = TabMenuResultsView()
        let items = (0..<20).map { ZoneTabMenuItem(title: "Command \($0)") {} }
        results.setRows(items.map { .init(item: $0) })
        results.fit(maximumHeight: 124)
        results.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(results.documentView)
        XCTAssertTrue(document === results.table)
        XCTAssertEqual(results.table.frame.minY, 0)
        XCTAssertEqual(results.contentView.bounds.minY, 0)
        for _ in 0..<20 { results.move(1) }
        XCTAssertGreaterThan(results.contentView.bounds.minY, 4)
        XCTAssertTrue(results.table.visibleRect.contains(results.table.rect(ofRow: 19)))
        results.setRows([.init(item: items[0])])
        results.fit(maximumHeight: 124)
        XCTAssertEqual(results.contentView.bounds.minY, 0)
        XCTAssertEqual(results.frame.height, 24)
        let fixture = CommandMenuFixture()
        for upward in [false, true] {
            let menu = NSMenu()
            let session = TabContextMenuSession(menu: menu, reader: fixture.reader)
            session.opensUpward = upward
            session.setNodes(fixture.reader.read().0, complete: true)
            session.setQuery("duplicate")
            XCTAssertEqual(menu.items.count, 3)
            XCTAssertTrue(menu.items[1].isSeparatorItem)
            XCTAssertTrue((upward ? menu.items.first : menu.items.last)?.view === session.results)
            XCTAssertTrue((upward ? menu.items.last : menu.items.first)?.view?.subviews.contains(session.search) == true)
        }
    }
}
