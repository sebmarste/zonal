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
normal menu typing; AppKit handles unfiltered navigation. Zonal never activates
itself or makes another document key to obtain command context.

Zonal actions always retain the clicked assignment. Application commands are
available only when that exact clicked window is the active app's focused AX
window. A background tab still offers its own Zonal actions and an explanatory
app-command notice; it never silently targets another document.

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
during tracking, so query changes end that tracking pass and re-present the same
snapshot at the original anchor. They do not trigger another AX scan. Return
always uses the latest query, including input received during that transition.
No-match and disabled rows cannot execute.
Typing during the bounded preparation is buffered for the menu; Escape cancels.
A changed app/window cancels preparation before a stale menu can appear.

Zonal action icons are preserved in both the native menu and search results.
Recognized app categories and individual commands use standard SF Symbols; the
app category can use its application icon. Unknown command titles remain without
an icon. These presentation hints do not change command identity or targeting;
Zonal does not extract another app's private NSMenuItem artwork.

Before one AXPress, execution revalidates the active app, original AX window,
category/path, exact retained command element, enabled state (including parents),
and shortcut. It closes the native menu before execution. Stale references and
unconfirmed outcomes are reported; commands are never blindly retried. External
app/window focus changes cancel menu tracking. Inventory reads tolerate transient
system-menu AX focus; execution requires strict focus after the menu closes.

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


## Non-focused window menus: proposed behavior

Application menus and their enabled state reflect an app's current command
context, not an arbitrary background document. The reliable extension is to
focus the exact clicked window using Zonal's existing focus path, wait for
verified app/window focus, then capture its menu snapshot. Execution would keep
the existing final identity/enabled-state checks and no-retry behavior. This
would make right-click focus that window and needs separate tests for same-app
siblings, cross-app focus changes, focus failure and cancellation, plus live
acceptance. It is proposed, not implemented in the appearance update.

A cached background preview could avoid focus at opening, but its commands and
enabled state would be provisional. Selecting a command would still need focus,
fresh discovery and revalidation. General commands that leave the window in the
background are not guaranteed by the current AX menu path.
