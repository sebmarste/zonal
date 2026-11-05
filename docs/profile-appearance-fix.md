# Profile appearance and clock settings

Profiles → Appearance now contains zone spacing, tab edge, tab labels,
overlapping-tab behavior and the main-stack clock checkbox. Controls edit the
selected profile, whose name appears in the section heading. Theme and feedback
appearance remain global under General. Clicking the displayed clock has no
action.

Profiles without an appearance override keep their existing global tab/clock
settings as a read-only fallback. Editing a profile saves an explicit appearance
on that profile, without changing other profiles or rewriting custom placements.
No persistence migration is performed. Unknown or invalid files still block writes.

The clock checkbox previously failed because the settings draft merge omitted
`behavior.showMainStackClock`. The legacy field now merges correctly, and the
new profile checkbox saves with the profile. Clock changes explicitly refresh the
tab projection without window reconciliation or reflow. Tab-edge changes compare
effective old/new appearance and reflow fitted windows when needed.

Frame capture now ignores redundant notifications at an existing fitted target
and rejects a delayed capture if its profile or geometry changed while waiting.
These guards prevent old/current fitted frames from being recorded as custom
rectangles in the destination profile. Regression tests reproduce both paths.

Live MacBook inspection before the fix found UW active at 6 pt, Main at 0 pt.
Three live zone-fit windows matched their desired spaced frames; the main browser,
Warp and Screen Sharing had saved custom placements and matched those targets.
Finder had no saved target; Settings had moved from its last custom target.
This establishes the current saved-placement behavior, not the history of why a
particular custom placement was created. Existing custom placements are preserved.

Validation: `./scripts/check` passed 378 XCTest tests (10 skipped), zero failures,
and 19 Python tests. Coverage includes the actual settings merge/reopen path,
per-profile switching of spacing/edge/labels/clock, compatibility fallback,
fitted-state preservation and rejection of delayed captures from another profile.
Live checkbox clicking and desktop compositing require separate visual acceptance.

## Installed verification

Source `17fa7fe133440ab95416a06c63bfb35e8aec076f` was built in Release for arm64 and
x86_64 with Developer ID team `XW6G452649`. Apple accepted notarization submission
`70b91dc8-7d96-4bfe-9bb9-e48a242c1e0d`; stapling, ticket verification, strict/deep
signature verification and Gatekeeper all passed.

Artifact `/private/tmp/zonal-profile-appearance/Zonal-profile-appearance-notarized.zip`
has SHA-256 `d16adc3cb5dd21f6e2bc9c55244908980c7725e587dfd2837658035e5fedca9e`.
Installed executable `/Applications/Zonal.app/Contents/MacOS/Zonal` on the MacBook
has matching binary SHA-256
`06295901577069f382b24094775b819149a4b28c7d16198378b23cc5933fc5a2`.
At post-install verification one process (PID 95687) ran this exact path; all four
health flags were true and all doctor findings were OK. Active profile remained UW.
The bundle still reports 0.5.4 (76); distinguish feature builds by source/hash.

The preceding clock-only app and configuration were preserved at
`/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-appearance-lLVRqbbu`.
Configuration bytes matched the backup after installation and startup. No saved
custom placements were reset. The install includes the command implementation
already present on this feature branch; native command interaction remains a
separate live acceptance check. Visual checkbox/clock acceptance is pending user
confirmation. Build, accepted notary submission, install and runtime evidence are
retained under `/private/tmp/zonal-profile-appearance/`.

## Follow-up: saved profile clock did not render

The user confirmed the checkbox now saved, but the clock remained absent.
Live MacBook configuration verified UW's `tabAppearance.showsClock` was true.
The renderer was resolving appearance from `workspaceContext()`'s cached profile.
A clock-only change intentionally skips reconciliation, leaving that profile
copy unchanged. `zoneTabs.refresh()` alone therefore still produced `showsClock=false`.

A new regression test saves a profile clock override and reads the tab snapshot
without reconciling. It failed on the installed source, then passed after making
the rendering projection resolve the cached profile ID against the latest saved
configuration. Geometry and fitted-window membership remain unchanged. Disabling
clock visibility is also covered. Required checks pass 379 XCTest tests (10
skipped, zero failures), plus 19 Python tests. This fixes the reproduced stale
projection; desktop visibility still needs user confirmation.

The cache fix was built from `67f3340ad0af2cd3b8ee1acdc29b18b7ee1e4d7b` for both
architectures with Developer ID signing. Apple accepted submission
`08892585-770a-48c2-96c0-2f1f890c0b99`; stapling, ticket, signature and Gatekeeper
checks passed. Artifact:
`/private/tmp/zonal-clock-render-fix/Zonal-clock-render-fix-notarized.zip`, SHA-256
`1fd6810ceb381b4df9c2b8a9e6d9762f8ce4d328cc5077e440205f8aaf742ee6`.
Installed binary SHA-256:
`b8e93a72bae94a8c8afa36a7f2dddaf56ad2d339c348fe3e17b89c05791476bc`.
Post-install verified one process (PID 2658 at verification) at the exact installed
path, all four health flags true, all doctor findings OK, and configuration bytes
unchanged (including UW's enabled clock). Rollback:
`/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-clock-render-gXE4Z9k6`.
Evidence is retained under `/private/tmp/zonal-clock-render-fix/evidence/`.
Visual clock acceptance is still awaiting user confirmation.

## Main-zone Frame/spacing report after clock confirmation

The user confirmed the clock is visible and supplied a screenshot of a standalone
main-zone tab strip. Live UW configuration was Frame on all three zones, 6 pt
spacing, bottom tabs. All three live main-zone windows were saved as `.custom`:
main browser assignment `EA65EAFB-C4F1-4F7F-8CB9-24ACC9A39726` at
`[1330,30,2458,1378]`, plus two Screen Sharing windows. With no fitted members,
`ZoneTabStripView` deliberately uses the strip-only fallback even when Frame is
configured, and restore preserves custom rectangles instead of applying zone gaps.
This is the current data/rendering explanation; it does not establish how the
browser became custom historically.

Planned live repair: fit only that exact browser assignment to Main, preserving
the Screen Sharing custom placements. A focus-based attempt stopped before any
fit because actual focus could not be confirmed. To avoid focus races, the local
API now exposes `fit-assignment <uuid>`, which validates a live managed assignment
and calls the existing exact-target tab Fit operation. Invalid/missing UUIDs are
covered. Required checks passed 380 XCTest tests (10 skipped, zero failures) and
19 Python tests.

Source `df36de4fde156d54985bed1d26c25608ee9c0471` was built/signature-verified for
both architectures and accepted under notarization submission
`fdeaf7b5-e853-47e7-ac29-f1297c60c344`. Artifact:
`/private/tmp/zonal-exact-fit/Zonal-exact-fit-notarized.zip`, SHA-256
`cc65cd513a231ff44ca136059e995dd6cf00a9636ec33d398fdd1bbfebaf193b`.
Installed binary SHA-256
`e0d5861cfb05b5cf709a4a8845c1dac39ee3979f08484aa806fe6ea83fdc3628`.
Installed signature, ticket, Gatekeeper, exact executable path and one running
process (PID 4763 at verification) passed; all health flags and doctor findings
were OK. Configuration was preserved. Rollback:
`/Users/sebmarste/.local/share/macbook-deploy/rollback/zonal-exact-fit-g3XSdvCH`.

The repair has **not executed**: after restart, live window inventory was empty;
a normal rescan and `CGSessionCopyCurrentDictionary` confirmed the MacBook was
locked. The identity guard rejected the missing target before issuing Fit. Await
unlock, then verify exact live identity and issue `fit-assignment` once. Retained
repair script `/private/tmp/zonal-exact-fit/repair-main.py` must use remote stage
`/Users/sebmarste/.local/share/macbook-deploy/staging/upload.HjKv077u` in place of
`REPAIR_STAGE`. It verifies a `.zoneFit` result, observed/desired frame agreement,
and unchanged Screen Sharing profile placements. Do not retry an uncertain fit
without reading the actual result. Native Frame/spacing acceptance remains open.
