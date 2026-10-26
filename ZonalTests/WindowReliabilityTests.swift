import AppKit
import Darwin
import XCTest
@testable import Zonal

@MainActor
final class WindowReliabilityTests: XCTestCase {
    func testApplicationQuitImmediatelyRemovesTabsAndPreservesSavedAssignments() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000), scale: 1)])
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
        var config = store.loadConfiguration()
        config.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        config.profiles[0].displayRoles = manager.roles(for: snapshot)
        config.profiles[0].zones[0].windowPresentation = .tabs
        XCTAssertTrue(store.saveConfiguration(config))
        var windows = [managedWindow(cgWindowID: 1, observedOrder: 0), managedWindow(cgWindowID: 2, observedOrder: 1)]
        for i in windows.indices { windows[i].isOnCurrentSpace = true }
        // Distinct fake AX elements avoid requiring live Accessibility permissions.
        windows[0].element = AXUIElementCreateApplication(42001)
        windows[1].element = AXUIElementCreateApplication(42002)
        let assignments = windows.map { window in
            WindowAssignment(id: UUID(), identity: window.identity, zoneID: .main,
                placementsByProfileID: [config.profiles[0].id: .zoneFit(zoneID: .main)], updatedAt: Date())
        }
        store.saveAssignments(assignments)
        let registry = WindowRegistry(inventoryProvider: { $0(windows, nil) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: WindowController(), store: store)
        service.start()
        defer { service.stop() }
        XCTAssertEqual(service.tabSnapshots().flatMap(\.items).count, 2)
        tracker.handleApplicationTerminated(processIdentifier: 42)
        XCTAssertTrue(tracker.currentSpaceWindows.isEmpty)
        XCTAssertTrue(service.currentProfileContext().windows.isEmpty)
        XCTAssertTrue(service.tabSnapshots().flatMap(\.items).isEmpty)
        XCTAssertEqual(Set(store.loadAssignments().map(\.id)), Set(assignments.map(\.id)))
        windows = []
        tracker.reconcile()
        XCTAssertTrue(service.tabSnapshots().flatMap(\.items).isEmpty)
    }

    func testApplicationQuitRejectsOlderInventoryAndCompletesFreshScan() {
        var window = managedWindow(cgWindowID: 1, observedOrder: 0)
        window.isOnCurrentSpace = true
        var callbacks: [([ManagedWindow], AXUIElement?) -> Void] = []
        let registry = WindowRegistry(inventoryProvider: { callbacks.append($0) })
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        tracker.reconcile()
        callbacks.removeFirst()([window], nil)
        var published: [[LiveWindowID]] = []
        tracker.onWindowsChanged = { published.append($0.map(\.id)) }
        var completed = false
        tracker.reconcile { completed = true }
        tracker.handleApplicationTerminated(processIdentifier: 42)
        XCTAssertEqual(published, [[]])
        callbacks.removeFirst()([window], nil)
        XCTAssertTrue(tracker.windows.isEmpty)
        XCTAssertFalse(completed)
        XCTAssertEqual(callbacks.count, 1)
        callbacks.removeFirst()([], nil)
        XCTAssertTrue(completed)
        XCTAssertEqual(published, [[]])
    }

    func testAmbiguousLiveWindowsCompeteForOneSavedPlacement() throws {
        try assertAmbiguousRecovery(reverse: false)
        try assertAmbiguousRecovery(reverse: true)
    }

    private func assertAmbiguousRecovery(reverse: Bool) throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        var a = managedWindow(cgWindowID: 99101, observedOrder: 0)
        var b = managedWindow(cgWindowID: 99102, observedOrder: 1)
        a.isOnCurrentSpace = true
        b.isOnCurrentSpace = true
        let observed = reverse ? [b, a] : [a, b]
        let registry = WindowRegistry(inventoryProvider: { $0(observed, nil) })
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000), scale: 1)])
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
        var config = store.loadConfiguration()
        config.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        config.profiles[0].displayRoles = manager.roles(for: snapshot)
        XCTAssertTrue(store.saveConfiguration(config))
        var oldIdentity = a.identity
        oldIdentity.processIdentifier = 41
        oldIdentity.cgWindowID = 99000
        var saved = WindowAssignment(id: UUID(), identity: oldIdentity, zoneID: .main, updatedAt: Date())
        saved.retention = .durable
        saved.placementsByProfileID[config.profiles[0].id] = .zoneFit(zoneID: .main)
        store.saveAssignments([saved])
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { nil })
        let controller = WindowController(frameProvider: { _ in CGRect(x: 0, y: 0, width: 1600, height: 1000) })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: controller, store: store)
        service.start()
        defer { service.stop() }
        XCTAssertEqual(tracker.currentSpaceWindows.count, 2)
        let after = try XCTUnwrap(store.loadAssignments().first { $0.id == saved.id })
        XCTAssertEqual(after.identity, oldIdentity, "Ambiguous live siblings must leave the saved assignment unresolved")
    }

    func testFutureWorkspaceMustNotBeOverwritten() throws {
        let directory = try directory()
        let store = PersistenceStore(supportDirectory: directory)
        store.bootstrap()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.workspaceURL)) as? [String: Any])
        json["schemaVersion"] = 999
        json["futureField"] = "must survive"
        let future = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try future.write(to: store.workspaceURL)
        let reopened = PersistenceStore(supportDirectory: directory)
        reopened.bootstrap()
        _ = reopened.updateWorkspace { _ in }
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.workspaceURL)) as? [String: Any])
        XCTAssertEqual(after["schemaVersion"] as? Int, 999)
        XCTAssertEqual(after["futureField"] as? String, "must survive")
    }


    func testDisplayDisconnectDoesNotPersistMacOSFrameChangesBeforeRestore() async throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        var window = managedWindow(cgWindowID: 42, observedOrder: 0)
        window.isOnCurrentSpace = true
        let captured = window
        let registry = WindowRegistry(inventoryProvider: { completion in completion([captured], captured.element) })
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
        var configuration = store.loadConfiguration()
        configuration.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        configuration.profiles[0].displayRoles = manager.roles(for: snapshot)
        configuration.behavior.restoreOnLaunch = false
        configuration.behavior.restoreOnDisplayChange = true
        XCTAssertTrue(store.saveConfiguration(configuration))
        let profileID = configuration.profiles[0].id
        var original = WindowAssignment(id: UUID(), identity: window.identity, zoneID: .main, updatedAt: Date())
        original.retention = .durable
        original.placementsByProfileID[profileID] = .zoneFit(zoneID: .main)
        store.saveAssignments([original])
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { captured })
        let controller = WindowController(frameProvider: { _ in CGRect(x: 40, y: 40, width: 800, height: 600) })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: controller, store: store)
        let engine = RestoreEngine(profileManager: manager, windowRegistry: registry, windowTracker: tracker,
            windowController: controller, workspaceState: service, store: store)
        service.start()
        engine.start()
        defer { engine.stop(); service.stop() }
        // Prove this is a valid capture target, then restore its fitted state for the disconnect.
        XCTAssertEqual(service.recordCustomFrame(for: window, frame: CGRect(x: 40, y: 40, width: 800, height: 600)), .saved)
        store.saveAssignments([original])
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertTrue(service.isDisplayTransitionActive)
        tracker.onWindowFrameChanged?(captured)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(service.isDisplayTransitionActive)
        XCTAssertEqual(store.loadAssignments().first?.placementsByProfileID[profileID], .zoneFit(zoneID: .main))
    }

    func testManualFitUnavailableReportsNotSavedWithoutCreatingUndo() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let registry = WindowRegistry()
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let original = WindowAssignment(id: UUID(), identity: window.identity, zoneID: .main, updatedAt: Date())
        store.saveAssignments([original])
        let manager = ProfileManager(store: store, displayProvider: Displays())
        let tracker = WindowTracker(registry: registry)
        let controller = WindowController(frameProvider: { _ in CGRect(x: 10, y: 10, width: 300, height: 200) })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: controller, store: store)
        let engine = RestoreEngine(profileManager: manager, windowRegistry: registry, windowTracker: tracker,
            windowController: controller, workspaceState: service, store: store)
        defer { engine.stop() }
        let bytes = try Data(contentsOf: store.workspaceURL)
        var outcomes: [WindowPlacementOutcome] = []
        engine.performManualAction(window: window, change: .fit(.main)) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.notSaved])
        XCTAssertTrue(engine.recentActions.isEmpty)
        XCTAssertTrue(store.loadUndoJournal().isEmpty)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testManualFitFailedSaveReportsNotSavedWithoutCreatingUndo() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let registry = WindowRegistry()
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let original = WindowAssignment(id: UUID(), identity: window.identity, zoneID: .main, updatedAt: Date())
        store.saveAssignments([original])
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let manager = ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot))
        var configuration = store.loadConfiguration()
        configuration.profiles[0].setupBindings = [manager.setupBinding(for: snapshot)]
        configuration.profiles[0].displayRoles = manager.roles(for: snapshot)
        XCTAssertTrue(store.saveConfiguration(configuration))
        let tracker = WindowTracker(registry: registry)
        let controller = WindowController(frameProvider: { _ in CGRect(x: 10, y: 10, width: 300, height: 200) })
        let service = WorkspaceStateService(profileManager: manager, layoutEngine: LayoutEngine(),
            windowRegistry: registry, windowTracker: tracker, windowController: controller, store: store)
        let engine = RestoreEngine(profileManager: manager, windowRegistry: registry, windowTracker: tracker,
            windowController: controller, workspaceState: service, store: store)
        defer { engine.stop() }
        try FileManager.default.removeItem(at: store.workspaceURL)
        try FileManager.default.createDirectory(at: store.workspaceURL, withIntermediateDirectories: false)
        var outcomes: [WindowPlacementOutcome] = []
        engine.performManualAction(window: window, change: .fit(.main)) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.notSaved])
        XCTAssertTrue(engine.recentActions.isEmpty)
        XCTAssertTrue(store.loadUndoJournal().isEmpty)
        try FileManager.default.removeItem(at: store.workspaceURL)
        XCTAssertTrue(store.flushPendingWorkspaceWrite())
        XCTAssertEqual(PersistenceStore(supportDirectory: store.supportDirectory)
            .loadAssignments().first?.placementsByProfileID[configuration.profiles[0].id], .zoneFit(zoneID: .main))
    }

    func testInstanceOwnershipRejectsConcurrentOwnerAndAllowsReacquisition() throws {
        let url = try directory().appendingPathComponent("instance.lock")
        let owner = ZonalInstanceLock(url: url)
        let contender = ZonalInstanceLock(url: url)
        XCTAssertTrue(try owner.acquire())
        XCTAssertTrue(try owner.acquire())
        XCTAssertFalse(try contender.acquire())
        owner.release()
        XCTAssertTrue(try contender.acquire())
        XCTAssertFalse(try owner.acquire())
        contender.release()
        XCTAssertTrue(try owner.acquire())
        owner.release()
    }

    func testInstanceOwnershipRejectsSymlinkWithoutTouchingItsTarget() throws {
        let root = try directory()
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("instance.lock")
        let bytes = Data("preserve me".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ZonalInstanceLock(url: link).acquire())
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testCustomPlacementOnUnknownDisplaySetupReportsUnavailableWithoutSaving() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: Displays()),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let bytes = try Data(contentsOf: store.workspaceURL)
        var failures = 0
        service.onPersistenceFailure = { failures += 1 }
        XCTAssertEqual(service.assignCustomFrame(window, to: .main,
            frame: CGRect(x: 10, y: 10, width: 300, height: 200)), .unavailable)
        XCTAssertEqual(service.recordCustomFrame(for: window,
            frame: CGRect(x: 10, y: 10, width: 300, height: 200)), .unavailable)
        XCTAssertEqual(service.updateAssignment(UUID(), zoneID: .main, fitToZone: false), .unavailable)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testAssignmentSaveReportsFailureAndRetryPersistsIntendedState() throws {
        let root = try directory()
        let store = PersistenceStore(supportDirectory: root)
        store.bootstrap()
        let original = assignment()
        store.saveAssignments([original])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: Displays()),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        let previous = root.appendingPathComponent("previous-workspace")
        try FileManager.default.moveItem(at: store.workspaceURL, to: previous)
        try FileManager.default.createDirectory(at: store.workspaceURL, withIntermediateDirectories: false)
        var failures = 0
        service.onPersistenceFailure = { failures += 1 }
        XCTAssertEqual(service.updateAssignment(original.id, zoneID: .right, fitToZone: false), .failed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(store.loadAssignments().first?.zoneID, .right)
        try FileManager.default.removeItem(at: store.workspaceURL)
        XCTAssertTrue(store.flushPendingWorkspaceWrite())
        XCTAssertEqual(PersistenceStore(supportDirectory: root).loadAssignments().first?.zoneID, .right)
        XCTAssertEqual(service.updateAssignment(original.id, zoneID: .left, fitToZone: false), .saved)
        XCTAssertEqual(failures, 1)
    }

    func testSessionRecoveryCompletionExplicitlyRefreshesUnchangedFocus() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let registry = WindowRegistry()
        let window = managedWindow(cgWindowID: 1, observedOrder: 0)
        let tracker = WindowTracker(registry: registry, focusedWindowProvider: { window })
        tracker.captureFocusedWindow(origin: "test")
        let service = WorkspaceStateService(profileManager: ProfileManager(store: store),
            layoutEngine: LayoutEngine(), windowRegistry: registry, windowTracker: tracker,
            windowController: WindowController(), store: store)
        var refreshed: [LiveWindowID?] = []
        service.onOutlineEnvironmentChanged = { refreshed.append($0?.id) }
        XCTAssertTrue(service.beginSessionRecovery())
        XCTAssertTrue(refreshed.isEmpty)
        service.finishSessionRecovery()
        XCTAssertEqual(refreshed, [window.id])
        XCTAssertFalse(service.isSessionRecoveryActive)
    }

    func testDisplayHandoffKeepsCaptureFrozenAndCarriesOnlyDraggedWindowOptOut() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let registry = WindowRegistry()
        let dragged = managedWindow(cgWindowID: 1, observedOrder: 0)
        let untouched = managedWindow(cgWindowID: 2, observedOrder: 1)
        let tracker = WindowTracker(registry: registry)
        let service = WorkspaceStateService(profileManager: ProfileManager(store: store),
            layoutEngine: LayoutEngine(), windowRegistry: registry, windowTracker: tracker,
            windowController: WindowController(), store: store)
        let before = try Data(contentsOf: store.workspaceURL)
        XCTAssertTrue(service.beginSessionRecovery())
        service.recordUserAdjustmentDuringRecovery(to: dragged)
        let generation = service.beginDisplayTransition()
        service.finishSessionRecovery()
        XCTAssertTrue(service.isDisplayTransitionActive, "Never release capture suppression between restores")
        XCTAssertFalse(service.shouldRestoreAfterDisplayChange(dragged))
        XCTAssertTrue(service.shouldRestoreAfterDisplayChange(untouched))
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), before)
        service.finishDisplayTransition(generation: generation)
        XCTAssertFalse(service.isDisplayTransitionActive)
    }

    func testKnownFocusFastPathRequiresExactCurrentSpaceIdentityAndNoRecovery() {
        let known = managedWindow(cgWindowID: 1, observedOrder: 0)
        let other = managedWindow(cgWindowID: 2, observedOrder: 0)
        XCTAssertTrue(KnownWindowFocusPolicy.canSkipReconciliation(identity: known.identity,
            cached: [known], current: [known], recovering: false))
        XCTAssertFalse(KnownWindowFocusPolicy.canSkipReconciliation(identity: known.identity,
            cached: [other], current: [known], recovering: false))
        XCTAssertFalse(KnownWindowFocusPolicy.canSkipReconciliation(identity: known.identity,
            cached: [known], current: [other], recovering: false))
        XCTAssertFalse(KnownWindowFocusPolicy.canSkipReconciliation(identity: known.identity,
            cached: [known], current: [known], recovering: true))
        var reused = known.identity
        reused.processIdentifier = 43
        XCTAssertFalse(KnownWindowFocusPolicy.canSkipReconciliation(identity: reused,
            cached: [known], current: [known], recovering: false))
    }

    func testPlacementSkipsOnlyWhenPositionAndSizeAlreadyMatch() {
        let frame = CGRect(x: 10, y: 30, width: 800, height: 600)
        XCTAssertTrue(PlacementNoOpPolicy.shouldSkip(actual: frame, target: frame))
        XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: nil, target: frame))
        XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: frame.offsetBy(dx: 20, dy: 0), target: frame))
        for (x, y) in [(CGFloat(1), CGFloat(0)), (-1, 0), (0, 1), (0, -1), (0.5, 0), (0, -0.5)] {
            XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: frame.offsetBy(dx: x, dy: y), target: frame))
        }
        XCTAssertTrue(PlacementNoOpPolicy.shouldSkip(actual: frame.offsetBy(dx: 0.005, dy: -0.005), target: frame))
        XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: CGRect(x: 10, y: 30, width: 802, height: 598), target: frame))
        XCTAssertFalse(PlacementNoOpPolicy.shouldSkip(actual: CGRect(x: 10, y: 30, width: 803, height: 600), target: frame))
    }

    func testFocusLayoutDoesNotRepeatPreparedOrAlreadyActiveStack() {
        let selected = UUID()
        XCTAssertFalse(FocusLayoutPolicy.needsLayout(assignmentID: selected, previousActive: UUID(), prepared: true))
        XCTAssertFalse(FocusLayoutPolicy.needsLayout(assignmentID: selected, previousActive: selected, prepared: false))
        XCTAssertTrue(FocusLayoutPolicy.needsLayout(assignmentID: selected, previousActive: UUID(), prepared: false))
        XCTAssertTrue(FocusLayoutPolicy.needsLayout(assignmentID: selected, previousActive: nil, prepared: false))
    }

    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/zonal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func assignment(number: UInt32 = 1) -> WindowAssignment {
        var identity = WindowIdentity(bundleIdentifier: "test.editor", processIdentifier: 42, cgWindowID: number,
                                      axRole: "AXWindow", axSubrole: "AXStandardWindow", observedOrder: 0)
        identity.documentURL = "file:///same-document.txt"
        return WindowAssignment(id: UUID(), identity: identity, zoneID: .main, updatedAt: Date())
    }

    func testSameDocumentAssignmentsRemainIndependent() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        var first = assignment()
        let second = assignment(number: 2)
        store.saveAssignments([first, second])
        first.zoneID = .left
        store.upsertAssignment(first)
        XCTAssertEqual(store.loadAssignments(), [first, second])
    }

    func testFailedWorkspaceWriteRetriesIntendedState() throws {
        let root = try directory()
        let store = PersistenceStore(supportDirectory: root)
        store.bootstrap()
        let first = assignment()
        store.saveAssignments([first])
        let original = root.appendingPathComponent("previous-workspace")
        try FileManager.default.moveItem(at: store.workspaceURL, to: original)
        try FileManager.default.createDirectory(at: store.workspaceURL, withIntermediateDirectories: false)
        XCTAssertFalse(store.updateWorkspace { $0.assignments[0].zoneID = .right })
        XCTAssertEqual(store.loadAssignments()[0].zoneID, .right)
        try FileManager.default.removeItem(at: store.workspaceURL)
        try FileManager.default.moveItem(at: original, to: store.workspaceURL)
        XCTAssertTrue(store.flushPendingWorkspaceWrite())
        XCTAssertEqual(PersistenceStore(supportDirectory: root).loadAssignments()[0].zoneID, .right)
    }

    func testUndoJournalReportsWriteFailuresAndRecovers() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let entry = WindowUndoEntry(identity: assignment().identity,
                                    frame: CGRect(x: 0, y: 0, width: 100, height: 100), assignmentSnapshot: nil)
        let transaction = WindowUndoTransaction(name: "Move", entries: [entry])
        try FileManager.default.createDirectory(at: store.undoJournalURL, withIntermediateDirectories: false)
        // A directory in place of the journal gives a deterministic write failure.
        XCTAssertFalse(store.saveUndoJournal([transaction]))
        try FileManager.default.removeItem(at: store.undoJournalURL)
        XCTAssertTrue(store.saveUndoJournal([transaction]))
        XCTAssertEqual(store.loadUndoJournal().first?.id, transaction.id)
        XCTAssertTrue(store.saveUndoJournal([]))
    }

    func testUndoShortcutRoundTripsWithoutStealingPlainCommandZ() throws {
        let binding = HotkeyBinding(command: .undo, keyCode: 6, keyLabel: "Z", modifiers: .controlOption)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(decoded, binding)
        guard case .undo = decoded.command.zonalCommand else { return XCTFail("Undo must reach the global command handler") }
        XCTAssertFalse(HotkeyBinding.defaults.contains { $0.keyCode == 6 && $0.modifiers == .commandOnly })
    }

    func testUndoBatchFinishesOnceWithSynchronousAndDuplicateResults() {
        let entries = (1...3).map { index in
            WindowUndoEntry(identity: assignment(number: UInt32(index)).identity,
                            frame: CGRect(x: 0, y: 0, width: 400, height: 300), assignmentSnapshot: nil)
        }
        let batch = WindowUndoBatch(entries: entries)
        XCTAssertFalse(batch.complete(index: 0, outcome: .cancelledByUser))
        XCTAssertFalse(batch.complete(index: 0, outcome: .placed))
        XCTAssertFalse(batch.complete(index: 2, outcome: .placed))
        XCTAssertTrue(batch.complete(index: 1, outcome: .constrained))
        XCTAssertFalse(batch.complete(index: 1, outcome: .placed))
        XCTAssertEqual(batch.restored, 1)
        XCTAssertEqual(batch.failedEntries, [entries[0], entries[1]])
    }

    func testAccordionScopeExcludesOtherZonesCustomAndIgnoredWindows() {
        var profile = DefaultProfiles.main
        profile.zones[0].windowPresentation = .peekStack
        let zone = profile.zones[0].id
        var window = assignment()
        window.zoneID = zone
        window.placementsByProfileID[profile.id] = .zoneFit(zoneID: zone)
        XCTAssertTrue(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile))
        XCTAssertFalse(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile, busyZones: [zone]))
        profile.zones[0].windowPresentation = .overlap
        XCTAssertFalse(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile))
        XCTAssertTrue(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile, includeOverlap: true))
        profile.zones[0].windowPresentation = .peekStack
        XCTAssertFalse(ZoneReflowPolicy.includes(window, zones: [], profile: profile))
        window.managementMode = .ignored
        XCTAssertFalse(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile))
        window.managementMode = .managed
        window.placementsByProfileID[profile.id] = .unplaced(zoneID: zone)
        XCTAssertFalse(ZoneReflowPolicy.includes(window, zones: [zone], profile: profile))
    }

    func testMissingProfilePreservesCustomSizeAndKeepsWindowReachableWithoutPersisting() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot)),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        var profile = DefaultProfiles.main
        profile.zones[0].windowPresentation = .tabs
        let zone = profile.zones[0].id
        var custom = assignment()
        custom.zoneID = zone
        custom.placementsByProfileID["ultrawide"] = .custom(zoneID: zone, displayRoleID: .workspace, normalizedDisplayFrame: .full)
        store.saveAssignments([custom])
        let saved = store.loadAssignments()
        let available = snapshot.displays[0].placementFrame
        let current = CGRect(x: 2200, y: -300, width: 825, height: 650)
        let target = try XCTUnwrap(service.targetFrame(for: custom, profile: profile, snapshot: snapshot, currentFrame: current))
        XCTAssertEqual(target.frame.size, current.size)
        XCTAssertTrue(available.contains(target.frame))
        XCTAssertEqual(target.frame.minY, available.minY)
        XCTAssertFalse(ZoneReflowPolicy.includes(custom, zones: [zone], profile: profile, includeOverlap: true),
                       "Focus and presentation changes must not refit a custom window with no placement in this profile")
        let onScreen = CGRect(x: 50, y: 50, width: 825, height: 650)
        XCTAssertEqual(service.targetFrame(for: custom, profile: profile, snapshot: snapshot, currentFrame: onScreen)?.frame, onScreen)
        let oversized = try XCTUnwrap(service.targetFrame(for: custom, profile: profile, snapshot: snapshot,
            currentFrame: CGRect(x: -200, y: -200, width: 3000, height: 2000)))
        XCTAssertEqual(oversized.frame, available)
        custom.placementsByProfileID[profile.id] = .zoneFit(zoneID: zone)
        XCTAssertTrue(ZoneReflowPolicy.includes(custom, zones: [zone], profile: profile))
        let fitted = try XCTUnwrap(service.targetFrame(for: custom, profile: profile, snapshot: snapshot, currentFrame: current))
        XCTAssertNotEqual(fitted.frame.size, current.size)
        custom.placementsByProfileID[profile.id] = .custom(zoneID: zone, displayRoleID: .workspace, normalizedDisplayFrame: .full)
        XCTAssertEqual(service.targetFrame(for: custom, profile: profile, snapshot: snapshot, currentFrame: current)?.frame, available)
        custom.placementsByProfileID[profile.id] = .unplaced(zoneID: zone)
        XCTAssertNil(service.targetFrame(for: custom, profile: profile, snapshot: snapshot, currentFrame: current))
        XCTAssertEqual(store.loadAssignments(), saved)
    }

    func testMissingProfileCarriesExplicitFitIntentButCustomSizingWins() {
        var window = assignment()
        XCTAssertTrue(window.fitsZone(in: "laptop")) // Existing unconfigured assignments keep their default.
        window.placementsByProfileID["ultrawide"] = .zoneFit(zoneID: .main)
        XCTAssertTrue(window.fitsZone(in: "laptop"))
        window.placementsByProfileID["other"] = .custom(zoneID: .main, displayRoleID: .workspace, normalizedDisplayFrame: .full)
        XCTAssertFalse(window.fitsZone(in: "laptop"))
        window.placementsByProfileID["laptop"] = .zoneFit(zoneID: .main)
        XCTAssertTrue(window.fitsZone(in: "laptop"))
    }

    func testPeekFocusPreviewDoesNotChangeHistoryOrWindowSize() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot)),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        var profile = DefaultProfiles.main
        profile.zones[0].windowPresentation = .peekStack
        let zone = profile.zones[0].id
        var first = assignment(), second = assignment(number: 2)
        first.zoneID = zone
        second.zoneID = zone
        first.placementsByProfileID[profile.id] = .zoneFit(zoneID: zone)
        second.placementsByProfileID[profile.id] = .zoneFit(zoneID: zone)
        store.saveAssignments([first, second])
        let history = ZoneStackState(globalRecency: [first.id, second.id], activeAssignmentByZone: [zone: first.id],
                                     assignmentRecencyByZone: [zone: [first.id, second.id]])
        store.saveZoneStackState(history)
        let bytes = try Data(contentsOf: store.workspaceURL)
        let before = try XCTUnwrap(service.targetFrame(for: second, profile: profile, snapshot: snapshot,
                                                       stackAssignments: [first, second]))
        let preview = try XCTUnwrap(service.targetFrame(for: second, profile: profile, snapshot: snapshot,
                                                        stackAssignments: [first, second], activeAssignmentID: second.id))
        XCTAssertEqual(before.frame.size, preview.frame.size)
        XCTAssertEqual(preview.frame.minX - before.frame.minX, CGFloat(profile.zones[0].peekWidth))
        let oldForeground = try XCTUnwrap(service.targetFrame(for: first, profile: profile, snapshot: snapshot,
            stackAssignments: [first, second]))
        let oldBackground = try XCTUnwrap(service.targetFrame(for: first, profile: profile, snapshot: snapshot,
            stackAssignments: [first, second], activeAssignmentID: second.id))
        XCTAssertEqual(oldForeground.frame.size, oldBackground.frame.size)
        XCTAssertEqual(oldForeground.frame.minX - oldBackground.frame.minX, CGFloat(profile.zones[0].peekWidth))
        XCTAssertEqual(oldBackground.frame.minX, before.frame.minX)
        XCTAssertEqual(before.container, preview.container)
        XCTAssertEqual(store.loadZoneStackState(), history)
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testLaptopPeekPreservesCustomMissingProfileWithoutOverwritingExternalPlacements() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 24, width: 1512, height: 958), scale: 2,
            persistentID: "built-in", name: "Built-in", isBuiltIn: true)])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot)),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        var profile = DisplayProfile(id: "laptop", name: "Laptop", mainZoneID: .main,
            zones: [Zone(id: .main, name: "Main", frame: .full)])
        profile.zones[0].windowPresentation = .peekStack
        let zone = ZoneID.main
        var first = assignment(), second = assignment(number: 2)
        first.zoneID = zone
        second.zoneID = zone
        first.placementsByProfileID = ["external": .zoneFit(zoneID: zone)]
        second.placementsByProfileID = ["external": .custom(zoneID: zone, displayRoleID: .workspace,
            normalizedDisplayFrame: .full)]
        var unplaced = assignment(number: 3), custom = assignment(number: 4)
        unplaced.zoneID = zone
        custom.zoneID = zone
        unplaced.placementsByProfileID = [profile.id: .unplaced(zoneID: zone)]
        custom.placementsByProfileID = [profile.id: .custom(zoneID: zone, displayRoleID: .workspace,
            normalizedDisplayFrame: .full)]
        let stack = [first, second, unplaced, custom]
        store.saveAssignments(stack)
        store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [zone: first.id],
            assignmentRecencyByZone: [zone: [first.id, second.id, unplaced.id, custom.id]]))
        let bytes = try Data(contentsOf: store.workspaceURL)
        XCTAssertTrue(ZoneReflowPolicy.includes(first, zones: [zone], profile: profile))
        XCTAssertFalse(ZoneReflowPolicy.includes(second, zones: [zone], profile: profile))
        XCTAssertFalse(ZoneReflowPolicy.includes(unplaced, zones: [zone], profile: profile))
        XCTAssertFalse(ZoneReflowPolicy.includes(custom, zones: [zone], profile: profile))
        XCTAssertNil(service.targetFrame(for: unplaced, profile: profile, snapshot: snapshot,
            stackAssignments: stack))
        for direction in ZonePeekDirection.allCases {
            profile.zones[0].peekDirection = direction
            let zoneFrame = profile.zones[0].frame.rect(in: snapshot.displays[0].placementFrame)
            for active in [first.id, second.id] {
                let fitted = try XCTUnwrap(service.targetFrame(for: first, profile: profile,
                    snapshot: snapshot, stackAssignments: stack, activeAssignmentID: active))
                XCTAssertEqual(fitted.frame, zoneFrame)
                let customFrame = CGRect(x: 100, y: 80, width: 600, height: 400)
                let preserved = try XCTUnwrap(service.targetFrame(for: second, profile: profile,
                    snapshot: snapshot, stackAssignments: stack, activeAssignmentID: active, currentFrame: customFrame))
                XCTAssertEqual(preserved.frame, customFrame)
            }
        }
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
        XCTAssertEqual(store.loadAssignments(), stack)
    }

    func testFocusingOutsidePeekStackPreservesEveryPeekFrame() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        let snapshot = DisplaySnapshot(displays: [.init(id: 99,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            visibleFrame: CGRect(x: 0, y: 24, width: 1600, height: 976), scale: 1)])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: FixedDisplayProvider(snapshot: snapshot)),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        var profile = DefaultProfiles.main
        profile.zones[0].windowPresentation = .peekStack
        let zone = profile.zones[0].id
        let fitted = (1...3).map { number in
            var window = assignment(number: UInt32(number))
            window.zoneID = zone
            window.placementsByProfileID[profile.id] = .zoneFit(zoneID: zone)
            return window
        }
        var outsider = assignment(number: 4)
        outsider.zoneID = zone
        let custom = WindowPlacement.custom(zoneID: zone, displayRoleID: .workspace,
                                             normalizedDisplayFrame: .full)
        for direction in ZonePeekDirection.allCases {
            profile.zones[0].peekDirection = direction
            for kind in 0..<3 {
                outsider.managementMode = kind == 2 ? .ignored : .managed
                outsider.placementsByProfileID[profile.id] = kind == 0 ? custom
                    : kind == 1 ? .unplaced(zoneID: zone) : .zoneFit(zoneID: zone)
                let stack = fitted + [outsider]
                store.saveAssignments(stack)
                let recency = fitted.map(\.id)
                store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [zone: fitted[0].id],
                                                        assignmentRecencyByZone: [zone: recency]))
                let before = try fitted.map {
                    try XCTUnwrap(service.targetFrame(for: $0, profile: profile, snapshot: snapshot,
                                                      stackAssignments: stack)).frame
                }
                // MRU still records actual focus, but the non-member cannot reorder peek.
                store.saveZoneStackState(ZoneStackState(activeAssignmentByZone: [zone: outsider.id],
                                                        assignmentRecencyByZone: [zone: [outsider.id] + recency]))
                XCTAssertFalse(ZoneReflowPolicy.includes(outsider, zones: [zone], profile: profile))
                let bytes = try Data(contentsOf: store.workspaceURL)
                for (index, window) in fitted.enumerated() {
                    let after = try XCTUnwrap(service.targetFrame(for: window, profile: profile, snapshot: snapshot,
                                                                  stackAssignments: stack))
                    XCTAssertEqual(after.frame, before[index])
                }
                XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
            }
        }
    }

    func testBehaviorOptionsRoundTrip() throws {
        var config = ZonalConfiguration.default
        config.behavior.feedbackMode = .errorsOnly
        config.behavior.feedbackCorner = .topLeading
        config.behavior.switcherDisplayScope = .focusedDisplay
        config.behavior.restoreOnWake = false
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(ZonalConfiguration.self, from: data), config)

    }

    func testFocusedDisplayScopeUsesLargestOverlapAndHandlesNegativeCoordinates() {
        let left = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 1)
        let right = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 2)
        let spanning = LiveWindowID.quartz(processIdentifier: 1, windowNumber: 3)
        let frames = [left: CGRect(x: -800, y: 0, width: 300, height: 300),
                      right: CGRect(x: 10, y: 0, width: 300, height: 300),
                      spanning: CGRect(x: -10, y: 0, width: 200, height: 300)]
        let displays = [CGRect(x: -900, y: 0, width: 900, height: 700), CGRect(x: 0, y: 0, width: 900, height: 700)]
        let policy = WindowDisplayScopePolicy()
        XCTAssertEqual(policy.includedWindowIDs(scope: .focusedDisplay, focused: left, frames: frames, displays: displays), [left])
        XCTAssertEqual(policy.includedWindowIDs(scope: .focusedDisplay, focused: right, frames: frames, displays: displays), [right, spanning])
        XCTAssertNil(policy.includedWindowIDs(scope: .allDisplays, focused: left, frames: frames, displays: displays))
        XCTAssertNil(policy.includedWindowIDs(scope: .focusedDisplay, focused: nil, frames: frames, displays: displays))
    }

    func testDisabledAutomaticRestoresNeverDisableManualActions() {
        var settings = WindowBehaviorSettings()
        settings.restoreOnLaunch = false
        settings.restoreOnWake = false
        settings.restoreOnSpaceChange = false
        settings.restoreOnDisplayChange = false
        for trigger: RestoreTrigger in [.launch, .systemResume, .spaceChange, .displayChange] {
            XCTAssertFalse(settings.allows(trigger))
        }
        for trigger: RestoreTrigger in [.manual, .profileApply, .applicationLifecycle] {
            XCTAssertTrue(settings.allows(trigger))
        }
        settings.feedbackMode = .errorsOnly
        XCTAssertFalse(settings.shows(WindowActionNotification(title: "", detail: "", symbolName: "", tone: .accent)))
        XCTAssertTrue(settings.shows(WindowActionNotification(title: "", detail: "", symbolName: "", tone: .warning)))
    }

    func testAllFeedbackCornersKeepSurfaceInsideVisibleScreen() {
        let screen = CGRect(x: -900, y: 100, width: 900, height: 700)
        for corner in FloatingHUDCorner.allCases {
            let footprint = FloatingHUDPlacementPolicy().frame(
                visibleFrame: screen, panelSize: CGSize(width: 448, height: 108),
                effectOutset: 24, surfaceInset: 20, corner: corner)
            let surface = footprint.insetBy(dx: 24, dy: 24)
            XCTAssertTrue(screen.contains(surface))
            XCTAssertEqual(corner == .topLeading || corner == .topTrailing ? screen.maxY - surface.maxY : surface.minY - screen.minY, 20)
        }
    }

    private struct Displays: DisplaySnapshotProviding {
        func currentSnapshot() -> DisplaySnapshot { DisplaySnapshot(displays: []) }
    }

    func testReadProjectionsDoNotDiscoverOrMutateAssignments() throws {
        let store = PersistenceStore(supportDirectory: try directory())
        store.bootstrap()
        var session = assignment()
        session.retention = .session
        store.saveAssignments([session])
        let registry = WindowRegistry()
        let service = WorkspaceStateService(
            profileManager: ProfileManager(store: store, displayProvider: Displays()),
            layoutEngine: LayoutEngine(), windowRegistry: registry,
            windowTracker: WindowTracker(registry: registry), windowController: WindowController(), store: store)
        let bytes = try Data(contentsOf: store.workspaceURL)
        for _ in 0..<3 {
            _ = service.currentProfileContext()
            _ = service.refreshSwitcherSnapshot(mode: .allWindows, resetSelection: true)
            _ = service.hasFullScreenCompanionContext()
            XCTAssertFalse(service.shouldUseNativeSwitcherInFullScreen())
        }
        XCTAssertEqual(store.loadAssignments(), [session])
        XCTAssertEqual(try Data(contentsOf: store.workspaceURL), bytes)
    }

    func testAutomationSecondInstanceCannotUnlinkOwnerSocket() throws {
        let socket = try directory().appendingPathComponent("api.sock")
        let first = LocalAutomationSocketServer(socketURL: socket) { _, _ in }
        let second = LocalAutomationSocketServer(socketURL: socket) { _, _ in }
        try first.start()
        defer { first.stop(); second.stop() }
        XCTAssertThrowsError(try second.start())
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertNoThrow(try second.start())
    }

    func testAutomationSlowReaderDoesNotBlockOtherClients() async throws {
        let socket = try directory().appendingPathComponent("api.sock")
        let received = expectation(description: "slow client request received")
        let server = LocalAutomationSocketServer(socketURL: socket, connectionTimeout: 1) { request, reply in
            let large = request.command == "large"
            reply(LocalAutomationResponse(apiVersion: 2, requestID: request.id, command: request.command,
                ok: true, message: large ? String(repeating: "x", count: 900_000) : "ready", result: nil, error: nil))
            if large { received.fulfill() }
        }
        try server.start()
        defer { server.stop() }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in bytes.indices { buffer[index] = UInt8(bitPattern: bytes[index]) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request = LocalAutomationRequest(apiVersion: 2, id: "slow", command: "large", arguments: [])
        var payload = try JSONEncoder().encode(request)
        payload.append(10)
        _ = payload.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        await fulfillment(of: [received], timeout: 2)
        let response = try await Task.detached {
            try LocalAutomationSocketClient(socketURL: socket).send(
                LocalAutomationRequest(apiVersion: 2, id: "fast", command: "health", arguments: []))
        }.value
        XCTAssertEqual(response.message, "ready")
    }
}
