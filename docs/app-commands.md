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


## Icon and shortcut columns update, 2026-11-08

Source `7e06c99c145fc01b6b561c3abd16b91c527b9cfa` passed `./scripts/check`: 406 XCTest tests
(10 skipped, zero failures) and 19 Python tests. Added fixtures render a wide
icon to verify transparent padding/aspect ratio, check common 16-point canvases
without mutating original images, verify native shortcut metadata and Carbon
special keys, and compare actual Auto Layout text/icon/shortcut positions at
320- and 480-point result widths.

The universal Developer ID build was accepted under notarization submission
`3036da96-7370-4341-bc74-97118fdafc46`. MacBook strict signature, staple, Gatekeeper,
both architectures, installed hash and mapped executable were verified:
`ff4a458bf0afee88d0d5a2df779a62e76e6cef63969e739f343bf21367a62c88`. One installed process ran (PID 49617),
all health flags were true, every doctor finding was OK, UW was active and saved
configuration matched the pre-install backup after startup. Live AX inventory
returned ten complete enabled Ardia categories. These are runtime checks. The user subsequently confirmed **“looks right now”**
for the normalized icons and right-aligned shortcut columns.

Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-menu-columns-If9e9HA1`.
Artifact/provenance/evidence: `/private/tmp/zonal-menu-columns/`.
ZIP SHA-256: `4179cf7f9505213c26254e2057a1e89f9b964f760f0efe0da63d780b50775e8b`.
This supplies live visual acceptance of icon size/spacing and shortcut alignment.
The user then reported hover tooltips and a “Window Focus Not Confirmed” error
when opening Ardia's tab menu, possibly after Ardia launched later than Zonal.
Earlier cross-app focus/Find success remains separately recorded against source
`0224bcc`; it does not establish that this later focus problem is resolved.


## Hover tooltips and Ardia focus investigation, 2026-11-08

Explicit native-menu and result-cell tooltips are removed, and text/table cell
expansion tooltips are disabled. Full paths and shortcut text remain accessible
through the result cell's accessibility label. Focus preparation now preserves
its failure phase, target/focused process and Quartz window IDs, exact-window
comparison, AX role and menu-bar availability before showing an alert. Native
focus logs report raise/activation outcomes without window titles.

Diagnostic source `7e44e494bd3bfec27938b5b4015061fbca66d366` passed `./scripts/check`: 407 XCTest
tests (10 skipped, zero failures) and 19 Python tests. Its universal Developer ID
build was accepted under notarization submission `aa2d727b-3be1-4411-b058-1e83ce3fa452` and
installed on the MacBook. Signature/ticket/Gatekeeper, installed and mapped
executable, all health/doctor checks, UW and configuration bytes were verified.
Executable SHA-256: `e93593c46c52304ff2e17490138b0402cbd978e78fee066f573a4452470cb822`.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-menu-focus-probe-RqbRoVj9`.
Artifact/provenance/evidence: `/private/tmp/zonal-menu-focus-probe/`.

The Ardia fault remains under investigation. Before replacement, Ardia's three
windows were tracked under PID 49865 and a fresh read found ten categories, so
there is no evidence of a startup-only command cache. One read was incomplete.
The user clarified that the failure is the pre-menu focus-confirmation alert.
The existing focus-assignment path also failed to confirm focus, but subsequent
diagnostics identified a locked desktop, making that probe inconclusive about
Ardia itself. After installation the active PID was 182 (`loginwindow`), the
reported focus role was AXApplication, no menu bar was exposed and Zonal saw zero
live desktop windows. Health permissions remained true. The user has been asked
to unlock, dismiss focus alerts and right-click Ardia once to capture the precise
failure. Do not claim Ardia repair from this diagnostic installation.


## Cold-menu focus deadline repair, 2026-11-09

The user confirmed that menus work when Ardia is already focused and that the
menu opens after unlocking and dismissing focus alerts. Unlocked diagnostics
reported ten categories/196 commands complete, with successful native raise
and front-window activation for Ardia PID 49865. This is live evidence for warm
menu opening, not a reproduction of the original cold-launch failure.

A deterministic regression then reproduced a concrete timing defect: the focus
preparation deadline remained armed throughout AX menu discovery. A slow first
menu read could enqueue a focus-timeout failure even after focus had been
confirmed and the inventory returned. The diagnostic callback could also arrive
late and dismiss an otherwise prepared menu. The new fixture fails against the
old implementation with “Confirmed focus mislabeled as a focus timeout during
menu discovery.”

The repair cancels the focus deadline immediately after strict focus readiness,
then performs the separately bounded AX inventory read. Queued timeout callbacks
check that the focus deadline is still active before failing preparation.
Capture, enabled-state/identity checks, frozen tracking snapshots and exactly-one
AXPress semantics are unchanged. `./scripts/check` passed 408 XCTest tests
(10 skipped, zero failures) and 19 Python tests. Cold-launch timing is covered by
the permission-independent fixture; a real cold Ardia relaunch remains a separate
live acceptance case.


The repair source `eea7e6e88954d1823eedff6dd71be64d0cfbbdd2` was built for arm64 and x86_64,
signed with Developer ID team XW6G452649 and accepted under notarization submission
`8eb225ee-5e10-4b67-905a-9f7dfe10bf9d`. The installed signature, staple, Gatekeeper acceptance,
executable hash and mapped running path were verified on the MacBook (PID 46445).
All four health flags and all doctor findings were OK; UW remained active and
configuration bytes matched the pre-install backup.
Executable SHA-256: `e79081b2d89b3baab3d98f07e9a69619ed64e8d7e3c25500bbd77e954c7f26d7`.
ZIP SHA-256: `8b00700c0d0689cf600cf7a700f6953c2bd44c18c55ce61f6b696201f2c443e3`.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-cold-menu-fix-DyR2wVDL`.
Artifact/provenance, failing-before regression and passing checks:
`/private/tmp/zonal-cold-menu-fix/`.

On the unlocked installed build, the live reader reported target/system/focused
PID 49865, matching target and focused Quartz window 22471, AXWindow role and a
readable menu bar. All ten Ardia categories were complete. This verifies live
window identity and menu discovery, not command execution. The user confirmed **“Menu and Find work; no tooltips”** for the cross-app test
on this repair. A real cold Ardia relaunch remains separately unverified; do not restart
the user's browser or discard its windows/tabs to manufacture that test.


## Compact spacing and unclipped viewport, 2026-11-09

Search result rows use 24 points (previously 28), group gaps use 6 (previously 8)
and the Search header uses 34 (previously 42). The redundant native separator
beside Search is removed; the separator between Zonal and app categories remains.
Icon and text sizes are unchanged. The shortcut field keeps a scrollbar gutter.

The results table uses explicit plain/custom row geometry, zero automatic content
insets and no elastic overscroll. Content height comes from actual table row
rectangles. Capped viewports initially stop at a whole-row boundary. Filtering
resets the clip origin and sizes the document to its actual row bounds before
revealing the selected item. Tests verify complete first/last rows, keyboard
navigation to the end of a long mixed-group list, shrinking from a scrolled list
to one result, and that compact row/header content stays inside its bounds.
`./scripts/check` passed 410 XCTest tests (10 skipped, zero failures) and 19 Python
tests. This deterministic geometry evidence is distinct from live visual checks.


Spacing source `72f606cf184614a6c64f6ea474b7a3c4a795e91d` was built for both architectures,
signed with Developer ID team XW6G452649, and accepted under notarization submission
`45b0e8e1-445a-44c5-b2e8-26c445fe4cb8`. The installed signature, staple, Gatekeeper assessment,
executable hash and mapped path were verified (one process, PID 47174). All health
flags and doctor findings were OK; UW stayed active and configuration bytes
matched the pre-install backup. The live focused-app inventory was complete.
Executable SHA-256: `03d2125230951030684a1415f3f1ac8db07f6ac7806deb19021275586342d643`.
ZIP SHA-256: `db2a27d7b8b5afe0c4c4bd358e20408b66a5b1e1c7cdcf1639b1dbc571099f6f`.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-menu-spacing-VeGiHEFw`.
Artifact/provenance/evidence: `/private/tmp/zonal-menu-spacing/`.

The user performed the long-list/scroll/filter check and confirmed **“looks
correct now.”** This supplies live acceptance of the compact spacing/clipping
repair; the earlier Find/no-tooltip
acceptance applies to the preceding repair and is recorded separately.


## Scrolling top inset and fixed Search separator, 2026-11-09

The user requested that top content spacing scroll with results, with a fixed
separator beside Search. A flipped document container now owns the four-point
top inset; the table sits below it inside the scrolling document. Scrolling
moves that inset out of view, while filtering resets it to the initial position.
The native Search separator stays outside the results scroll view in either
opening direction. macOS's small native outer menu margin remains unchanged.
Actual row bounds still determine the viewport, including the inset, so the
first/last commands stay fully reachable. Icons, text size, selection and command
context behavior are unchanged. `./scripts/check` passed 411 XCTest tests
(10 skipped, zero failures) and 19 Python tests, including inset scrolling,
filter reset, last-row visibility and fixed separator placement.


Edge-spacing source `3455ae1ce28738f744b51254c1fa1954b323f210` was built for both architectures,
Developer ID signed and notarized under submission `4eaaac43-8138-4739-b537-20102c291334`.
The installed signature, staple, Gatekeeper, hash and mapped executable were
verified (one process, PID 47763), with all health/doctor checks OK, UW active and
configuration bytes matching the backup. Live Ardia identity matched Quartz
window 22471 in PID 49865, with ten complete categories.
Executable SHA-256: `54fed3132cbe571bacb4b7028d8f8ebf2b83916df523cf88e65eef2870026a84`.
ZIP SHA-256: `b03b03c922db151fd7a70d733c546bc3fab9a16dd57365c726137cdf771013e3`.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-menu-edge-FVa3vvF4`.
Artifact/provenance/evidence: `/private/tmp/zonal-menu-edge/`.
The user checked this installed build and reported **“I dont see anything
changed.”** This refinement is not visually accepted: moving the four-point
internal inset did not address the gap the user means. The native NSMenu outer
margin remains fixed, and its public SDK interface has no padding/inset control.
The available CUA desktop surfaces are on the Mini, without a MacBook/Screen
Sharing surface. A screenshot identifying the exact visible gap is needed before
another implementation change or a different menu-host approach.


## Return to native edge spacing, 2026-11-09

The user accepted retaining the old approach instead of further custom edge
behavior, especially across opening directions. The extra four-point scrollable
inset and its document wrapper are removed. Results again use the table directly
as the scroll document, with the previously accepted compact rows and viewport
sizing/reset behavior. The fixed separator beside Search is retained. Native
macOS outer margins stay standard. No custom menu host or private padding API
is introduced; no screenshot is required to pursue the abandoned refinement.
`./scripts/check` passed 411 XCTest tests (10 skipped, zero failures) and 19 Python
tests, covering native document geometry, scrolling/filter reset and fixed Search
separator placement in both opening directions.


Native-spacing source `7cea9403b54e2d840441fb74cee608c7553de464` was Developer ID signed for
both architectures and accepted under notarization submission `13e88eb4-c206-45e2-95dc-897c8830373e`.
Installed signature, staple, Gatekeeper, hash and mapped executable were verified
(one process, PID 48461), with all health/doctor findings OK, UW active and
configuration bytes matching the backup. The live focused-app menu read was
complete. No new visual success is inferred from those runtime checks; this is
the user's chosen return to native edge behavior, not another scrolling-edge fix.
Executable SHA-256: `233185a022f02add883baa8906c35e105e5bbd08ee0a49225e2baf7668711ff9`.
ZIP SHA-256: `b3bd9193b296a0a5bbd6c225ec6e4257e902a10b849f00f2356527625efcea9c`.
Rollback: `/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-native-menu-spacing-9S4FPNRy`.
Artifact/provenance/evidence: `/private/tmp/zonal-native-menu-spacing/`.
The abandoned scrolling-edge refinement no longer needs a screenshot or further
acceptance; native margins and the fixed Search separator are intentional.


## Review fixes, 2026-11-09

Filtering now retains the selected command through the native close/reopen pass
when the query and direction are unchanged. A new regression spans two tracking
passes: type Move, press Down, let the menu reopen, then Return must still run
Move Right. Buffered queries use the actual opening direction.

Opening context comes from the tracker's captured AX window. Configuration,
presentation guards, diagnostics and execution focus-return checks no longer do
foreign AX reads on the main actor. Focus validation runs on the reader queue;
app/key-window ownership is checked again after asynchronous replies. A final
background window check rejects context changes during discovery. Execution still
revalidates command identity, enabled state and focus before one AXPress.

Each opening retains native category items and a flattened search-item inventory,
including icon canvases. Filtering reuses those objects, and resizing an unchanged
query avoids reloading the table. No cross-opening AX cache is introduced.
`./scripts/check` passed 414 XCTest tests (10 skipped) and 19 Python tests.
This is deterministic evidence; installed-app and live timing evidence follow
separately after signed delivery.
