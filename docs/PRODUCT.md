# Product

ScreenSwap is a macOS 14+ menu-bar utility for moving eligible windows between
exactly two selected active displays. On a Mac with three or more displays,
users choose the active pair; other displays remain untouched.

## Actions

- **Swap:** exchange the selected windows, preserving proportional layouts.
  Default shortcut: Control–Shift–S.
- **Move Focused Window:** move one focused eligible window to the other
  selected display, independently of swap checkboxes.
  Default shortcut: Control–Option–Shift–S.
- **Call / Return:** bring the topmost eligible window from the other selected
  display to the system primary display. Invoke again to restore that same
  window's saved display and geometry. Default shortcut: Control–Shift–C.

Left click defaults to Swap and middle click to Move. The right-click menu
configures both bindings. They remain distinct; scrolling over the icon cycles
middle click between the two remaining modes and previews its icon. Keyboard
shortcuts are configurable in Settings and stay tied to their named actions.

A pending Return blocks Swap and Move until Return or Cancel. Cancel keeps the
window where it is and forgets recovery intent. Failed placement retains retry
state; a missing window, changed pair or disconnected source cannot retarget
Return. Return state is kept in memory for the current app session.

## Supported behavior

Accessibility onboarding, per-window selection, launch at login, About/support
links and Reduce Motion-aware feedback accompany the window actions. Movable
fixed-size windows receive position writes only. Native full-screen Spaces,
spanning, minimized, transient and unavailable windows are excluded.

Idle and hover icons are static. Fully successful actions animate using the
supplied icon pack; Reduce Motion skips or cancels playback immediately.

## Outside current scope

General N-display rotation, persistent recovery across app restarts, display
locking and Windows support.
