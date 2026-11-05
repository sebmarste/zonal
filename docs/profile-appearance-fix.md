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
