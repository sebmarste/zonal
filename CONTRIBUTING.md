# Contributing to Zonal

Zonal is a native, local-first macOS window manager. Focused bug fixes, regression
fixtures, documentation improvements and reports from real display setups are welcome.
For a new feature or substantial restructuring, open an issue describing the problem
and intended behavior before investing in an implementation.

## Changes and pull requests

- Explain the user-visible problem, the change, and how you checked it.
- Add deterministic regression tests for behavior changes. Keep them independent
  of live Accessibility permissions and personal workspace data.
- Run `./scripts/check`. Record live checks separately with OS version, architecture,
  display arrangement and the behavior actually observed.
- Follow [AGENTS.md](AGENTS.md) for window identity, persistence and compositing invariants.
- Keep generated icon assets consistent with [their sources](Zonal/IconSource/README.md).
- Do not commit signing material, personal configuration, crash dumps or unreviewed screenshots.

Small documentation-only edits need link and diff checks; they do not require a
full native test run. Maintainers may ask for a smaller change when a proposal
adds complexity without solving a demonstrated problem.

By contributing, you agree that your contribution is available under the project's
[MIT license](LICENSE). Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Development and validation

The `scripts/` directory holds the shared local/CI build, release, and validation
entry points. Icon sources live in `Zonal/IconSource`; generated assets live in
`Zonal/Assets.xcassets`. The icon sources and exporter are not app resources.

Requirements:

- macOS 26 or newer
- Xcode 27 or a compatible Xcode installation with the macOS 27 SDK
- Python 3.9+ (the Xcode command-line tools installation is sufficient)
- Accessibility and Input Monitoring permissions for live window-management
  checks

### Local build and data isolation

Clone the repository, open `Zonal.xcodeproj`, select the shared Zonal scheme and
run Debug. No private signing configuration or paid Apple account is required.
Alternatively, build without launching:

```sh
./scripts/build-dev
```

Debug uses an ad-hoc signature and bundle ID `com.sebmarste.zonal.dev`, displayed
as Zonal Development. Its workspace lives in `~/Library/Application Support/Zonal Development`;
its automation socket is below that directory. Release uses `com.sebmarste.zonal`
and `~/Library/Application Support/Zonal`. Neither copies nor migrates the other's
state. A shared ownership lock prevents both copies from managing windows at once,
including with the existing installed release. Quit the daily app before running
Debug; quit Debug before returning to the daily app. The build script never quits,
installs or launches either copy.

Permissions are separate for the development app. Ad-hoc rebuilds can require
permission reapproval; for a stable personal development signature, select your own
team in Xcode locally or pass signing overrides to xcodebuild. Do not commit your
team, certificate or credentials. Local development still controls real windows
when launched with permission; separate data does not create a simulated desktop.

Run the deterministic validation suite from the repository root:

```sh
./scripts/check
```

The script writes Derived Data below the system temporary directory, runs all
unit tests and validates the property list and project diff. It runs the hosted
test app without installing Zonal or starting its normal window-management services.

Live validation is separate because it operates on the signed-in user's actual
windows:

```sh
/Applications/Zonal.app/Contents/MacOS/Zonal --automation diagnostics
./scripts/check-live-state
```

`check-live-state` is read-only. It samples the structured observed/desired
window model and fails on duplicate identities, impossible frames, or
unexplained drift while reporting stable placement mismatches as warnings.

For resource regression checks, leave the app settled and run:

```sh
./scripts/check-resource-usage --seconds 30
```

This read-only probe uses CPU-time deltas for the same process (100% is one core),
reports resident memory and growth, and fails above 5% average CPU or 32 MiB growth.
These are idle acceptance budgets, not limits during interactions. Repeat after
opening/closing Settings, repeated switching, and sleep/wake on the target Mac.
The switcher warms once and retains a detached view tree while hidden. Keyboard
capture runs on a dedicated run loop using cached shortcut matching, and mouse
tracking is listen-only, so rendering cannot block ordinary system input.
Diagnostics include tab refresh, content-update, and actual hosting-layout counts;
unchanged tabs should not accumulate layout passes. Short samples cannot prove
absence of long-term leaks or measure total system/GPU energy.

For an opt-in compositing preview in a graphical session with screen-capture
permission:

```sh
TEST_RUNNER_ZONAL_LIVE_OVERLAY_CHECK=1 xcodebuild \
  -project Zonal.xcodeproj -scheme Zonal -destination 'platform=macOS' \
  -only-testing:ZonalTests/OverlayCompositingTests test
```

It creates temporary preview windows over a contrasting background and saves
`/tmp/zonal-overlay-compositing.png` for visual inspection. It uses a temporary
settings store and does not move your application windows. The normal check
suite skips this live test.

To check optional Window Server notifications and target-relative outline ordering
without screen capture or Accessibility permission:

```sh
TEST_RUNNER_ZONAL_LIVE_WINDOW_SERVER_CHECK=1 ./scripts/check
```

This opt-in check creates temporary windows and verifies native events, stacking
levels, and Quartz bounds. It does not prove visual compositing or other apps' AX behavior.

For tab backing order and same-zone switching, run:

```sh
TEST_RUNNER_ZONAL_LIVE_TAB_PROTOTYPE_CHECK=1 xcodebuild \
  -project Zonal.xcodeproj -scheme Zonal -destination 'platform=macOS' \
  -only-testing:ZonalTests/ZoneTabPrototypeRenderingTests test
```

Add `TEST_RUNNER_ZONAL_TAB_SCREENSHOTS=1` to export renderings and illustrations
to `/tmp/zonal-tab-prototypes-rendering`. Native screenshot capture is a separate
opt-in test requiring screen-capture permission; unavailable capture does not
mark the ordering test as skipped. Clear-corner and shadow-boundary assertions
always run in the normal suite without writing preview files.

The deterministic suite also exercises placement cancellation, superseding queued
requests, independent per-app workers, fullscreen companion eligibility, and
edge-centered outline rendering and focus visibility. These checks do not simulate actual mouse gestures
or prove live multi-display behavior.


### Settings previews

Export native Settings page renderings without starting window-management services:

```sh
TEST_RUNNER_ZONAL_SETTINGS_PREVIEWS=1 xcodebuild \
  -project Zonal.xcodeproj -scheme Zonal -destination 'platform=macOS' \
  -only-testing:ZonalTests/OverlayCompositingTests/testSettingsNativePreviews test
```

Images are written to `/tmp/zonal-settings-previews`. This uses temporary settings
and preview windows; it does not grant permissions or submit reports. It verifies
rendering, not live Accessibility behavior or actual GitHub submission.

## Code map and platform boundaries

`AppContainer` composes the shared services. `PersistenceStore` owns saved state;
`WindowRegistry` and `WindowTracker` discover and track exact windows;
`WindowController` places and focuses them; `RestoreEngine` coordinates recovery
and undo. `WorkspaceStateService` supplies reconciled projections to switchers,
tabs, diagnostics and automation. Settings pages edit one shared draft.
See [AGENTS.md](AGENTS.md) for the identity, persistence and compositing invariants.

Some macOS integration uses dynamically resolved private APIs:

| Adapter | Purpose and fallback |
| --- | --- |
| `AXEnhancedUserInterface` | Temporarily suppress animated frame writes, restoring the enabled state; unavailable/disabled modes are unchanged |
| `_AXUIElementGetWindow` | Exact AX-to-Quartz identity; otherwise require a unique metadata match |
| SkyLight notifications and transactions | Decoration ordering; fall back to public ordering and polling |
| SkyLight corner-radius query | Native outline shape; fall back to a 10-point radius |
| Legacy process activation | Single-window focus; fall back to public Accessibility focus |

These interfaces can change across OS releases and are not an App Store compatibility
promise. Keep them behind adapters and test unavailable backends. Universal builds
are not evidence of Intel runtime compatibility; see README for live-tested limits.

## Release process

Merging an increased app version and build number in `Zonal/Info.plist` to protected
`main` starts **Release**. Other merges do not create releases. CI creates an
immutable version tag, runs checks, builds both architectures, signs with Developer
ID, notarizes and staples the app and DMG, and verifies the uploaded artifacts.
It then automatically publishes the release as a public beta with generated notes.
A draft holds the assets until verification succeeds; failures leave it unpublished.

Only the maintainer can update `main`, and required PR checks protect merges.
The `release-signing` environment accepts only workflows running from `main`.
PR checks have no signing credentials. Signing has read-only repository access;
separate jobs create the tag and publish the verified artifacts.

Release assets retain the installer, checksums, source/toolchain provenance and
matching debug symbols. Shared local/CI build and verification code lives in
`scripts/release.py`; GitHub-specific setup lives in `.github/scripts`.
Local signing remains available as a fallback. Credential setup and recovery
procedures are maintained in the private maintainer runbook.

## Terminology

A **profile** is a saved configuration; its **layout** arranges zones. A **display
setup** is the connected displays and their arrangement. A **Space** is a macOS
desktop. The **main zone** is the fallback for windows without a zone and takes
appearance priority when zones share tabs.

Use **All Windows** and **By Zone** for the switchers, and **Overlap**, **Peek stack**,
**Tab shelf**, and **Tab frame** for presentations. Both switchers show managed
windows in the current Space, subject to the display scope in settings.
User-facing key bindings are **shortcuts**. Shared names belong in the existing
model enums. Serialized names and automation commands are compatibility surfaces:
internal renames must preserve their wire values unless a format change is deliberate.
