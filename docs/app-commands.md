# Window context menu

Right-click a window tab to use one native menu with three sections:

1. Search.
2. Zonal window actions (move, fit/restore custom size, close).
3. The focused application's menu categories, such as Ardia, File, Edit and View.

When the menu opens upward, the section order is app categories, Zonal actions,
then Search. Commands and category contents keep their usual order. The search
section stays nearest the opening point. A configurable **App Commands** binding
opens this same menu at the focused window's tab; there is no separate palette.

Type to filter both Zonal and app commands. App results show full menu paths and
shortcuts. Arrow keys navigate native submenus. The first enabled search result is selected automatically; Up/Down changes the
visible selection and Return executes exactly that result. Escape clears a search, then follows
normal native-menu dismissal. Backspace edits the filter and Command-V pastes
search text. Clicking the search clear button resets the filter. The existing
keyboard tap handles search text because custom native-menu views do not receive
normal menu typing; AppKit handles unfiltered navigation. Search controls cannot
request keyboard or panel focus and prevent mouse-driven window ordering.

Zonal actions always retain the clicked assignment. Right-click explicitly
focuses the exact clicked window before reading its application menus, including
background windows. It uses the existing native focus executor once and verifies
the app and AX window before discovery. A three-second preparation timeout covers
cancelled native focus callbacks; failed verification cannot present commands.
The initial source app/window is captured only to tolerate the expected opening
transition. Unrelated app/window changes cancel preparation.

AX categories are discovered before scanning descendants. Missing AXEnabled on a
menu container does not disable all its children; commands still require explicit
enabled state. Reads use a 150 ms message timeout, bounded depth/node counts and
a 1.5 second scan budget. The fresh inventory is assembled before presentation;
root categories and submenus remain a frozen snapshot until dismissal. This
prevents delayed AX reads from resizing or scrolling an open menu. The Apple
menu is excluded. Empty AX submenus are unavailable; Zonal does not press a
command to force population, and there is no dynamic-items hint.

Search stays inside the same native menu in a scrollable result area with explicit
selection. Its height fits the result count, with scrolling capped at 420 points
or the available screen space. The same Search row stays at the original tab
anchor in either direction. AppKit does not support resizing custom item views
during tracking, so query changes end that tracking pass without a close fade and re-present the same
snapshot at the original anchor. They do not trigger another AX scan. Return
always uses the latest query, including input received during that transition.
No-match and disabled rows cannot execute.
Typing during the bounded preparation is buffered for the menu; Escape cancels.
A changed app/window cancels preparation before a stale menu can appear.

Zonal action icons are preserved in both the native menu and search results.
All icons use a 16 × 16 point canvas, centered without stretching their aspect
ratio, including the application icon and zone drawings. Search rows share one
icon/title layout for both Zonal and app commands.
Recognized app categories and individual commands use standard SF Symbols; the
app category can use its application icon. Unknown command titles remain without
an icon. These presentation hints do not change command identity or targeting;
Zonal does not extract another app's private NSMenuItem artwork.

Shortcuts use native key-equivalent/modifier metadata in unfiltered menus, with
AppKit drawing the shortcut column. Search results have a separate right-aligned
shortcut field and keep full paths in the title column. Titles can truncate in
the middle without overlapping shortcuts; tooltips and accessibility labels
retain the full path/shortcut. Special-key equivalents use the SDK's Carbon menu
glyph constants, which differ from virtual key codes.

Before one AXPress, execution revalidates the active app, original AX window,
category/path, exact retained command element, enabled state (including parents),
and shortcut. It closes the native menu before execution. Stale references and
unconfirmed outcomes are reported; commands are never blindly retried. External
app/window focus changes cancel menu tracking. A confirmed focus transition into
our own menu host is tolerated only while its command context is retained; an
ordinary Zonal key window does not count as that menu host. After dismissal,
execution can return focus from Zonal's own menu to the captured window, then
performs a bounded read-only readiness wait. It immediately rejects another app
or sibling window and still requires strict focus before its one AXPress.
Diagnostics record confirmed/unconfirmed execution, including the failure reason.

`Zonal --automation app-menus` reads a bounded inventory of the currently active
app, reporting category names and counts without executing commands. Diagnostics
also retain the most recent menu inventory summary.

## Validation

Deterministic fixtures cover section reversal without reversing contents, native
submenus, full-path search, preserved Zonal actions, missing container AXEnabled,
content-sized search height/caps in either direction, anchored tracking transitions,
snapshot immutability during tracking,
Apple exclusion, automatic enabled-result selection, arrow navigation, exactly-once
Return dispatch, command enabled state, exact duplicate identities, stale/replaced references,
focus changes, shortcut modifiers and timeout/no-retry behavior. They do not need
live Accessibility permissions. Native app menu availability, search interaction,
arrow navigation and actual command execution need separate live acceptance on
the installed MacBook build.

## Installed verification, 2026-11-08

Source `d31f39a9be1b6dac5950d14431c5bca128f86048` passed `./scripts/check`:
385 XCTest tests (10 skipped, zero failures) and 19 Python tests. Its universal
Developer ID Release build was accepted under notarization submission
`82877f18-543b-4fad-888c-86c29c02c2f6`, stapled, and passed strict/deep signature,
ticket and Gatekeeper checks. Installed executable SHA-256 matches
`39af7f50cc2772f56ada3d044d97862d5f0a0de6dcbd72c240da4a96afe56b2e`.
All four runtime health flags were true, one process ran the installed path,
and configuration bytes matched the pre-install backup. Rollback:
`/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-native-menu-KNgGlwk5`.
Artifact/provenance and evidence: `/private/tmp/zonal-native-app-menu/`.

The installed read-only `app-menus` query returned a complete real Ardia inventory:
11 enabled categories (Apple, Ardia, File, Edit, View, Tabs, Bookmarks, History,
Extensions, Window, Help). The user then confirmed **“Sections and search work”**
from the actual tab context menu. The user then selected Ardia’s Find command and
confirmed **“Find opens and the menu closes.”** A subsequent diagnostic read
reported `categories=11 commands=252 complete=true`, with all doctor findings OK.
This confirms native sections, inline search and a harmless app command executing
through the real context menu. Focus-change cancellation and other applications
remain separately bounded by fixtures/source checks rather than live acceptance.


## Menu stability update, 2026-11-08

Source `18d778a30ffb410fe8afd44d09a3db5150abed67` removes updates during native
tracking and the Apple/dynamic-items rows. Search uses an explicit selected row,
skips disabled results, preserves menu height in both directions, and dispatches
Return once to the selected handler. `./scripts/check` passed 392 XCTest tests
(10 skipped, zero failures) and 19 Python tests.

The universal Developer ID build was accepted under notarization submission
`fb7a8a14-77fc-4c81-9bde-5cf792c82eee`. Its installed signature, staple,
Gatekeeper assessment and executable hash were verified on the MacBook:
`43c827cf529fddaf5bb6dd00ceb2cb4552fb71c0d8f21d805c8c9a1648005750`.
Exactly one process ran `/Applications/Zonal.app/Contents/MacOS/Zonal`, including
a matching mapped executable. All four health flags were true, every doctor
finding was OK, and configuration matched the pre-install backup after startup.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-stable-menu-3RPppA6e`.
Artifact/provenance and retained checks: `/private/tmp/zonal-stable-app-menu/`.

On the installed MacBook build, the user checked Ardia's bottom-tab menu with
“find” and confirmed **“Stable; selection and Return work.”** This supplies live
acceptance for upward-menu stability, visible initial selection, and Return
execution. The immediate post-install inventory (`categories=0 complete=false`)
was inconclusive; the later user interaction is the evidence for this case.
Focus-change cancellation and other applications still lack separate live
acceptance.


## Right-click focus and command handoff

The user explicitly accepted focusing a window on right-click. This supersedes
the earlier background-preview proposal. The implementation uses the exact
captured AX element, not an enumerated sibling. It cancels older pending focus
requests, makes one native focus request when needed, and verifies the result
before reading menus. User input into a preparing menu is buffered without
activating Zonal. External focus changes still cancel.

The user also reported an “App Command Not Confirmed” alert after searching on
the previously installed build. That identifies the execution/validation path;
the precise alert body was not supplied. The update adds passive search controls,
menu-host focus handling and a bounded focus-settling check. These are covered by
deterministic fixtures. On the installed combined build the user later confirmed
“Window focuses and Find opens,” providing live acceptance for the reported
cross-app right-click/Find case.


## Combined dynamic menu and focus update, 2026-11-08

Source `0224bccc3ac6b0938e35c218374481d2ed26b7c0` passed `./scripts/check`: 402 XCTest tests
(10 skipped, zero failures) and 19 Python tests. Fixtures cover dynamic result
height/caps, anchored reopening without AX re-indexing, rapid typing/Return,
icon preservation, passive search controls, opening-focus verification,
unfinished-focus timeout, external apps and sibling-window rejection.

The universal Developer ID build was accepted under notarization submission
`41043240-8edd-4bef-af5a-2dbe6a3fa3b1`. Installed signature, staple, Gatekeeper assessment,
both architectures and executable SHA-256 were verified on the MacBook:
`a07d44528a5979ed5a533b87259a44b68e6d40b3fa7816653f4c6207e890d4c5`. Exactly one process (PID 45416) ran the
installed path with the matching mapped executable. All four health flags were
true, all doctor findings were OK, UW was active, and configuration bytes matched
the pre-install backup after startup. The live inventory saw eight windows and
read six complete enabled menu categories for the currently active T3 Code app.
These checks establish installation/runtime health, not search or command success.

Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-command-menu-ONpXNXHS`.
Artifact, provenance and retained evidence: `/private/tmp/zonal-command-menu/`.
ZIP SHA-256: `c3438062262812d6cab9d6c98031e11fd34cb98fc023b72dcc08201ff9a86cb0`.

On this installed build, the user confirmed **“Window focuses and Find opens”**
when right-clicking Ardia from another active app and searching for Find. This
supplies live acceptance for cross-app focusing and command execution. The user
also inspected the menu and reported oversized/misaligned icons, then requested
right-aligned shortcuts. Those visual issues are addressed in the subsequent
appearance update; this is not acceptance of the new icon/column layout.
