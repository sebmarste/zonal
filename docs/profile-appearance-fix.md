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
