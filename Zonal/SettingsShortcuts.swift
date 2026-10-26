import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var shortcutsSection: some View {
        Panel(maxHeight: false) {
            HStack {
                Text("Shortcuts")
                    .font(.headline)
                Spacer()
                Button(action: addHotkey) {
                    Label("Add Shortcut", systemImage: "plus")
                }
            }

            if !hotkeyConflicts.isEmpty {
                Label(
                    "Resolve duplicate shortcuts: \(hotkeyConflicts.joined(separator: ", "))",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                ForEach(configuration.hotkeys.indices, id: \.self) { hotkeyIndex in
                    ShortcutExpandableRow(
                        title: hotkeyTitle(configuration.hotkeys[hotkeyIndex].command),
                        shortcut: hotkeyShortcut(configuration.hotkeys[hotkeyIndex]),
                        isSelected: configuration.hotkeys[hotkeyIndex].id == selectedHotkeyID,
                        isEnabled: hotkeyBinding(hotkeyIndex, \.isEnabled),
                        command: hotkeyCommandKindBinding(hotkeyIndex),
                        zone: hotkeyZoneBinding(hotkeyIndex),
                        needsZone: selectedHotkeyNeedsZone(hotkeyIndex),
                        direction: hotkeyDirectionBinding(hotkeyIndex),
                        needsDirection: selectedHotkeyNeedsDirection(hotkeyIndex),
                        zones: zoneCatalog,
                        modifiers: configuration.hotkeys[hotkeyIndex].modifiers,
                        key: HotkeyKey(keyCode: configuration.hotkeys[hotkeyIndex].keyCode, label: configuration.hotkeys[hotkeyIndex].keyLabel),
                        recordShortcut: { modifiers, key in
                            configuration.hotkeys[hotkeyIndex].modifiers = modifiers
                            configuration.hotkeys[hotkeyIndex].keyCode = key.keyCode
                            configuration.hotkeys[hotkeyIndex].keyLabel = key.label
                            persist()
                        },
                        selectAction: { selectedHotkeyID = configuration.hotkeys[hotkeyIndex].id },
                        deleteAction: {
                            selectedHotkeyID = configuration.hotkeys[hotkeyIndex].id
                            deleteSelectedHotkey()
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }


}
