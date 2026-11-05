# Active application commands

Configure an **App Commands** binding under Settings → Switching & Shortcuts →
Add Shortcut. The focused window's tab also has **App Commands…** in its context
menu. Other tab actions continue to target the clicked window.

The overlay captures the frontmost application's exact AX focused window at
opening. It stays non-activating, receives typing through Zonal's existing input
tap, and does not call `NSApp.activate` or make a Zonal window key. Arrow keys
navigate nested menus; Return opens a submenu or executes a command. Typing
searches full menu paths, with shortcuts displayed beside results. Escape clears
search, returns to the parent, then closes. Left returns to the parent.

AX reads run on a serial queue with a 150 ms message timeout, 1.5 second scan
budget, depth limit and node limit. Empty or unsupported menus produce a partial
inventory notice. Explicit navigation can populate a lazy menu through AXShowMenu
when the application supports it; Zonal never presses a menu item merely to
populate it. Commands an app does not expose through AX remain available through
its native menu bar. Search covers the currently exposed inventory; lazy menus
may require explicit navigation first.

Execution reads a fresh inventory and checks the original app/window, full path,
exact retained AX item, shortcut and enabled state (including parent menus).
A changed, replaced or unavailable item is rejected. Each execution sends one
AXPress request. A timeout reports uncertainty and never triggers a retry.
External application activation and focused-window changes close the overlay;
a bounded background focus check also covers missing notifications.

## Validation boundary

Deterministic fixture tests cover duplicate labels, full-path token search,
shortcut modifier rendering, shortcut persistence, keyboard capture, focus
changes, disabled and replaced elements, and single-attempt timeout behavior.
They do not require Accessibility permission.

Live keyboard routing, dynamic menus across real applications, and transparent
corner/shadow compositing still require acceptance on a usable desktop. The Mini
focus prototype preserved the target AX window but did not become key, and
Computer Use desktop capture failed with `cgWindowNotFound`. The implementation
therefore uses the existing non-activating input-tap architecture; this is not
proof of successful live interaction. Do not present these deterministic tests
as live acceptance or an installed-app check.
