import Foundation
import OSLog

enum ZonalStoragePaths {
    static func supportDirectory(bundleIdentifier: String?, fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let name = bundleIdentifier == "com.sebmarste.zonal" ? "Zonal" : "Zonal Development"
        return base.appendingPathComponent(name, isDirectory: true)
    }

    static var current: URL { supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier) }
    // Share only process ownership with installed releases, never workspace data or sockets.
    static var instanceLock: URL {
        supportDirectory(bundleIdentifier: "com.sebmarste.zonal").appendingPathComponent("instance.lock")
    }
}

final class PersistenceStore {
    private static let workspaceSchemaVersion = 3
    private static let workspaceWriteDelay: TimeInterval = 0.3

    struct WorkspaceArchive: Codable, Equatable {
        var schemaVersion: Int
        var assignments: [WindowAssignment]
        var history: ZoneStackState

        static let empty = WorkspaceArchive(
            schemaVersion: PersistenceStore.workspaceSchemaVersion,
            assignments: [],
            history: .empty
        )
    }

    private struct RestoreHistoryArchive: Codable {
        var schemaVersion: Int
        var records: [RestoreRecord]
    }

    private struct UndoJournalArchive: Codable {
        var schemaVersion: Int
        var transactions: [WindowUndoTransaction]
    }

    private static let logger = Logger(subsystem: "com.sebmarste.zonal", category: "Persistence")
    private let fileManager: FileManager
    private let supportDirectoryOverride: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedConfiguration: ZonalConfiguration?
    private(set) var configurationSaveError: String?
    private var cachedWorkspace: WorkspaceArchive?
    private var cachedPersistedWorkspace: WorkspaceArchive?
    private var cachedRestoreHistory: [RestoreRecord]?
    private(set) var readOnlyReason: String?
    private var pendingWorkspaceWrite: DispatchWorkItem?
    private var workspaceWritePending = false

    init(fileManager: FileManager = .default, supportDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.supportDirectoryOverride = supportDirectory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var supportDirectory: URL {
        if let supportDirectoryOverride {
            return supportDirectoryOverride
        }
        return ZonalStoragePaths.supportDirectory(bundleIdentifier: Bundle.main.bundleIdentifier, fileManager: fileManager)
    }

    var configURL: URL {
        supportDirectory.appendingPathComponent("zonal-config.json")
    }

    var workspaceURL: URL {
        supportDirectory.appendingPathComponent("workspace.json")
    }

    var restoreHistoryURL: URL {
        supportDirectory.appendingPathComponent("restore-history.json")
    }

    var undoJournalURL: URL {
        supportDirectory.appendingPathComponent("undo-journal.json")
    }

    func bootstrap() {
        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Could not create support directory: \(error.localizedDescription, privacy: .public)")
            return
        }
        _ = loadConfiguration()
        _ = loadWorkspace()
        _ = loadRestoreHistory()
        _ = loadUndoJournal()
        guard readOnlyReason == nil else { return }
        if !fileManager.fileExists(atPath: configURL.path) { saveConfiguration(.default) }
        if !fileManager.fileExists(atPath: restoreHistoryURL.path) { saveRestoreHistory([]) }
        if !fileManager.fileExists(atPath: workspaceURL.path) { _ = saveWorkspace(.empty) }
    }

    func loadProfiles(forceReload: Bool = false) -> [DisplayProfile] {
        loadConfiguration(forceReload: forceReload).profiles
    }

    func loadConfiguration(forceReload: Bool = false) -> ZonalConfiguration {
        if !forceReload, let cachedConfiguration {
            return cachedConfiguration
        }
        guard fileManager.fileExists(atPath: configURL.path) else { return .default }
        do {
            let configuration: ZonalConfiguration = try read(configURL, version: 5)
            try PersistenceValidation.configuration(configuration)
            cachedConfiguration = configuration
            return configuration
        } catch {
            blockWrites(for: configURL, error: error)
            return .default
        }
    }

    @discardableResult
    func saveConfiguration(_ configuration: ZonalConfiguration) -> Bool {
        do { try PersistenceValidation.configuration(configuration) }
        catch { configurationSaveError = "Settings contain invalid or duplicate identifiers."; return false }
        guard write(configuration, to: configURL, label: "configuration") else {
            configurationSaveError = readOnlyReason ?? "Settings could not be saved. Check that Zonal’s support folder is writable, then retry."
            return false
        }
        cachedConfiguration = configuration
        configurationSaveError = nil
        return true
    }

    // Only the fields edited by this draft replace the shared store's latest values.
    func mergedConfiguration(draft: ZonalConfiguration, baseline: ZonalConfiguration) -> ZonalConfiguration {
        var latest = loadConfiguration()
        func merge<Value: Equatable>(_ keyPath: WritableKeyPath<ZonalConfiguration, Value>) {
            if draft[keyPath: keyPath] != baseline[keyPath: keyPath] {
                latest[keyPath: keyPath] = draft[keyPath: keyPath]
            }
        }
        merge(\.schemaVersion)
        merge(\.setupVersion)
        merge(\.activeProfileID)
        merge(\.profiles)
        merge(\.hotkeys)
        merge(\.useNativeCommandTab)
        merge(\.menuBarMode)
        merge(\.theme)
        merge(\.tabEdge)
        merge(\.tabShowsNames)
        merge(\.overlappingZoneTabs)
        merge(\.dragZoneActivationMode)
        merge(\.showInteractionDiagnostics)
        merge(\.showActiveWindowOutline)
        merge(\.activeWindowOutlineColor)
        merge(\.activeWindowOutlineWidth)
        merge(\.useNativeCommandTabInFullScreen)
        merge(\.behavior.feedbackMode)
        merge(\.behavior.feedbackCorner)
        merge(\.behavior.showSwitcherShortcutGuide)
        merge(\.behavior.switcherDisplayScope)
        merge(\.behavior.outlinePulseMode)
        merge(\.behavior.restoreOnLaunch)
        merge(\.behavior.restoreOnWake)
        merge(\.behavior.restoreOnDisplayChange)
        merge(\.behavior.restoreOnSpaceChange)
        merge(\.excludedBundleIdentifiers)
        merge(\.windowDefaultZoneRules)
        return latest
    }

    func loadUndoJournal() -> [WindowUndoTransaction] {
        guard fileManager.fileExists(atPath: undoJournalURL.path) else { return [] }
        do {
            let archive: UndoJournalArchive = try read(undoJournalURL, version: 1)
            return Array(archive.transactions.filter { !$0.entries.isEmpty }.suffix(20))
        } catch { blockWrites(for: undoJournalURL, error: error); return [] }
    }

    @discardableResult
    func saveUndoJournal(_ transactions: [WindowUndoTransaction]) -> Bool {
        guard canWrite(undoJournalURL) else { return false }
        let retained = Array(transactions.suffix(20))
        guard !retained.isEmpty else {
            guard fileManager.fileExists(atPath: undoJournalURL.path) else { return true }
            do { try fileManager.removeItem(at: undoJournalURL); return true }
            catch {
                Self.logger.error("Could not clear undo journal: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        return write(
            UndoJournalArchive(schemaVersion: 1, transactions: retained),
            to: undoJournalURL,
            label: "undo journal"
        )
    }

    func loadAssignments(forceReload: Bool = false) -> [WindowAssignment] {
        loadWorkspace(forceReload: forceReload).assignments
    }

    func saveAssignments(_ assignments: [WindowAssignment]) {
        updateWorkspace { $0.assignments = assignments }
    }

    func upsertAssignment(_ assignment: WindowAssignment) {
        var assignments = loadAssignments()
        if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
            assignments[index] = assignment
        } else {
            assignments.append(assignment)
        }
        saveAssignments(assignments)
    }

    @discardableResult
    func removePlacementState(forProfileID profileID: String) -> Bool {
        updateWorkspace { workspace in
            for index in workspace.assignments.indices {
                workspace.assignments[index].placementsByProfileID.removeValue(forKey: profileID)
                workspace.assignments[index].savedCustomPlacementsByProfileID.removeValue(forKey: profileID)
            }
        }
    }

    func loadZoneStackState(forceReload: Bool = false) -> ZoneStackState {
        loadWorkspace(forceReload: forceReload).history
    }

    @discardableResult
    func saveZoneStackState(_ state: ZoneStackState) -> Bool {
        updateWorkspace { $0.history = state }
    }

    @discardableResult
    func stageZoneStackState(_ state: ZoneStackState) -> Bool {
        updateWorkspaceCoalesced { $0.history = state }
    }

    @discardableResult
    func flushPendingWorkspaceWrite() -> Bool {
        pendingWorkspaceWrite?.cancel()
        pendingWorkspaceWrite = nil
        guard workspaceWritePending, let workspace = cachedWorkspace else { return true }
        let saved = saveWorkspace(workspace)
        workspaceWritePending = !saved
        return saved
    }

    @discardableResult
    func updateWorkspace(_ update: (inout WorkspaceArchive) -> Void) -> Bool {
        pendingWorkspaceWrite?.cancel()
        pendingWorkspaceWrite = nil
        var workspace = loadWorkspace()
        guard readOnlyReason == nil else { return false }
        update(&workspace)
        do { try PersistenceValidation.workspace(workspace) } catch { return false }
        workspace.schemaVersion = Self.workspaceSchemaVersion
        cachedWorkspace = workspace
        let saved = saveWorkspace(workspace)
        workspaceWritePending = !saved
        return saved
    }

    @discardableResult
    private func updateWorkspaceCoalesced(_ update: (inout WorkspaceArchive) -> Void) -> Bool {
        var workspace = loadWorkspace()
        guard readOnlyReason == nil else { return false }
        update(&workspace)
        do { try PersistenceValidation.workspace(workspace) } catch { return false }
        workspace.schemaVersion = Self.workspaceSchemaVersion
        cachedWorkspace = workspace
        workspaceWritePending = true
        pendingWorkspaceWrite?.cancel()
        let item = DispatchWorkItem { [weak self] in
            _ = self?.flushPendingWorkspaceWrite()
        }
        pendingWorkspaceWrite = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.workspaceWriteDelay,
            execute: item
        )
        return true
    }

    private func loadWorkspace(forceReload: Bool = false) -> WorkspaceArchive {
        if !forceReload, let cachedWorkspace {
            return cachedWorkspace
        }
        guard fileManager.fileExists(atPath: workspaceURL.path) else { return .empty }
        do {
            let workspace: WorkspaceArchive = try read(workspaceURL, version: Self.workspaceSchemaVersion)
            try PersistenceValidation.workspace(workspace)
            cachedWorkspace = workspace
            cachedPersistedWorkspace = workspace
            return workspace
        } catch {
            blockWrites(for: workspaceURL, error: error)
            return .empty
        }
    }

    @discardableResult
    private func saveWorkspace(_ workspace: WorkspaceArchive) -> Bool {
        guard canWrite(workspaceURL) else { return false }
        let persistedWorkspace = persistedProjection(of: workspace)
        if cachedPersistedWorkspace == persistedWorkspace {
            cachedWorkspace = workspace
            return true
        }
        guard write(persistedWorkspace, to: workspaceURL, label: "workspace") else {
            return false
        }
        cachedWorkspace = workspace
        cachedPersistedWorkspace = persistedWorkspace
        return true
    }

    private func persistedProjection(of workspace: WorkspaceArchive) -> WorkspaceArchive {
        var persistedWorkspace = workspace
        persistedWorkspace.assignments.removeAll { $0.retention == .session }
        var reducer = WindowHistoryReducer(state: persistedWorkspace.history)
        reducer.prune(validAssignmentIDs: Set(persistedWorkspace.assignments.map(\.id)))
        persistedWorkspace.history = reducer.state
        return persistedWorkspace
    }

    func loadRestoreHistory(forceReload: Bool = false) -> [RestoreRecord] {
        if !forceReload, let cachedRestoreHistory {
            return cachedRestoreHistory
        }
        guard fileManager.fileExists(atPath: restoreHistoryURL.path) else { return [] }
        do {
            let archive: RestoreHistoryArchive = try read(restoreHistoryURL, version: 2)
            let records = archive.records
            cachedRestoreHistory = records
            return records
        } catch {
            blockWrites(for: restoreHistoryURL, error: error)
            Self.logger.error("Could not load restore history: \(error.localizedDescription, privacy: .public)")
            cachedRestoreHistory = nil
            return []
        }
    }

    func appendRestoreRecord(_ record: RestoreRecord) {
        var records = loadRestoreHistory()
        records.insert(record, at: 0)
        saveRestoreHistory(Array(records.prefix(20)))
    }

    private func saveRestoreHistory(_ records: [RestoreRecord]) {
        if write(
            RestoreHistoryArchive(schemaVersion: 2, records: records),
            to: restoreHistoryURL,
            label: "restore history"
        ) {
            cachedRestoreHistory = records
        }
    }

    private struct Version: Decodable { var schemaVersion: Int }
    private enum ReadError: Error { case unsupportedVersion }

    private func read<Value: Decodable>(_ url: URL, version: Int) throws -> Value {
        let data = try Data(contentsOf: url)
        guard try decoder.decode(Version.self, from: data).schemaVersion == version else {
            throw ReadError.unsupportedVersion
        }
        return try decoder.decode(Value.self, from: data)
    }

    private func blockWrites(for url: URL, error: Error) {
        backupInvalidIfNeeded(url)
        readOnlyReason = "Zonal could not open \(url.lastPathComponent): the data is invalid or uses an unsupported format. Your files were preserved. Restore a compatible backup or use the matching app version, then restart Zonal."
        configurationSaveError = readOnlyReason
    }

    private func canWrite(_ url: URL) -> Bool {
        guard readOnlyReason == nil else { return false }
        guard fileManager.fileExists(atPath: url.path) else { return true }
        let expected = url == configURL ? 5 : url == workspaceURL ? 3 : url == restoreHistoryURL ? 2 : 1
        do {
            let _: Version = try read(url, version: expected)
            return true
        } catch {
            // Ordinary filesystem errors remain retryable; malformed or unsupported data does not.
            if error is DecodingError || error is ReadError { blockWrites(for: url, error: error) }
            return false
        }
    }

    private func backupInvalidIfNeeded(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backupURL = url.appendingPathExtension("invalid-backup")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        do {
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
            Self.logger.error("Could not back up invalid persistence data: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private func write<Value: Encodable>(_ value: Value, to url: URL, label: String) -> Bool {
        guard canWrite(url) else { return false }
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Self.logger.error("Could not save \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

struct ConfigurationRuntimePolicy {
    func requiresWorkspaceReconciliation(previous: ZonalConfiguration?, current: ZonalConfiguration) -> Bool {
        guard let previous else { return true }
        return previous.tabEdge != current.tabEdge
            || previous.tabShowsNames != current.tabShowsNames
            || previous.overlappingZoneTabs != current.overlappingZoneTabs
            || previous.activeProfileID != current.activeProfileID
            || previous.excludedBundleIdentifiers != current.excludedBundleIdentifiers
            || previous.windowDefaultZoneRules != current.windowDefaultZoneRules
            || runtimeProfiles(previous.profiles) != runtimeProfiles(current.profiles)
    }

    private func runtimeProfiles(_ profiles: [DisplayProfile]) -> [DisplayProfile] {
        profiles.map { profile in
            var runtime = profile
            runtime.name = ""
            for index in runtime.zones.indices { runtime.zones[index].name = "" }
            for index in runtime.displayRoles.indices {
                runtime.displayRoles[index].name = ""
                runtime.displayRoles[index].descriptor.name = ""
            }
            for index in runtime.setupBindings.indices {
                runtime.setupBindings[index].name = ""
                for displayIndex in runtime.setupBindings[index].displays.indices {
                    runtime.setupBindings[index].displays[displayIndex].name = ""
                }
            }
            return runtime
        }
    }
}

// Cleanup waits for the configuration commit and survives a failed save/retry.
struct PendingConfigurationOperations {
    private var operations: [() -> Bool] = []

    mutating func append(_ operation: @escaping () -> Bool) { operations.append(operation) }

    mutating func finish(configurationSaved: Bool) -> Bool {
        guard configurationSaved else { return false }
        while let operation = operations.first {
            guard operation() else { return false }
            operations.removeFirst()
        }
        return true
    }
}

// Validate decoded values before runtime dictionaries or window commands see them.
enum PersistenceValidation {
    enum Invalid: Error { case identifiers, geometry, references, version }

    static func unique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else { throw Invalid.identifiers }
    }

    static func frame(_ frame: NormalizedFrame) throws {
        guard [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { throw Invalid.geometry }
    }

    static func configuration(_ value: ZonalConfiguration) throws {
        guard value.schemaVersion == 5 else { throw Invalid.version }
        guard !value.profiles.isEmpty else { throw Invalid.identifiers }
        try unique(value.profiles.map(\.id))
        try unique(value.hotkeys.map(\.id))
        for profile in value.profiles {
            guard profile.zoneSpacing.isFinite, DisplayProfile.zoneSpacingRange.contains(profile.zoneSpacing) else { throw Invalid.references }
            guard !profile.id.isEmpty, !profile.zones.isEmpty else { throw Invalid.identifiers }
            try unique(profile.zones.map(\.id))
            try unique(profile.displayRoles.map(\.id))
            try unique(profile.setupBindings.map(\.id))
            guard profile.zones.contains(where: { $0.id == profile.mainZoneID }) else { throw Invalid.references }
            for zone in profile.zones {
                guard !zone.id.rawValue.isEmpty else { throw Invalid.identifiers }
                try frame(zone.frame)
            }
            for binding in profile.setupBindings { try unique(binding.displays.map(\.persistentID)) }
        }
        if let active = value.activeProfileID,
           !value.profiles.contains(where: { $0.id == active }) { throw Invalid.references }
    }

    static func workspace(_ value: PersistenceStore.WorkspaceArchive) throws {
        guard value.schemaVersion == 3, value.history.schemaVersion == 2 else { throw Invalid.version }
        try unique(value.assignments.map(\.id))
        try unique(value.history.globalRecency)
        for ids in value.history.assignmentRecencyByZone.values { try unique(ids) }
        let ids = Set(value.assignments.map(\.id))
        let referenced = value.history.globalRecency + value.history.assignmentRecencyByZone.values.flatMap { $0 }
            + Array(value.history.activeAssignmentByZone.values)
        guard referenced.allSatisfy(ids.contains) else { throw Invalid.references }
        for assignment in value.assignments {
            for placement in assignment.placementsByProfileID.values {
                if case .custom(_, _, let normalized) = placement { try frame(normalized) }
            }
            for saved in assignment.savedCustomPlacementsByProfileID.values {
                guard [saved.size.width, saved.size.height, saved.relativePosition.x, saved.relativePosition.y].allSatisfy(\.isFinite),
                      saved.size.width > 0, saved.size.height > 0 else { throw Invalid.geometry }
            }
        }
    }
}
