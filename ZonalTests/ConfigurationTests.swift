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
    var enabled = true
    var omitCategoryEnabled = false
    var replacement: AXUIElement?
    var presses: [AXUIElement] = []
    var outcome: AXError = .success
    var onPress: (() -> Void)?
    lazy var reader = AppCommandReader(pid: pid, window: window, attribute: { [unowned self] element, name in
        if name == kAXFocusedApplicationAttribute { return AXUIElementCreateApplication(self.current ? self.pid : 910099) }
        if name == kAXFocusedWindowAttribute { return self.window }
        if name == kAXMenuBarAttribute { return self.bar }
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
    }, press: { [unowned self] element in self.presses.append(element); self.onPress?(); return self.outcome })
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
        XCTAssertTrue(results.allSatisfy { $0.title.contains("File › Duplicate") && $0.title.contains("⌥⇧⌘D") })
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
    func testSearchPreservesMenuHeightAndOpeningAnchorInBothDirections() throws {
        let fixture = CommandMenuFixture()
        for upward in [false, true] {
            let root = NSMenu()
            root.addItem(ZoneTabMenuItem(title: "Fit to Zone") {})
            let session = TabContextMenuSession(menu: root, reader: fixture.reader)
            session.opensUpward = upward
            session.setNodes(fixture.reader.read().0, complete: false)
            let height = root.size.height
            let anchor = upward ? root.items.last : root.items.first
            for query in ["duplicate", "fit", "no such command", ""] {
                session.setQuery(query)
                XCTAssertEqual(root.size.height, height, accuracy: 0.5, "query=\(query) upward=\(upward)")
                XCTAssertTrue((upward ? root.items.last : root.items.first) === anchor)
            }
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
