# Zonal development guidance

## Validation

- Run `./scripts/check` after source, test, project, or persistence changes.
- Keep deterministic tests independent of live Accessibility permissions.
- Treat live window validation as additional evidence, never as a substitute
  for regression tests.

## Window identity and discovery

- Discover current-Space Quartz metadata before all-Space metadata.
- Never use enumeration order as identity and never guess between ambiguous
  same-application windows.
- Capture the exact focused AX window at the notification boundary before
  dispatching to the main actor.
- Keep confirmed current-Space windows through incomplete scans; removal
  requires the configured sequence of complete absences.
- The transient host exclusion is intentionally exact:
  `AXDialog + AXIdentifier=_NS:8 + normalized title hint=window`. Do not broaden
  it without new live evidence and a regression fixture.

## State and persistence

- The app owns one shared `PersistenceStore`; inject it rather than creating
  feature-local stores against the same files.
- Assignment and MRU history changes that belong to one operation must be
  persisted as one workspace update.
- Switcher, diagnostics, and automation projections should be read-only.
- Support only the current pre-release persistence formats. Preserve unsupported
  or invalid files and block writes instead of migrating or silently resetting them.
- Treat sleep/unlock as one session-recovery transaction. Freeze assignment
  targets before unlock, suppress automatic AX frame persistence until restore
  verification finishes, and let an explicit mouse gesture opt only its window
  out of the pending restore.
- A restore toast reports verified placement outcomes, not issued AX commands.

## Repository hygiene

- Preserve unrelated user changes and inspect `git status` before editing.
- Local commits are allowed when requested. Creating remotes, pushing,
  publishing, and deploying require explicit user authorization.

## Floating-window compositing

- Borderless and non-activating overlay windows must remain transparent at the AppKit level: set `isOpaque = false`, `backgroundColor = .clear`, and `hasShadow = false`.
- Do not use the native `NSWindow` shadow for a rounded SwiftUI surface. Window Server shadows follow the rectangular window bounds, not the inner SwiftUI shape.
- Render shadows on the same rounded SwiftUI shape that draws the surface. The hosting window must include a transparent effect outset at least as large as the shadow's visible extent; a surface that fills the window will clip its shadow into a sharp rectangle.
- Size and position floating windows from the full rendered footprint (surface plus effect outset), while anchoring the visible surface where the UX expects it.
- When adding or changing a floating surface, inspect its transparent corners over a contrasting background at runtime. Source-level corner radii alone do not verify correct AppKit/SwiftUI compositing.
