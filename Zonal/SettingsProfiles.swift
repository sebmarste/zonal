import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var zonesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(zoneCatalog) { zone in
                ZoneCard(
                    zoneID: zone.id,
                    name: zoneNameBinding(zoneID: zone.id),
                    isMain: mainZoneBinding(zoneID: zone.id),
                    presentation: zonePresentationBinding(zoneID: zone.id),
                    peekWidth: zoneOptionBinding(zoneID: zone.id, keyPath: \.peekWidth, fallback: 48),
                    peekDirection: zoneOptionBinding(zoneID: zone.id, keyPath: \.peekDirection, fallback: .left),
                    tabBorderWidth: zoneOptionBinding(zoneID: zone.id, keyPath: \.tabBorderWidth, fallback: ZoneTabMetrics.defaultBorderWidth),
                    canDelete: zoneCatalog.count > 1,
                    select: { selectedZoneID = zone.id },
                    moveBefore: { movingZoneID in moveZone(movingZoneID, before: zone.id) },
                    draggedZoneID: $draggedZoneID,
                    deleteAction: {
                        pendingDeletion = .zone(id: zone.id, name: zone.name)
                    }
                )
            }

            Button(action: addZone) {
                Label("Add Zone", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
    }

    var profilesSection: some View {
        let runtimeSnapshot = profileManager.currentSnapshot()
        let matchedProfileID = profileManager.matchedProfile(for: runtimeSnapshot)?.id
        return VStack(alignment: .leading, spacing: 12) {
            Panel(maxHeight: false) {
                HStack {
                    Text("Profiles")
                        .font(.headline)
                    Spacer()
                    Button(action: addProfile) {
                        Label("Add Profile", systemImage: "plus")
                    }
                }

                VStack(spacing: 6) {
                    ForEach(configuration.profiles) { profile in
                        ProfileListRow(
                            profileID: profile.id,
                            name: profileNameBinding(profileID: profile.id),
                            isSelected: profile.id == selectedProfileID,
                            isMatched: profile.id == matchedProfileID,
                            isLastApplied: profile.id == configuration.activeProfileID,
                            displaySetups: profile.setupBindings,
                            canDelete: configuration.profiles.count > 1,
                            selectAction: { selectedProfileID = profile.id },
                            moveBefore: { movingProfileID in moveProfile(movingProfileID, before: profile.id) },
                            draggedProfileID: $draggedProfileID,
                            bindDisplaysAction: {
                                beginDisplayCapture(profileID: profile.id)
                            },
                            removeSetupAction: { setup in
                                pendingDeletion = .displaySetup(profileID: profile.id, profileName: profile.name,
                                                                setupID: setup.id, setupName: setup.name)
                            },
                            activateAction: { beginProfileApply(profile.id) },
                            deleteAction: {
                                pendingDeletion = .profile(id: profile.id, name: profile.name)
                            }
                        )
                    }
                }

                Divider()
                HStack(spacing: 14) {
                    Label(
                        "Editing: \(selectedProfile?.name ?? "None")",
                        systemImage: "pencil"
                    )
                    Spacer()
                    Label(
                        "Current profile: \(profileManager.matchedProfile(for: runtimeSnapshot)?.name ?? "No match")",
                        systemImage: "display"
                    )
                    .foregroundStyle(matchedProfileID == nil ? .orange : .secondary)
                }
                .font(.caption)
            }

            if let profileIndex = selectedProfileIndex {
                profileAppearanceSection(profileIndex)
            }

            Panel(padding: 0) {
                if let profileIndex = selectedProfileIndex {
                    ProfileLayoutEditor(
                        profile: profileBinding(profileIndex),
                        selectedZoneID: $selectedZoneID,
                        mainZoneID: configuration.profiles[profileIndex].mainZoneID,
                        commit: { persist() }
                    )
                } else {
                    ContentUnavailableView("No Profile", systemImage: "display", description: Text("Create a profile to place zones."))
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .frame(minHeight: 500)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


}

extension SettingsView {
    func profileTabBinding<Value>(_ index: Int, _ keyPath: WritableKeyPath<ProfileTabAppearance, Value>) -> Binding<Value> {
        Binding(get: { configuration.tabAppearance(for: configuration.profiles[index])[keyPath: keyPath] },
            set: { value in
                var appearance = configuration.tabAppearance(for: configuration.profiles[index])
                appearance[keyPath: keyPath] = value
                configuration.profiles[index].tabAppearance = appearance
                persist()
            })
    }

    func profileAppearanceSection(_ index: Int) -> some View {
        Panel(maxHeight: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance · \(configuration.profiles[index].name)").font(.headline)
                Text("These settings belong to the profile being edited. Applying the profile restores its spacing and tab appearance.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Zone spacing")
                    Slider(value: $configuration.profiles[index].zoneSpacing, in: DisplayProfile.zoneSpacingRange, step: 1,
                        onEditingChanged: { editing in if !editing { persist() } })
                        .accessibilityLabel("Zone spacing")
                    TextField("Points", value: Binding(get: { configuration.profiles[index].zoneSpacing }, set: { value in
                        guard value.isFinite else { return }
                        configuration.profiles[index].zoneSpacing = min(DisplayProfile.zoneSpacingRange.upperBound, max(0, value.rounded()))
                        persist()
                    }), format: .number).frame(width: 44)
                    Text("pt").foregroundStyle(.secondary)
                }
                Text("Space between fitted zones and around the display. Custom-sized windows retain their saved positions.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("Tab edge", selection: profileTabBinding(index, \.edge)) {
                    ForEach(ZoneTabEdge.allCases) { Text($0.title).tag($0) }
                }
                Picker("Tab labels", selection: profileTabBinding(index, \.showsNames)) {
                    Text("Icons and full names").tag(true)
                    Text("Icons only").tag(false)
                }
                Picker("Overlapping zone tabs", selection: profileTabBinding(index, \.overlappingTabs)) {
                    ForEach(OverlappingZoneTabs.allCases) { Text($0.title).tag($0) }
                }
                Text("For zones with identical frames on the same display. All windows combines their most-recent-first history.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show clock in main stack tab bar", isOn: profileTabBinding(index, \.showsClock))
                Text("Requires Tabs presentation. The clock stays with the main zone’s shared tab bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("System controls in main stack", isOn: profileSystemControlBinding(index, \.isEnabled))
                Text("Uses the clock area of the main zone’s tab strip. Each profile has its own controls; narrow strips collect them in a menu.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(SystemControlItem.allCases) { item in
                    Toggle(item.title, isOn: Binding(get: {
                        configuration.tabAppearance(for: configuration.profiles[index]).systemControls?.items.contains(item) ?? true
                    }, set: { selected in
                        var appearance = configuration.tabAppearance(for: configuration.profiles[index])
                        var controls = appearance.systemControls ?? SystemControlSettings()
                        controls.items.removeAll { $0 == item }
                        if selected { controls.items.append(item) }
                        appearance.systemControls = controls
                        configuration.profiles[index].tabAppearance = appearance
                        persist()
                    }))
                    .disabled(!(configuration.tabAppearance(for: configuration.profiles[index]).systemControls?.isEnabled ?? false))
                }
                Text("Right-click blank tab-strip space or a zone icon for the Zonal menu and native menu bar access. Use Control–F2 (or Fn–Control–F2) directly. Configure auto-hide in macOS System Settings; switching profiles does not change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func profileSystemControlBinding(_ index: Int, _ keyPath: WritableKeyPath<SystemControlSettings, Bool>) -> Binding<Bool> {
        Binding(get: {
            (configuration.tabAppearance(for: configuration.profiles[index]).systemControls ?? SystemControlSettings())[keyPath: keyPath]
        }, set: { value in
            var appearance = configuration.tabAppearance(for: configuration.profiles[index])
            var controls = appearance.systemControls ?? SystemControlSettings()
            controls[keyPath: keyPath] = value
            appearance.systemControls = controls
            configuration.profiles[index].tabAppearance = appearance
            persist()
        })
    }
}
