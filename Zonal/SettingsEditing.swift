import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var selectedProfileIndex: Int? {
        configuration.profiles.firstIndex { $0.id == selectedProfileID }
    }

    var selectedProfile: DisplayProfile? {
        guard let selectedProfileIndex else { return nil }
        return configuration.profiles[selectedProfileIndex]
    }

    var selectedHotkeyIndex: Int? {
        configuration.hotkeys.firstIndex { $0.id == selectedHotkeyID }
    }

    var hotkeyConflicts: [String] {
        let enabled = configuration.hotkeys.filter(\.isEnabled)
        let grouped = Dictionary(grouping: enabled) { hotkey in
            "\(hotkey.modifiers.displayString) + \(hotkey.keyLabel)"
        }
        return grouped.filter { $0.value.count > 1 }.map(\.key).sorted()
    }

    var zoneCatalog: [Zone] {
        guard let source = configuration.profiles.first else { return [] }
        return source.zones
    }

    var globalMainZoneID: ZoneID? {
        configuration.profiles.first?.mainZoneID
    }

    func profileBinding(_ profileIndex: Int) -> Binding<DisplayProfile> {
        Binding(
            get: { configuration.profiles[profileIndex] },
            set: { profile in configuration.profiles[profileIndex] = profile }
        )
    }

    func profileNameBinding(profileID: String) -> Binding<String> {
        Binding(
            get: { configuration.profiles.first { $0.id == profileID }?.name ?? "" },
            set: { newName in
                guard let profileIndex = configuration.profiles.firstIndex(where: { $0.id == profileID }) else { return }
                configuration.profiles[profileIndex].name = newName
                schedulePersistence()
            }
        )
    }

    func zoneNameBinding(zoneID: ZoneID) -> Binding<String> {
        Binding(
            get: { zoneCatalog.first { $0.id == zoneID }?.name ?? "" },
            set: { newName in
                for profileIndex in configuration.profiles.indices {
                    guard let zoneIndex = configuration.profiles[profileIndex].zones.firstIndex(where: { $0.id == zoneID }) else { continue }
                    configuration.profiles[profileIndex].zones[zoneIndex].name = newName
                }
                schedulePersistence()
            }
        )
    }

    func mainZoneBinding(zoneID: ZoneID) -> Binding<Bool> {
        Binding(
            get: { globalMainZoneID == zoneID },
            set: { isSelected in
                guard isSelected else { return }
                setGlobalMainZone(zoneID)
            }
        )
    }

    func zonePresentationBinding(zoneID: ZoneID) -> Binding<ZonePresentationOption> {
        Binding(
            get: { zoneCatalog.first { $0.id == zoneID }.map(ZonePresentationOption.init) ?? .overlap },
            set: { option in
                for profileIndex in configuration.profiles.indices {
                    guard let zoneIndex = configuration.profiles[profileIndex].zones.firstIndex(where: {
                        $0.id == zoneID
                    }) else { continue }
                    option.apply(to: &configuration.profiles[profileIndex].zones[zoneIndex])
                }
                persist()
            }
        )
    }

    func zoneOptionBinding<Value>(zoneID: ZoneID, keyPath: WritableKeyPath<Zone, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: {
                zoneCatalog.first { $0.id == zoneID }?[keyPath: keyPath] ?? fallback
            },
            set: { presentation in
                for profileIndex in configuration.profiles.indices {
                    guard let zoneIndex = configuration.profiles[profileIndex].zones.firstIndex(where: {
                        $0.id == zoneID
                    }) else { continue }
                    configuration.profiles[profileIndex].zones[zoneIndex][keyPath: keyPath] = presentation
                }
                persist()
            }
        )
    }

    func hotkeyBinding<Value>(_ hotkeyIndex: Int, _ keyPath: WritableKeyPath<HotkeyBinding, Value>) -> Binding<Value> {
        Binding(
            get: { configuration.hotkeys[hotkeyIndex][keyPath: keyPath] },
            set: {
                configuration.hotkeys[hotkeyIndex][keyPath: keyPath] = $0
                persist()
            }
        )
    }

    func hotkeyCommandKindBinding(_ hotkeyIndex: Int) -> Binding<HotkeyCommandKind> {
        Binding(
            get: { HotkeyCommandKind(command: configuration.hotkeys[hotkeyIndex].command) },
            set: { kind in
                let existingZone = hotkeyZone(for: configuration.hotkeys[hotkeyIndex].command) ?? selectedZoneID ?? zoneCatalog.first?.id ?? .main
                configuration.hotkeys[hotkeyIndex].command = kind.command(zoneID: existingZone)
                persist()
            }
        )
    }

    func hotkeyZoneBinding(_ hotkeyIndex: Int) -> Binding<ZoneID> {
        Binding(
            get: { hotkeyZone(for: configuration.hotkeys[hotkeyIndex].command) ?? selectedZoneID ?? zoneCatalog.first?.id ?? .main },
            set: { zoneID in
                switch configuration.hotkeys[hotkeyIndex].command {
                case .focusZone:
                    configuration.hotkeys[hotkeyIndex].command = .focusZone(zoneID)
                case .moveFocusedWindow:
                    configuration.hotkeys[hotkeyIndex].command = .moveFocusedWindow(zoneID)
                default:
                    break
                }
                persist()
            }
        )
    }

    func selectedHotkeyNeedsZone(_ hotkeyIndex: Int) -> Bool {
        hotkeyZone(for: configuration.hotkeys[hotkeyIndex].command) != nil
    }

    func selectedHotkeyNeedsDirection(_ hotkeyIndex: Int) -> Bool {
        if case .moveFocusedWindowRelative = configuration.hotkeys[hotkeyIndex].command {
            return true
        }
        return false
    }

    func hotkeyDirectionBinding(_ hotkeyIndex: Int) -> Binding<SwitcherArrowKey> {
        Binding(
            get: {
                if case .moveFocusedWindowRelative(let direction) = configuration.hotkeys[hotkeyIndex].command {
                    return direction
                }
                return .right
            },
            set: { direction in
                configuration.hotkeys[hotkeyIndex].command = .moveFocusedWindowRelative(direction)
                persist()
            }
        )
    }

    func hotkeyZone(for command: HotkeyCommand) -> ZoneID? {
        switch command {
        case .focusZone(let zoneID), .moveFocusedWindow(let zoneID):
            return zoneID
        default:
            return nil
        }
    }

    func hotkeyTitle(_ command: HotkeyCommand) -> String {
        switch command {
        case .focusZone(let zoneID):
            return "Focus \(zoneName(zoneID))"
        case .moveFocusedWindow(let zoneID):
            return "Move to \(zoneName(zoneID))"
        case .moveFocusedWindowRelative(let direction):
            return "Move \(direction.title)"
        default:
            return command.title
        }
    }

    func zoneName(_ zoneID: ZoneID) -> String {
        ZoneNameResolver().name(for: zoneID, in: zoneCatalog)
    }

    func hotkeyShortcut(_ hotkey: HotkeyBinding) -> String {
        "\(hotkey.modifiers.displayString) + \(hotkey.keyLabel)"
    }

    func displayBindingSummary(_ profile: DisplayProfile) -> String {
        profile.setupBindings.isEmpty ? "No captured display setup" : profile.setupBindings.map(\.name).joined(separator: ", ")
    }

    func reload() {
        // Reopening Settings must retain edits when an earlier write failed.
        guard configurationSaveError == nil else { return }
        configuration = store.loadConfiguration()
        sanitizeConfiguration()
        baselineConfiguration = configuration
        selectedProfileID = existingProfileID(configuration.activeProfileID) ?? configuration.profiles.first?.id
        selectedHotkeyID = configuration.hotkeys.first?.id
        syncSelectedZoneToSelectedProfile()
    }

    func schedulePersistence() {
        onPendingEditsChanged(true)
        pendingConfigurationWrite?.cancel()
        let work = DispatchWorkItem { persist() }
        pendingConfigurationWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func flushPendingConfiguration() {
        guard pendingConfigurationWrite != nil || configurationSaveError != nil else { return }
        persist()
    }

    @discardableResult
    func persist() -> Bool {
        defer { onPendingEditsChanged(configurationSaveError != nil || pendingConfigurationWrite != nil) }
        pendingConfigurationWrite?.cancel()
        pendingConfigurationWrite = nil
        sanitizeConfiguration()
        let previous = store.loadConfiguration()
        let merged = store.mergedConfiguration(draft: configuration, baseline: baselineConfiguration)
        guard store.saveConfiguration(merged) else {
            configurationSaveError = store.configurationSaveError
            return false
        }
        guard pendingConfigurationOperations.finish(configurationSaved: true) else {
            if configurationBeforePendingCleanup == nil { configurationBeforePendingCleanup = previous }
            configurationSaveError = "Settings were saved, but window history could not be updated. Retry to finish the change."
            return false
        }
        configurationSaveError = nil
        configuration = merged
        baselineConfiguration = merged
        profileManager.reloadProfiles()
        appContainer.configurationDidChange(previous: configurationBeforePendingCleanup ?? previous)
        configurationBeforePendingCleanup = nil
        syncSelectedZoneToSelectedProfile()
        return true
    }

    func addProfile() {
        let id = uniqueProfileID(base: "profile")
        let sourceZones = zoneCatalog.isEmpty ? [Zone(id: .main, name: "Main", frame: .full)] : zoneCatalog
        let profile = DisplayProfile(
            id: id,
            name: "Profile \(configuration.profiles.count + 1)",
            mainZoneID: globalMainZoneID ?? sourceZones.first?.id ?? .main,
            zones: sourceZones.map {
                Zone(
                    id: $0.id,
                    name: $0.name,
                    frame: .full,
                    windowPresentation: $0.windowPresentation,
                    peekWidth: $0.peekWidth,
                    peekDirection: $0.peekDirection,
                    tabStyle: $0.tabStyle,
                    tabBorderWidth: $0.tabBorderWidth
                )
            }
        )
        configuration.profiles.append(profile)
        selectedProfileID = id
        selectedZoneID = profile.mainZoneID
        persist()
    }

    func completeSetup(
        _ template: WorkspaceTemplate,
        replaceCommandTab: Bool,
        launchAtLogin: Bool
    ) {
        let snapshot = profileManager.currentSnapshot()
        let roles = profileManager.roles(for: snapshot)
        let primaryPersistentID = snapshot.primaryDisplay.map {
            $0.persistentID.isEmpty ? "display-\($0.id)" : $0.persistentID
        }
        let primaryRoleID = roles.first { $0.descriptor.persistentID == primaryPersistentID }?.id
            ?? roles.first?.id
            ?? .workspace
        let zones = template.zones.map { zone in
            Zone(
                id: zone.id,
                name: zone.name,
                frame: zone.frame,
                displayRoleID: primaryRoleID
            )
        }
        let profileName: String
        if snapshot.hasUltrawide {
            profileName = "Ultrawide"
        } else if snapshot.displays.count == 1, snapshot.displays.first?.isBuiltIn == true {
            profileName = "Laptop"
        } else {
            profileName = "Current Setup"
        }
        let profile = DisplayProfile(
            id: "main",
            name: profileName,
            mainZoneID: template.mainZoneID,
            setupBindings: [
                profileManager.setupBinding(
                    for: snapshot,
                    name: profileManager.setupName(for: snapshot)
                )
            ],
            displayRoles: roles,
            zones: zones
        )
        configuration.setupVersion = 1
        configuration.activeProfileID = profile.id
        configuration.profiles = [profile]
        configuration.useNativeCommandTab = !replaceCommandTab
        selectedProfileID = profile.id
        selectedZoneID = profile.mainZoneID
        guard persist() else { return }
        showSetupAssistant = false
        appContainer.setLaunchAtLoginEnabled(launchAtLogin)
        appContainer.applyProfileNow(profile.id)
    }

    func addZone() {
        let zoneID = uniqueZoneID(base: "zone")
        let zone = Zone(id: zoneID, name: "Zone \(zoneCatalog.count + 1)", frame: .full)
        for profileIndex in configuration.profiles.indices {
            configuration.profiles[profileIndex].zones.append(zone)
        }
        selectedZoneID = zoneID
        persist()
    }

    func deleteProfile(_ profileID: String) {
        guard configuration.profiles.count > 1,
              let profileIndex = configuration.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        configuration.profiles.remove(at: profileIndex)
        pendingConfigurationOperations.append {
            guard !store.loadConfiguration().profiles.contains(where: { $0.id == profileID }) else { return true }
            return store.removePlacementState(forProfileID: profileID)
        }
        if configuration.activeProfileID == profileID {
            configuration.activeProfileID = configuration.profiles.first?.id
        }
        selectedProfileID = existingProfileID(configuration.activeProfileID) ?? configuration.profiles.first?.id
        persist()
    }

    func deleteZone(_ zoneID: ZoneID) {
        guard zoneCatalog.count > 1 else { return }
        for profileIndex in configuration.profiles.indices {
            configuration.profiles[profileIndex].zones.removeAll { $0.id == zoneID }
            if configuration.profiles[profileIndex].mainZoneID == zoneID {
                configuration.profiles[profileIndex].mainZoneID = configuration.profiles[profileIndex].zones.first?.id ?? .main
            }
        }
        configuration.hotkeys.removeAll {
            switch $0.command {
            case .focusZone(zoneID), .moveFocusedWindow(zoneID):
                return true
            default:
                return false
            }
        }
        pendingConfigurationOperations.append {
            let saved = store.loadConfiguration()
            guard !saved.profiles.flatMap(\.zones).contains(where: { $0.id == zoneID }) else { return true }
            let fallbackZoneID = saved.profiles.first?.mainZoneID ?? saved.profiles.first?.zones.first?.id ?? .main
            return store.updateWorkspace { workspace in
                var reducer = WindowHistoryReducer(state: workspace.history)
                for index in workspace.assignments.indices
                    where workspace.assignments[index].zoneID == zoneID {
                    workspace.assignments[index].zoneID = fallbackZoneID
                    for profile in saved.profiles {
                        workspace.assignments[index].placementsByProfileID[profile.id] = .zoneFit(zoneID: fallbackZoneID)
                    }
                    workspace.assignments[index].updatedAt = Date()
                    reducer.moveAssignment(workspace.assignments[index].id, from: zoneID, to: fallbackZoneID)
                }
                workspace.history = reducer.state
            }
        }
        selectedZoneID = globalMainZoneID ?? zoneCatalog.first?.id
        selectedHotkeyID = configuration.hotkeys.first?.id
        persist()
    }

    func confirmDeletion(_ deletion: SettingsDeletion) {
        switch deletion {
        case .zone(let id, _):
            deleteZone(id)
        case .profile(let id, _):
            deleteProfile(id)
        }
        pendingDeletion = nil
    }

    func beginProfileApply(_ profileID: String) {
        guard let preview = appContainer.profileTransitionPreview(profileID) else { return }
        profileApplyPreview = preview
    }

    func applyProfileConfirmed(_ profileID: String) {
        configuration.activeProfileID = profileID
        selectedProfileID = profileID
        guard persist() else { return }
        appContainer.applyProfileNow(profileID)
    }

    func setGlobalMainZone(_ zoneID: ZoneID) {
        for profileIndex in configuration.profiles.indices {
            configuration.profiles[profileIndex].mainZoneID = zoneID
        }
        selectedZoneID = zoneID
        persist()
    }

    func moveProfiles(from source: IndexSet, to destination: Int) {
        configuration.profiles.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func moveProfile(_ movingProfileID: String, before targetProfileID: String) {
        guard movingProfileID != targetProfileID,
              let sourceIndex = configuration.profiles.firstIndex(where: { $0.id == movingProfileID }),
              let targetIndex = configuration.profiles.firstIndex(where: { $0.id == targetProfileID }) else { return }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        moveProfiles(from: IndexSet(integer: sourceIndex), to: destination)
    }

    func moveZones(from source: IndexSet, to destination: Int) {
        for profileIndex in configuration.profiles.indices {
            configuration.profiles[profileIndex].zones.move(fromOffsets: source, toOffset: destination)
        }
        persist()
    }

    func moveZone(_ movingZoneID: ZoneID, before targetZoneID: ZoneID) {
        guard movingZoneID != targetZoneID,
              let sourceIndex = zoneCatalog.firstIndex(where: { $0.id == movingZoneID }),
              let targetIndex = zoneCatalog.firstIndex(where: { $0.id == targetZoneID }) else { return }
        let destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        moveZones(from: IndexSet(integer: sourceIndex), to: destination)
    }

    func beginDisplayCapture(profileID: String) {
        let snapshot = profileManager.currentSnapshot()
        captureDraft = DisplayCaptureDraft(
            profileID: profileID,
            snapshot: snapshot,
            setupName: profileManager.setupName(for: snapshot)
        )
    }

    func saveCapturedSetup(_ draft: DisplayCaptureDraft, apply: Bool) {
        guard let profileIndex = configuration.profiles.firstIndex(where: { $0.id == draft.profileID }) else { return }
        let snapshot = draft.snapshot
        configuration.profiles[profileIndex].setupBindings.removeAll { binding in
            Set(binding.displays.map(\.persistentID)) == Set(snapshot.displays.map { $0.descriptor.persistentID })
        }
        configuration.profiles[profileIndex].setupBindings.append(
            profileManager.setupBinding(
                for: snapshot,
                name: draft.setupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? profileManager.setupName(for: snapshot)
                    : draft.setupName
            )
        )
        configuration.profiles[profileIndex].displayRoles = profileManager.roles(for: snapshot)
        let defaultRoleID = configuration.profiles[profileIndex].displayRoles.first?.id ?? .workspace
        for zoneIndex in configuration.profiles[profileIndex].zones.indices
            where configuration.profiles[profileIndex].zones[zoneIndex].displayRoleID == nil {
            configuration.profiles[profileIndex].zones[zoneIndex].displayRoleID = defaultRoleID
        }
        if apply {
            configuration.activeProfileID = configuration.profiles[profileIndex].id
        }
        guard persist() else { return }
        if apply {
            appContainer.applyProfileNow(configuration.profiles[profileIndex].id)
        }
    }

    func addHotkey() {
        let zoneID = selectedZoneID ?? zoneCatalog.first?.id ?? .main
        let hotkey = HotkeyBinding(command: .focusZone(zoneID), keyCode: 49, keyLabel: "Space", modifiers: .controlOption)
        configuration.hotkeys.append(hotkey)
        selectedHotkeyID = hotkey.id
        persist()
    }

    func deleteSelectedHotkey() {
        guard let hotkeyIndex = selectedHotkeyIndex else { return }
        configuration.hotkeys.remove(at: hotkeyIndex)
        selectedHotkeyID = configuration.hotkeys.first?.id
        persist()
    }

    func syncSelectedZoneToSelectedProfile() {
        ConfigurationEditor().ensureEveryProfileContainsEveryZone(&configuration)
        guard let profileIndex = selectedProfileIndex else {
            selectedZoneID = nil
            return
        }
        let profile = configuration.profiles[profileIndex]
        if let selectedZoneID, profile.zones.contains(where: { $0.id == selectedZoneID }) {
            return
        }
        selectedZoneID = profile.zones.first { $0.id == profile.mainZoneID }?.id ?? profile.zones.first?.id
    }

    func sanitizeConfiguration() {
        configuration = ConfigurationEditor().sanitized(configuration)
    }

    func existingProfileID(_ profileID: String?) -> String? {
        guard let profileID,
              configuration.profiles.contains(where: { $0.id == profileID }) else {
            return nil
        }
        return profileID
    }

    func uniqueProfileID(base: String, excluding excludedIDs: Set<String> = []) -> String {
        let existingIDs = Set(configuration.profiles.map(\.id)).union(excludedIDs)
        var index = configuration.profiles.count + 1
        var candidate = "\(base)-\(index)"
        while existingIDs.contains(candidate) {
            index += 1
            candidate = "\(base)-\(index)"
        }
        return candidate
    }

    func uniqueZoneID(base: String, excluding excludedIDs: Set<ZoneID> = []) -> ZoneID {
        let existingIDs = Set(zoneCatalog.map(\.id)).union(excludedIDs)
        var index = zoneCatalog.count + 1
        var candidate = ZoneID(rawValue: "\(base)-\(index)")
        while existingIDs.contains(candidate) {
            index += 1
            candidate = ZoneID(rawValue: "\(base)-\(index)")
        }
        return candidate
    }
}
