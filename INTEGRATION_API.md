# Captured-window automation API

These local API v2 additions expose captured-window actions and native app-menu catalogs.
Inspect capabilities on the running app before using optional commands. An older installed build
does not gain source fixes. All window execution reuses Zonal’s current scope and action policy.

Requests retain the `{apiVersion:2,id,command,arguments}` envelope. Use one request per connection;
keep the write side open until the response. Half-close or pipelined bytes cancel pending work. Existing capabilities are
`window-scope`, `window-action`, `show-window-actions`, and `undo`. This update adds
`native-window-catalog` and `guarded-undo`.

`undo` delegates the existing global undo engine after checking persistence write access and
current undo availability. It is a general action independent of captured window scope.
`status` optionally includes `undoTransaction`: the current transaction ID, name and target
window metadata. `undo-if-current <transaction-uuid>` refuses a changed transaction, read-only
state or busy engine before invoking Undo in the same main-actor turn. Clients should send
the ID they displayed. Acceptance means Undo started; the existing engine verifies outcomes.

`window-scope <origin-json>` accepts pre-palette PID, Quartz window ID, bundle ID, session,
profileID and assignmentID. All must still identify one non-minimized, non-fullscreen managed
window in Zonal's current profile. There is no frontmost-window fallback. Results contain only
actions allowed by the same RestoreEngine guards and tab snapshot policy used by Zonal's UI.
Optional appName, windowTitle and zoneName fields let clients label the exact target.
The status/zones projection includes optional normalized zone frames for item previews.
These are presentation metadata; scope and action execution remain authoritative in Zonal.

`window-action <origin-json> <action-id>` resolves scope again and delegates fit, restore-custom,
move or close to Zonal's existing engine. Undo is exclusively global. Acceptance is not placement verification.

`native-window-scope <origin-json>` exports Zonal's cached native app-menu inventory without
opening a panel, capturing input or focusing another app. Results include windowScope and
nativeScope: token, complete, and commands with id, title, full path, enabled and shortcut.
Discovery retains Zonal's bounded reads; complete=false means a partial inventory, not an
exhaustive list. Disabled rows remain identifiable. The existing Apple-menu exclusion applies.

`native-window-action <origin-json> <scope-token> <command-id>` delegates to the existing
AppCommandExecution/reader pipeline. Leases expire after five minutes (at most eight retained)
and bind palette session, profile, assignment, PID, process launch date and exact AX window.
Every export creates a fresh immutable lease. Execution revalidates the menu path, title, current
AX element, shortcut, focused target, lease and captured Zonal scope at the press boundary.
Socket disconnect, server shutdown and the five-second request deadline revoke pending permission.
Changed or expired contexts fail closed. The client restores the captured app/window
before dispatch; Zonal does not choose a replacement target. Native commands retain their app's
own undo semantics. Zonal placement actions retain Zonal's existing undo engine.

`show-window-actions <origin-json>` remains available for Zonal's own UI consumers. Tinycast
no longer calls it. Tinycast exposes Settings and Undo as general root actions, applicable
Zonal placement actions directly in root with window/zone names, and one Window actions…
gateway into a separately searchable native scope inside Tinycast. Hidden non-root context
records preserve exact profile/assignment capture. No native leaf is flattened into root.

The stable and Dev Zonal bundles share the instance lock. Do not bypass it or run two managers.
Deterministic fake-AX tests cover export without a panel/input capture, duplicate command paths,
session rejection, one guarded press and replaced-command rejection. These tests do not prove
live macOS execution. No live move, close, undo or native command is claimed for the new API.
