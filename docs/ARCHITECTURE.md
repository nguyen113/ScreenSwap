# Architecture

## Source organization

`ScreenSwapCore` remains the pure domain target, organized into `Geometry/`
and `Models/`. `ScreenSwapMac` remains one macOS target, organized by boundary:
`Accessibility/`, `Displays/`, `Swap/`, `StatusItem/`, `Diagnostics/`,
`Performance/`, `Selection/`, `Settings/`, and `HotKey/`. The selection
boundary owns runtime keys based on process ID plus Quartz window number,
read-only menu inventory, and non-persistent checked state. Titles are
presentation-only and never identities.

No additional SwiftPM targets are introduced by this layout refactor.

```text
StatusBarController --> SwapCoordinator --> AccessibilityWindowService
       |                       |             (capture, apply, verify, restore)
       |                       +--> DisplayProviding + DisplayPairSelectionStore
       |                       +--> WindowSelectionStore + WindowMappingEngine
       |
       +--> LiveStatusItemInventoryProvider --> read-only AX/Quartz inventory
       +--> GlobalHotKeyService --> swap / focused-window move
       +--> FocusedWindowProvider --> targeted move through SwapCoordinator
       +--> Settings / About windows
```

## Core principle

`ScreenSwapCore` owns deterministic domain models and geometry planning.

It must not depend on Accessibility APIs or status-bar UI.

## Icon presentation

`IconAnimationController` presents the v3.1.3 Option A templates at 18pt with
native @1x and @2x representations. SwiftPM copies the PNG resources into
`ScreenSwap_ScreenSwapMac.bundle`; packaging includes that bundle in
`Contents/Resources` alongside the permanent blue Swap ICNS. Editable SVG
masters and the pack's requirements remain in `Design/IconPack`.

Only fully successful nonempty transactions animate: thirteen frames over
twelve intervals (Swap 200ms; horizontal Move 180ms). Failures, partial results,
idle and hover remain static. AppKit supplies tint and pressed treatment.
New actions cancel old playback; Reduce Motion is checked before and during
playback and observed for immediate cancellation. Presentation never delays AX
work. The controller serializes status-item commands so a second hotkey or
middle-click cannot reset in-flight feedback. The coordinator publishes frozen
source/destination display geometry only for a successful focused move; the UI
derives direction from that geometry, never display ordering. No vertical
glyph is supplied, so vertical moves keep the static Swap icon. After feedback,
the icon returns to Swap because left-click still invokes Swap.

Call/Return is deferred in `backlog.yml`. Its editable artwork is retained but
no command or recovery state is enabled by importing the icon pack.

## Swap transaction

1. Validate Accessibility permission.
2. Discover active displays.
3. Reconcile and freeze exactly two selected displays. With three or more
   physical displays, `DisplayPairSelectionStore` keeps a runtime-only pair.
4. Snapshot windows against the complete active-display topology.
5. Detect windows that span any active displays and exclude them from the move
   plan; classify windows on non-pair displays as intentional routing skips.
6. Assign each remaining window to a source display, then retain only the
   frozen pair.
7. Compute the complete destination move plan using the unchanged two-display
   mapping engine.
8. Re-read display IDs, full frames, and visible frames after capture and
   immediately before the first AX write. Abort with no writes if topology or
   geometry changed during the transaction.
9. Apply every planned move, continuing after individual failures.
10. Verify successful ordinary-window writes against both AX geometry and the
   Quartz on-screen window list.
11. If a window has the expected AX geometry but remains offscreen after the
    bounded verification window, best-effort restore its captured AX frame.
12. Report non-sensitive counts and outcome to the status item.

At transaction capture, `WindowSelectionStore` is reconciled against fresh
`RuntimeWindowKey` values from the whole topology and frozen for the remainder
of the transaction. Choices for a display outside the current pair stay in
memory until its runtime windows disappear. `DisplayPairSelectionStore` is
separate, process-local state: display rows choose transaction membership,
while the `All windows` child rows choose window participation.
Only selected captured windows reach the planner and applier. The coordinator
also retains the complete immutable pre-swap snapshot in memory for a future
undo feature; no AX handles persist beyond the transaction.

Never discover and mutate windows interleaved.

The focused-window command reads the AX-focused window from the frontmost
application after checking Accessibility trust, then matches its frame and
process ID to a Quartz window number. The runtime key is held for one command.
The coordinator captures the complete eligible batch and plans only that key,
ignoring the ordinary swap checkboxes. The same topology check, AX apply,
verification, restoration, and non-sensitive diagnostics govern the move.
The menu freezes the focused key when it opens so clicking its command cannot
retarget another window.
The status item also observes middle-button down/up events locally and globally.
It accepts a click only when button 2 starts and ends over the icon, freezing
the focused key at mouse-down before routing through the same targeted move.

`AccessibilityWindowService` owns OS-specific capability decisions. In
particular, a non-resizable window keeps its actual captured size; only its
planner-selected origin is clamped within the destination visible frame. The
pure mapping engine remains unaware of AX capabilities.
