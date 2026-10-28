import XCTest
@testable import Zonal

final class PersistenceStoreTests: XCTestCase {
    func testSwitcherHotkeysDefaultAndPersistedDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let baseline = store.loadConfiguration()
        XCTAssertTrue(baseline.behavior.showSwitcherShortcutGuide)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline)) as? [String: Any])
        var behavior = try XCTUnwrap(json["behavior"] as? [String: Any])
        behavior.removeValue(forKey: "showSwitcherHotkeys")
        json["behavior"] = behavior
        let decoded = try JSONDecoder().decode(ZonalConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.behavior.showSwitcherShortcutGuide)
        var draft = baseline
        draft.behavior.showSwitcherShortcutGuide = false
        var external = baseline
        external.theme = .dark
        XCTAssertTrue(store.saveConfiguration(external))
        XCTAssertTrue(store.saveConfiguration(store.mergedConfiguration(draft: draft, baseline: baseline)))
        let reopened = store.loadConfiguration(forceReload: true)
        XCTAssertFalse(reopened.behavior.showSwitcherShortcutGuide)
        XCTAssertEqual(reopened.theme, .dark)
    }


    func testInvalidAndUnsupportedConfigurationIsPreservedAndBlocksAllWrites() throws {
        for problem in ["duplicate-profile", "duplicate-zone", "duplicate-role", "future", "old", "truncated"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PersistenceStore(supportDirectory: directory)
            store.bootstrap()
            var config = store.loadConfiguration()
            switch problem {
            case "duplicate-profile": config.profiles.append(config.profiles[0])
            case "duplicate-zone": config.profiles[0].zones.append(config.profiles[0].zones[0])
            case "duplicate-role":
                let roles = ProfileManager(store: store).roles(for: DisplaySnapshot(displays: [.init(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1)]))
                config.profiles[0].displayRoles = roles + roles
            case "future": config.schemaVersion = 999
            case "old": config.schemaVersion = 4
            default: break
            }
            let bytes = problem == "truncated" ? Data("{".utf8) : try JSONEncoder().encode(config)
            try bytes.write(to: store.configURL)
            let workspace = try Data(contentsOf: store.workspaceURL)
            let reopened = PersistenceStore(supportDirectory: directory)
            reopened.bootstrap()
            XCTAssertNotNil(reopened.readOnlyReason, problem)
            XCTAssertFalse(reopened.saveConfiguration(.default), problem)
            XCTAssertFalse(reopened.updateWorkspace { $0.assignments = [] }, problem)
            XCTAssertFalse(reopened.saveUndoJournal([]), problem)
            XCTAssertEqual(try Data(contentsOf: store.configURL), bytes, problem)
            XCTAssertEqual(try Data(contentsOf: store.workspaceURL), workspace, problem)
        }
    }

    func testDuplicateAssignmentsAreRejectedBeforeRuntimeProjection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let assignment = WindowAssignment(id: UUID(), identity: WindowIdentity(bundleIdentifier: "example", processIdentifier: 1, cgWindowID: 1, axRole: "AXWindow", axSubrole: "AXStandardWindow", observedOrder: 0), zoneID: .main, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(PersistenceStore.WorkspaceArchive(schemaVersion: 3, assignments: [assignment, assignment], history: .empty))
        try bytes.write(to: store.workspaceURL)
        let reopened = PersistenceStore(supportDirectory: directory)
        reopened.bootstrap()
        XCTAssertNotNil(reopened.readOnlyReason)
        XCTAssertTrue(reopened.loadAssignments().isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testBasicDiagnosticsContainOnlyStatusAndCounts() {
        let report = SupportReport.diagnostics(version: "1.0", build: "10", system: "macOS test",
            accessibility: true, inputMonitoring: false, keyboardCapture: false, tracking: true,
            displayCount: 2, profileCount: 3, zoneCount: 4, windowCount: 5,
            restoreCounts: [.init(moved: 1, unchanged: 2, skipped: 3, failed: 4)])
        XCTAssertTrue(report.contains("Displays: 2, profiles: 3, zones: 4, windows: 5"))
        XCTAssertTrue(report.contains("moved=1 unchanged=2 skipped=3 failed=4"))
        XCTAssertFalse(report.contains(NSHomeDirectory()))
        XCTAssertFalse(report.contains("socket"))
        XCTAssertFalse(report.contains("profileName"))
    }

    func testBugReportURLPreservesEditedTextAndFallsBackForLongReports() throws {
        let report = SupportReport.draft(diagnostics: "macOS: test & # ? ü")
        let url = try XCTUnwrap(SupportReport.issueURL(report: report))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, report)
        XCTAssertNil(SupportReport.issueURL(report: String(repeating: "ü", count: 8000)))
        XCTAssertEqual(url.host, "github.com")
    }

    func testMissingLoginRegistrationCanRetryAndPropagatesFailure() throws {
        final class Login: LaunchAtLoginServicing {
            var state: LaunchAtLoginState = .registrationMissing
            var attempts = 0
            var fail = true
            func register() throws {
                attempts += 1
                if fail { throw NSError(domain: "test", code: 1) }
                state = .enabled
            }
            func unregister() throws { state = .disabled }
            func openSystemSettings() {}
        }
        let service = Login()
        XCTAssertThrowsError(try service.setEnabled(true))
        service.fail = false
        try service.setEnabled(true)
        try service.setEnabled(true)
        XCTAssertEqual(service.attempts, 2)
        XCTAssertEqual(service.state, .enabled)
        try service.setEnabled(false)
        XCTAssertEqual(service.state, .disabled)
    }

    func testConfigurationCleanupWaitsForSuccessfulSaveAndRetainsFailedOperations() {
        var pending = PendingConfigurationOperations()
        var firstAttempts = 0
        var secondAttempts = 0
        pending.append { firstAttempts += 1; return true }
        pending.append { secondAttempts += 1; return secondAttempts > 1 }
        XCTAssertFalse(pending.finish(configurationSaved: false))
        XCTAssertEqual(firstAttempts, 0)
        XCTAssertEqual(secondAttempts, 0)
        XCTAssertFalse(pending.finish(configurationSaved: true))
        XCTAssertEqual(firstAttempts, 1)
        XCTAssertEqual(secondAttempts, 1)
        XCTAssertTrue(pending.finish(configurationSaved: true))
        XCTAssertEqual(firstAttempts, 1)
        XCTAssertEqual(secondAttempts, 2)
        XCTAssertTrue(pending.finish(configurationSaved: true))
        XCTAssertEqual(secondAttempts, 2)
    }

    func testSettingsDraftPreservesChangesFromOtherConfigurationConsumers() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let baseline = store.loadConfiguration()
        var draft = baseline
        draft.theme = .dark
        draft.tabEdge = .bottom
        draft.tabShowsNames = false
        draft.overlappingZoneTabs = .allWindows
        draft.profiles[0].name = "Edited profile"
        draft.behavior.outlinePulseMode = .allFocusedWindows

        var external = baseline
        external.excludedBundleIdentifiers = ["com.example.Excluded"]
        external.windowDefaultZoneRules = [WindowDefaultZoneRule(bundleIdentifier: "com.example.App", zoneID: .main)]
        external.useNativeCommandTab = true
        XCTAssertTrue(store.saveConfiguration(external))

        let merged = store.mergedConfiguration(draft: draft, baseline: baseline)
        XCTAssertEqual(merged.theme, .dark)
        XCTAssertEqual(merged.tabEdge, .bottom)
        XCTAssertFalse(merged.tabShowsNames)
        XCTAssertEqual(merged.overlappingZoneTabs, .allWindows)
        XCTAssertEqual(merged.profiles[0].name, "Edited profile")
        XCTAssertEqual(merged.behavior.outlinePulseMode, .allFocusedWindows)
        XCTAssertEqual(merged.excludedBundleIdentifiers, external.excludedBundleIdentifiers)
        XCTAssertEqual(merged.windowDefaultZoneRules, external.windowDefaultZoneRules)
        XCTAssertTrue(merged.useNativeCommandTab)
        XCTAssertTrue(store.saveConfiguration(merged))
        XCTAssertEqual(store.loadConfiguration(forceReload: true), merged)
    }

    func testFailedConfigurationWritePreservesSavedConfigurationAndCanRetry() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let baseline = store.loadConfiguration()
        var draft = baseline
        draft.theme = .dark
        try FileManager.default.removeItem(at: store.configURL)
        try FileManager.default.createDirectory(at: store.configURL, withIntermediateDirectories: false)

        XCTAssertFalse(store.saveConfiguration(draft))
        XCTAssertNotNil(store.configurationSaveError)
        XCTAssertEqual(store.loadConfiguration(), baseline)
        try FileManager.default.removeItem(at: store.configURL)
        XCTAssertTrue(store.saveConfiguration(store.mergedConfiguration(draft: draft, baseline: baseline)))
        XCTAssertNil(store.configurationSaveError)
        XCTAssertEqual(store.loadConfiguration(forceReload: true).theme, .dark)
    }



    func testUndoJournalSurvivesStoreReloadAndClearsWhenEmpty() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: 9,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 0
        )
        var transaction = WindowUndoTransaction(
            name: "Snap Window",
            entries: [
                WindowUndoEntry(
                    identity: identity,
                    frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                    assignmentSnapshot: WindowActionSnapshot(
                        identity: identity,
                        frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                        assignment: nil
                    )
                )
            ]
        )
        transaction.createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        store.saveUndoJournal([transaction])

        XCTAssertEqual(PersistenceStore(supportDirectory: directory).loadUndoJournal(), [transaction])
        store.saveUndoJournal([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.undoJournalURL.path))
    }

    func testUpsertKeepsQuartzlessSessionWindowAssignment() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let sessionID = UUID()
        let assignmentID = UUID()
        let identity = WindowIdentity(
            bundleIdentifier: "com.example.Editor",
            processIdentifier: 42,
            cgWindowID: nil,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1,
            sessionID: sessionID
        )
        store.saveAssignments([
            WindowAssignment(
                id: assignmentID,
                identity: identity,
                zoneID: .left,
                updatedAt: Date()
            )
        ])

        store.upsertAssignment(
            WindowAssignment(
                id: assignmentID,
                identity: WindowIdentity(
                    bundleIdentifier: "com.example.Editor",
                    processIdentifier: 42,
                    cgWindowID: nil,
                    axRole: "AXWindow",
                    axSubrole: "AXStandardWindow",
                    observedOrder: 99,
                    titleHint: "renamed",
                    sessionID: sessionID
                ),
                zoneID: .right,
                updatedAt: Date()
            )
        )

        XCTAssertEqual(store.loadAssignments().count, 1)
        XCTAssertEqual(store.loadAssignments().first?.id, assignmentID)
        XCTAssertEqual(store.loadAssignments().first?.zoneID, .right)
    }

    func testDeletingProfilePlacementStatePreservesOtherProfiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        var assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: 7,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 0
            ),
            zoneID: .main,
            placementsByProfileID: [
                "temporary": .zoneFit(zoneID: .left),
                "main": .zoneFit(zoneID: .main)
            ],
            updatedAt: Date()
        )
        let custom = SavedCustomPlacement(size: CGSize(width: 400, height: 300), relativePosition: CGPoint(x: 0.5, y: 0.5))
        assignment.savedCustomPlacementsByProfileID = ["temporary": custom, "main": custom]
        store.saveAssignments([assignment])

        store.removePlacementState(forProfileID: "temporary")

        let restored = try XCTUnwrap(store.loadAssignments().first)
        XCTAssertNil(restored.savedCustomPlacementsByProfileID["temporary"])
        XCTAssertEqual(restored.savedCustomPlacementsByProfileID["main"], custom)
        XCTAssertNil(restored.placementsByProfileID["temporary"])
        XCTAssertEqual(restored.placementsByProfileID["main"], .zoneFit(zoneID: .main))
    }

    func testInvalidWorkspaceDataIsBackedUpBeforeRecovery() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        try Data("not-json".utf8).write(to: store.workspaceURL, options: .atomic)

        XCTAssertEqual(store.loadAssignments(forceReload: true), [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.workspaceURL.appendingPathExtension("invalid-backup").path
            )
        )
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), Data("not-json".utf8))
        XCTAssertNotNil(store.readOnlyReason)
        XCTAssertFalse(store.updateWorkspace { $0.assignments = [] })
    }





    func testAssignmentIdentityRoundTrips() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()

        let assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: 100,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            placementsByProfileID: [
                "profile-a": .custom(
                    zoneID: .center,
                    displayRoleID: .workspace,
                    normalizedDisplayFrame: NormalizedFrame(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        store.saveAssignments([assignment])

        XCTAssertEqual(store.loadAssignments(), [assignment])
    }





    func testWorkspaceUpdatePersistsAssignmentsAndHistoryTogether() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.App",
                processIdentifier: 42,
                cgWindowID: 100,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var reducer = WindowHistoryReducer(state: .empty)
        reducer.recordFocus(assignmentID: assignment.id, zoneID: .center)
        let history = reducer.state

        store.updateWorkspace {
            $0.assignments = [assignment]
            $0.history = history
        }

        let reloaded = PersistenceStore(supportDirectory: directory)
        XCTAssertEqual(reloaded.loadAssignments(), [assignment])
        XCTAssertEqual(reloaded.loadZoneStackState(), history)
    }

    func testSessionAssignmentIsAvailableInMemoryButExcludedFromDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.Ephemeral",
                processIdentifier: 42,
                cgWindowID: 100,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            placementsByProfileID: ["main": .unplaced(zoneID: .center)],
            retention: .session,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        var history = ZoneStackState.empty
        var reducer = WindowHistoryReducer(state: history)
        reducer.recordFocus(assignmentID: assignment.id, zoneID: .center)
        history = reducer.state

        store.updateWorkspace {
            $0.assignments = [assignment]
            $0.history = history
        }

        XCTAssertEqual(store.loadAssignments(), [assignment])
        XCTAssertEqual(store.loadZoneStackState(), history)
        let reloaded = PersistenceStore(supportDirectory: directory)
        XCTAssertEqual(reloaded.loadAssignments(), [])
        XCTAssertEqual(reloaded.loadZoneStackState(), .empty)
    }

    func testPromotingSessionAssignmentPersistsIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        var assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.Promoted",
                processIdentifier: 42,
                cgWindowID: 100,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            retention: .session,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        store.saveAssignments([assignment])

        assignment.retention = .durable
        assignment.placementsByProfileID["main"] = .zoneFit(zoneID: .center)
        store.upsertAssignment(assignment)

        let reloaded = PersistenceStore(supportDirectory: directory)
        XCTAssertEqual(reloaded.loadAssignments(), [assignment])
    }

    func testStagedHistoryWriteFlushesDeterministically() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        let assignment = WindowAssignment(
            id: UUID(),
            identity: WindowIdentity(
                bundleIdentifier: "com.example.Durable",
                processIdentifier: 42,
                cgWindowID: 100,
                axRole: "AXWindow",
                axSubrole: "AXStandardWindow",
                observedOrder: 1
            ),
            zoneID: .center,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        store.saveAssignments([assignment])
        var history = ZoneStackState.empty
        var reducer = WindowHistoryReducer(state: history)
        reducer.recordFocus(assignmentID: assignment.id, zoneID: .center)
        history = reducer.state

        XCTAssertTrue(store.stageZoneStackState(history))
        XCTAssertEqual(store.loadZoneStackState(), history)
        XCTAssertNotEqual(
            PersistenceStore(supportDirectory: directory).loadZoneStackState(),
            history
        )
        XCTAssertTrue(store.flushPendingWorkspaceWrite())
        XCTAssertEqual(
            PersistenceStore(supportDirectory: directory).loadZoneStackState(),
            history
        )
    }



    func testUpsertChangesOnlyAssignmentIDAndLeavesCanonicalizationToReconciliation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()

        let identity = WindowIdentity(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            cgWindowID: 100,
            axRole: "AXWindow",
            axSubrole: "AXStandardWindow",
            observedOrder: 1
        )
        let staleMain = WindowAssignment(
            id: UUID(),
            identity: identity,
            zoneID: .main,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let staleLeft = WindowAssignment(
            id: UUID(),
            identity: identity,
            zoneID: .left,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        store.saveAssignments([staleMain, staleLeft])

        let current = WindowAssignment(
            id: staleMain.id,
            identity: identity,
            zoneID: .right,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        store.upsertAssignment(current)

        let assignments = store.loadAssignments()
        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments.first { $0.id == staleMain.id }?.zoneID, .right)
        XCTAssertEqual(assignments.first { $0.id == staleLeft.id }?.zoneID, .left)
    }

    func testRestoreHistoryIsNewestFirstAndBounded() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        for index in 0..<25 {
            store.appendRestoreRecord(
                RestoreRecord(
                    date: Date(timeIntervalSince1970: TimeInterval(index)),
                    trigger: "test",
                    profileName: "Profile \(index)",
                    moved: index,
                    unchanged: 0,
                    skipped: 0
                )
            )
        }

        let records = store.loadRestoreHistory()
        XCTAssertEqual(records.count, 20)
        XCTAssertEqual(records.first?.profileName, "Profile 24")
        XCTAssertEqual(records.last?.profileName, "Profile 5")
    }
}
