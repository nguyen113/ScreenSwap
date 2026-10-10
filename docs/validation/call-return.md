# Call / Return and mouse bindings validation

Date: 2026-10-10.

## Automated results

`./build-test.sh` passed with 170 tests discovered and executed.
`git diff --check` passed. Coverage includes Quartz stacking order independent
of application enumeration, original AX geometry before normalization, stable
runtime identity with fresh transaction IDs, Call/Return verification and
recovery, conflicts and cancellation, closed/unavailable windows, changed pair,
disconnected displays, changed usable geometry, fixed-size windows, permission
ordering, spanning/full-screen exclusions, mode persistence/exchange/cycling,
shortcut conflicts/registration restoration, wheel debounce, trackpad momentum,
AppKit hover selectors, template resources at both scales and Reduce Motion.
The final branch integrates main's configurable SWAP/MOVE and directional icon
change (#8), retaining dynamic horizontal/vertical/diagonal arrows and adding
regressions for existing preference migration and Call/Return input routing.

`Packaging/pack-app.sh --install --replace` built the universal app with the
existing ScreenSwap Local Development signing identity, verified its signature,
installed it at `/Applications/ScreenSwap.app` and launched it. The process was
confirmed running. Native UI inspection could not attach to the menu-bar app:
app-name/path lookups timed out and the bundle identifier was ambiguous across
existing worktrees. The agent did not directly verify live menu appearance or
window motion.

## User-reported manual result

On 2026-10-10, the user confirmed that the installed feature works ("it works")
and requested a pull request. This confirmation applies to the installed
Call/Return build before integration with main's newer directional-icon change.
Hardware details and individual scenario results were not provided; the additional physical checks below are not individually
confirmed.

## Additional physical checks

- Right-click the icon: confirm Left Click and Middle Click submenus, checked
  modes, Call command, and the Call/Return shortcut recorder in Settings.
- With default bindings (Swap/Move), scroll over the icon: middle click changes
  Move ↔ Call/Return, left click stays Swap, and the icon previews the new mode.
  Leaving the icon restores the left-click icon. Check mouse wheel and trackpad;
  one trackpad gesture changes once and momentum does not change it again.
- Select the system primary display and one other display. Arrange overlapping
  normal windows on the other display. Press Control–Shift–C: only its topmost
  eligible window moves proportionally onto the primary and is raised.
- Focus a different window and resize/reposition the called window. Invoke
  Call/Return again: the same runtime window returns to its saved display and
  geometry. Confirm both directions across unequal resolutions and Dock insets.
- While Return is pending, confirm Swap/Move are blocked and Cancel Return
  leaves the called window in place. Close/minimize/hide the called window or
  disconnect the source: Return must keep recovery and move no other window.
- Check native full-screen Spaces, spanning windows, fixed-size windows,
  Accessibility denial/regrant and a changed display pair. Reduce Motion must
  show the successful settled icon immediately without motion playback.
- Configure all three shortcuts, reject duplicates, and check unavailable
  combinations retain the previous registration. Changing click bindings must
  keep each shortcut bound to its named action.

Call/Return state is process-local. Cancel and app termination forget its saved
Return without moving the window.
