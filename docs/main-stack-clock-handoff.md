# Mac mini continuation

Current app-command UI (2026-11-08): the user replaced the separate palette with
a single native tab context menu. Search, Zonal actions and app categories are
sections in that menu; upward opening reverses section order only. This supersedes
the older palette wording below. See `docs/app-commands.md` for current behavior.

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

## Clock installation completed, 2026-11-05

The notarization profile is now stored in the explicit file-based login keychain:
`ZONAL_NOTARY_KEYCHAIN=/Users/sebastianstein/Library/Keychains/login.keychain-db`,
profile `zonal-release`. Pass that keychain path when using `notarytool`.
Xcode 27.1's UI showed the signed-in account, but CLI export returned `No Accounts`
even with `-allowProvisioningUpdates`; do not infer a missing UI login from that
CLI failure. No Xcode account credentials were extracted.

Apple accepted clock source `98b4512` under submission
`39d24951-f033-441c-82f3-7d94f56f90ed`. The app was stapled and ticket validation,
strict/deep Developer ID verification, hardened runtime/timestamp, both binary
architectures, ZIP integrity and Gatekeeper (`Notarized Developer ID`) passed.
The final install artifact is
`/private/tmp/zonal-clock-98b4512/Zonal-clock-98b4512-notarized.zip`, SHA-256
`66796e3f28ec1cfd9fe50b8dda59e0b9c320eb1d0c862563985652e1c9640518`.
It supersedes the earlier unstapled ZIP. The accepted submission log, artifact
metadata and install/post-install evidence remain in the same directory.

Installed on the MacBook after successful graceful quit. Original app and
configuration rollback:
`/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-clock-oXnGh2Ja`.
The configuration file matched the backup both immediately after replacement and
after startup. No configuration was edited by deployment.

Post-install checks verified `/Applications/Zonal.app` has the expected Developer
ID team `XW6G452649`, stapled ticket, accepted Gatekeeper assessment, both arm64
and x86_64 slices, and binary SHA-256
`4c647d0ecf571e223d1d7b3689f0b739421dd7ed4733d194d311198439dafb30`, matching
the Mini artifact. One process (PID 94306 at verification time) ran the exact
installed executable `/Applications/Zonal.app/Contents/MacOS/Zonal`.
Accessibility, Input Monitoring, keyboard capture and tracking all returned true;
all doctor findings were OK. The internal bundle version remains 0.5.4 (76), so
use the binary hash/source commit to distinguish this clock build from the public
release with the same version.

This installation contains the clock only. The app-command implementation is on
`feature/main-stack-commands` at `80c8175`, tested and built as Developer ID Release
for both architectures, but was not installed. Live clock/command visual acceptance
and transparent-corner inspection remain unverified. The clock is off by default;
enable General → Show clock in main stack tab bar to use it. No public release,
main push or merge occurred.
