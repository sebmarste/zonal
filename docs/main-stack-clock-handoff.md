# Mac mini continuation

Continue `origin/feature/main-stack-clock` (clock implementation: `62f1662`,
based on `origin/main` at `f9e3102`). Fetch first, inspect checkout state, and
preserve unrelated changes. Do the work natively on the Mac mini.

## First: signed build and MacBook installation

The user explicitly requests building/signing on the Mac mini and installing on
the MacBook. Do not install an ad-hoc build. Use the existing Developer ID signing
and notarization workflow; inspect `scripts/release.py` before choosing the local
build path. Do not publish a release, merge, or push main. Do not print credentials.
Preserve the installed app and configuration for rollback. Verify the installed
binary, running path, Accessibility/Input Monitoring, keyboard capture, and tracking.

The MacBook currently has the original notarized 0.5.4 (76), restored after a local
ad-hoc experiment. Its health API reports all four checks above true. The ad-hoc
copy lost permissions, which is why the user rejected that installation method.

Clock behavior: General → Show clock in main stack tab bar, off by default;
belongs to the group containing the main zone even when a peer zone is primary;
right end of horizontal tabs, top of vertical tabs; system short time, minute
updates, date tooltip. It requires a nonempty tab group and does not resize windows.

Validation: `./scripts/check` passed, 367 XCTest tests, 10 skipped, zero failures,
plus 19 Python tests. Release configuration built for arm64 and x86_64. Small
pre-existing Swift compiler/name-shadowing/test-initializer fixes are included.
AppKit renders for both Frame and Shelf were inspected. Live native validation
remains open: the preview controller saw zero fixture panels and screen capture
was unavailable. Recheck actual desktop compositing on a usable GUI session;
do not equate issued commands or offscreen images with live success.

## Then: remaining agreed app-command functionality

Implement only the currently active application's commands, obtained through AX.
One menu tree should support mouse and arrow-key nested navigation, plus typing
to search all commands with their full menu path and shortcut. Enter executes;
Escape returns/closes. Provide a configurable shortcut and a context-menu entry
on the currently focused window's tab. Background-tab actions still target the
clicked window; never silently execute a different document's app commands.
Capture the active app/window when opening; close on external focus changes.
Prototype palette keyboard focus without invalidating the target app's command
context before integrating. Revalidate enabled state and identity at execution.
Handle lazy/dynamic menus, duplicate names, modifiers, stale AX references, and
timeouts; never blindly retry commands with uncertain execution outcomes.

Battery, sound, Wi-Fi, third-party status items, and custom widgets remain out of
scope. The system menu bar stays available through macOS auto-hide; do not modify
its setting without a request. Run required checks and keep deterministic tests
independent of live AX permissions. Keep work on the feature branch.

## Continuation on Mini, 2026-11-05

`feature/main-stack-commands` starts at the clean clock head `98b4512`.
Fetched upstream: `origin/feature/main-stack-clock` remains `98b4512`;
`origin/main` remains `f9e3102`.

The clock-only source was archived for arm64 and x86_64 with the real timestamped
Developer ID Application identity, team `XW6G452649`. Strict/deep verification,
hardened runtime, architecture and ZIP checks passed. Retained artifact:
`/private/tmp/zonal-clock-98b4512/Zonal-clock-98b4512-DeveloperID.zip`.
SHA-256: `77b06fc4998a05520cf72f8bc5abbad66661ce03841e61e1d6ca4a572d3fd260`.
The archive and build/notary evidence are in that directory. This ZIP is **not
notarized**: the documented `zonal-release` profile was missing. The user is
setting up that profile locally. Resume with the existing `submission.zip`,
notarize using `scripts/release.py` helpers, staple/validate the archive's app,
verify Gatekeeper, and create a fresh ZIP from the stapled app before staging.
The old ZIP checksum will change after stapling. Do not install the unstapled ZIP.

MacBook access was intermittent but recovered. Live read-only checks verified
`/Applications/Zonal.app`, original 0.5.4 (76), Developer ID team `XW6G452649`,
stapled notarization ticket, one running process at the installed path, all four
health flags true, and all doctor findings OK. No replacement was performed.
Preserve this copy and configuration when installing the notarized clock build.

The app-command implementation and its limitations are documented in
`docs/app-commands.md`. Required checks passed: 373 XCTest tests, 10 skipped,
zero failures; 19 Python tests. Fixtures are independent of AX permission.
Live GUI acceptance remains open: the focus probe retained the original target
AX window but was not key; desktop capture failed with `cgWindowNotFound`.
Native typing and transparent corners have not been observed. No release,
main push, or merge was performed.
