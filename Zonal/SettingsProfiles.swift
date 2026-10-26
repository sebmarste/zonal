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
                            displayBindingSummary: displayBindingSummary(profile),
                            canDelete: configuration.profiles.count > 1,
                            selectAction: { selectedProfileID = profile.id },
                            moveBefore: { movingProfileID in moveProfile(movingProfileID, before: profile.id) },
                            draggedProfileID: $draggedProfileID,
                            bindDisplaysAction: {
                                beginDisplayCapture(profileID: profile.id)
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
