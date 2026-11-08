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
selection. Its height matches the unfiltered menu so the Search row stays at the
opening point even when results change. No-match and disabled rows cannot execute.
Typing during the bounded preparation is buffered for the menu; Escape cancels.
A changed app/window cancels preparation before a stale menu can appear.

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
stable search height in either direction, snapshot immutability during tracking,
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
