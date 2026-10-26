import AppKit
import Darwin
import OSLog
import SwiftUI

extension AppContainer {
    func startLocalAutomation() {
        guard automationServer == nil else { return }
        let server = LocalAutomationSocketServer { [weak self] request, reply in
            guard let self else { return }
            reply(self.response(to: request))
        }
        do {
            try server.start()
            automationServer = server
        } catch {
            Self.logger.error("Could not start local automation: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopLocalAutomation() {
        automationServer?.stop()
        automationServer = nil
    }

    private struct AutomationOutcome {
        var ok: Bool
        var message: String
        var result: LocalAutomationResult?
        var errorCode: String?
    }

    private func response(to request: LocalAutomationRequest) -> LocalAutomationResponse {
        let outcome = performAutomationCommand(request.command, arguments: request.arguments)
        return LocalAutomationResponse(
            apiVersion: LocalAutomationProtocol.currentVersion,
            requestID: request.id,
            command: request.command,
            ok: outcome.ok,
            message: outcome.message,
            result: outcome.result,
            error: outcome.errorCode.map {
                LocalAutomationError(code: $0, message: outcome.message)
            }
        )
    }

    private func performAutomationCommand(
        _ command: String,
        arguments: [String]
    ) -> AutomationOutcome {
        switch LocalAutomationCommand(name: command, arguments: arguments) {
        case .read(let kind):
            return success("\(kind.rawValue.capitalized) read", result: automationReadResult(kind))
        case .diagnostics:
            return success(
                "Diagnostics read",
                result: LocalAutomationResult(
                    state: .read,
                    diagnostics: privacySafeDiagnostics()
                )
            )
        case .doctor:
            return success(
                "Health check complete",
                result: LocalAutomationResult(
                    state: .read,
                    healthFindings: runHealthCheck()
                )
            )
        case .switcherMetrics:
            return success(
                "Switcher metrics read",
                result: LocalAutomationResult(
                    state: .read,
                    switcherMetrics: switcher.performanceSamples()
                )
            )
        case .resetSwitcherMetrics:
            switcher.clearPerformanceSamples()
            return success("Switcher metrics reset", state: .completed)
        case .openSettings:
            openSettings()
            return success("Settings opened", state: .completed)
        case .showGlobal:
            switcher.show(mode: .allWindows)
            return success("All Windows switcher shown", state: .completed)
        case .showZone:
            switcher.show(mode: .byZone)
            return success("By Zone switcher shown", state: .completed)
        case .next:
            guard switcher.isVisible else { return failure("switcher_not_visible", "Switcher is not visible") }
            switcher.next()
            return success("Selected next window", state: .completed)
        case .previous:
            guard switcher.isVisible else { return failure("switcher_not_visible", "Switcher is not visible") }
            switcher.previous()
            return success("Selected previous window", state: .completed)
        case .confirm:
            guard switcher.isVisible else { return failure("switcher_not_visible", "Switcher is not visible") }
            switcher.confirm()
            return success("Switcher selection accepted", state: .accepted)
        case .cancel:
            guard switcher.isVisible else { return failure("switcher_not_visible", "Switcher is not visible") }
            switcher.cancel()
            return success("Switcher cancelled", state: .completed)
        case .restore:
            restoreNow()
            return success("Restore accepted", state: .accepted)
        case .rescan:
            rescanWindows()
            return success("Window rescan accepted", state: .accepted)
        case .applyProfile(let profileID):
            guard store.loadProfiles().contains(where: { $0.id == profileID }) else {
                return failure("unknown_profile", "Unknown profile ID")
            }
            applyProfileNow(profileID)
            return success("Profile apply accepted", state: .accepted)
        case .moveFocused(let zoneReference):
            guard let resolved = resolveZone(zoneReference) else {
                return zoneResolutionFailure(zoneReference)
            }
            guard windowRegistry.focusedWindow() != nil else {
                return failure("no_focused_window", "No managed window is focused")
            }
            restoreEngine.assignFocusedWindow(to: ZoneID(rawValue: resolved.id))
            return success(
                "Focused window move accepted",
                result: LocalAutomationResult(state: .accepted, zone: resolved)
            )
        case .moveFocusedRelative(let direction):
            guard windowRegistry.focusedWindow() != nil else {
                return failure("no_focused_window", "No managed window is focused")
            }
            guard let zoneID = restoreEngine.assignFocusedWindow(in: direction) else {
                return failure("no_neighboring_zone", "No neighboring zone in that direction")
            }
            return success(
                "Focused window move accepted",
                result: LocalAutomationResult(state: .accepted, zone: zoneReference(zoneID))
            )
        case .focusZone(let zoneReference):
            guard let resolved = resolveZone(zoneReference) else {
                return zoneResolutionFailure(zoneReference)
            }
            guard restoreEngine.focusZone(ZoneID(rawValue: resolved.id)) else {
                return failure("no_window_in_zone", "No live window is available in \(resolved.name)")
            }
            return success(
                "Zone focus accepted",
                result: LocalAutomationResult(state: .accepted, zone: resolved)
            )
        case .focusNextInZone:
            guard restoreEngine.focusNextWindowInStack(direction: 1) else {
                return failure("no_window_in_zone", "No next window is available in the current zone")
            }
            return success("Next window focus accepted", state: .accepted)
        case .focusPreviousInZone:
            guard restoreEngine.focusNextWindowInStack(direction: -1) else {
                return failure("no_window_in_zone", "No previous window is available in the current zone")
            }
            return success("Previous window focus accepted", state: .accepted)
        case .focusAssignment(let assignmentID):
            let model = workspaceState.refreshSwitcherSnapshot(mode: .allWindows, resetSelection: true)
            guard let item = model.zones.flatMap(\.items).first(where: {
                $0.assignmentID == assignmentID
            }) else {
                return failure("no_live_window", "No live window for assignment")
            }
            workspaceState.selectSwitcherItem(assignmentID: item.assignmentID, zoneID: item.zoneID)
            workspaceState.focusSelectedWindow()
            return success("Window focus accepted", state: .accepted)
        case .focusBundle(let bundleIdentifier):
            let model = workspaceState.refreshSwitcherSnapshot(mode: .allWindows, resetSelection: true)
            guard let item = model.zones.flatMap(\.items).first(where: {
                $0.identity.bundleIdentifier == bundleIdentifier
            }) else {
                return failure("no_live_window", "No managed window for bundle identifier")
            }
            workspaceState.selectSwitcherItem(assignmentID: item.assignmentID, zoneID: item.zoneID)
            workspaceState.focusSelectedWindow()
            return success("Window focus accepted", state: .accepted)
        case .focusPrevious:
            let model = workspaceState.refreshSwitcherSnapshot(mode: .allWindows, resetSelection: true)
            guard model.selectedWindowID != nil else {
                return failure("no_live_window", "No previous managed window is available")
            }
            workspaceState.focusSelectedWindow()
            return success("Previous window focus accepted", state: .accepted)
        case .invalid(let message):
            return failure("invalid_arguments", message)
        case .unknown:
            return failure("unknown_command", "Unknown automation command")
        }
    }

    private func automationReadResult(_ kind: LocalAutomationReadKind) -> LocalAutomationResult {
        let health = LocalAutomationHealth(
            accessibilityTrusted: menuSnapshot.accessibilityTrusted,
            inputMonitoringGranted: menuSnapshot.inputMonitoringGranted,
            keyboardCaptureAvailable: menuSnapshot.keyboardCaptureAvailable,
            trackingActive: menuSnapshot.trackingActive
        )
        guard kind != .health else {
            return LocalAutomationResult(state: .read, health: health)
        }
        let mode = switcher.isVisible ? switcher.mode : .allWindows
        let model = workspaceState.switcherSnapshot(mode: mode)
        let items = model.zones.flatMap(\.items)
        let configuration = store.loadConfiguration()
        let snapshot = profileManager.currentSnapshot()
        let profile = profileManager.matchedProfile(for: snapshot)
            ?? profileManager.selectedProfile(for: snapshot)
        if kind == .debugState {
            let context = workspaceState.currentProfileContext()
            let liveAssignments = context.windows.compactMap {
                workspaceState.assignment(for: $0, context: context)
            }
            let debugWindows = context.windows.map { window in
                let assignment = workspaceState.assignment(for: window, context: context)
                let desired = assignment.flatMap {
                    workspaceState.targetFrame(
                        for: $0,
                        profile: context.profile,
                        snapshot: context.snapshot,
                        stackAssignments: liveAssignments
                    )?.frame
                }
                return LocalAutomationDebugWindow(
                    id: window.id.sortKey,
                    bundleIdentifier: window.identity.bundleIdentifier,
                    assignmentID: assignment?.id.uuidString,
                    zoneID: assignment?.zoneID.rawValue,
                    observedFrame: windowController.frame(of: window).map(Self.frameArray),
                    desiredFrame: desired.map(Self.frameArray),
                    isFullScreen: windowController.isFullScreen(window),
                    isMinimized: windowController.isMinimized(window),
                    isManaged: assignment?.managementMode != .ignored,
                    isPlacementPending: windowController.isApplyingPlacement(to: window)
                )
            }
            return LocalAutomationResult(
                state: .read,
                debugState: LocalAutomationDebugState(
                    profileID: context.profile.id,
                    windows: debugWindows
                )
            )
        }
        let zones = profile.zones.map { zone in
            LocalAutomationZone(
                id: zone.id.rawValue,
                name: ZoneNameResolver().name(for: zone.id, in: profile.zones),
                windowCount: items.filter { $0.zoneID == zone.id }.count,
                isSelected: zone.id == model.selectedZoneID
            )
        }
        let windows = items.map {
            LocalAutomationWindow(
                assignmentID: $0.assignmentID.uuidString,
                bundleIdentifier: $0.identity.bundleIdentifier,
                appName: $0.appName,
                zoneID: $0.zoneID.rawValue,
                zoneName: $0.zoneName,
                isSelected: $0.identity == model.selectedWindowID,
                isActive: $0.isActive
            )
        }
        if kind == .zones {
            return LocalAutomationResult(state: .read, zones: zones)
        }
        if kind == .windows {
            return LocalAutomationResult(state: .read, windows: windows)
        }
        return LocalAutomationResult(
            state: .read,
            health: health,
            displaySetup: menuSnapshot.displaySetupName,
            matchedProfile: menuSnapshot.matchedProfileName,
            switcherVisible: switcher.isVisible,
            // Keep automation wire values stable across user-facing renames.
            mode: mode == .allWindows ? "global" : "zone",
            focusedBundleIdentifier: windowRegistry.focusedWindow()?.identity.bundleIdentifier,
            selectedBundleIdentifier: items.first(where: {
                $0.identity == model.selectedWindowID
            })?.identity.bundleIdentifier,
            profiles: configuration.profiles.map {
                LocalAutomationProfile(
                    id: $0.id,
                    name: $0.name,
                    isMatched: $0.id == profile.id,
                    isLastApplied: $0.id == configuration.activeProfileID
                )
            },
            zones: zones,
            windows: windows
        )
    }

    private static func frameArray(_ frame: CGRect) -> [Double] {
        [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)
    }

    private func resolveZone(_ reference: String) -> LocalAutomationZoneReference? {
        let profile = workspaceState.currentProfileContext().profile
        guard case .resolved(let zoneID) = ZoneReferenceResolver().resolve(
            reference,
            in: profile.zones
        ) else { return nil }
        return LocalAutomationZoneReference(
            id: zoneID.rawValue,
            name: ZoneNameResolver().name(for: zoneID, in: profile.zones)
        )
    }

    private func zoneResolutionFailure(_ reference: String) -> AutomationOutcome {
        let zones = workspaceState.currentProfileContext().profile.zones
        switch ZoneReferenceResolver().resolve(reference, in: zones) {
        case .resolved:
            return failure("unknown_zone", "Could not resolve zone")
        case .notFound:
            return failure("unknown_zone", "Unknown zone ID or name: \(reference)")
        case .ambiguous(let ids):
            return failure(
                "ambiguous_zone_name",
                "Zone name is ambiguous; use one of these IDs: \(ids.map(\.rawValue).joined(separator: ", "))"
            )
        }
    }

    private func zoneReference(_ zoneID: ZoneID) -> LocalAutomationZoneReference {
        let zones = workspaceState.currentProfileContext().profile.zones
        return LocalAutomationZoneReference(
            id: zoneID.rawValue,
            name: ZoneNameResolver().name(for: zoneID, in: zones)
        )
    }

    private func success(
        _ message: String,
        state: LocalAutomationExecutionState = .completed
    ) -> AutomationOutcome {
        success(message, result: LocalAutomationResult(state: state))
    }

    private func success(
        _ message: String,
        result: LocalAutomationResult
    ) -> AutomationOutcome {
        AutomationOutcome(ok: true, message: message, result: result, errorCode: nil)
    }

    private func failure(_ code: String, _ message: String) -> AutomationOutcome {
        AutomationOutcome(ok: false, message: message, result: nil, errorCode: code)
    }
}
