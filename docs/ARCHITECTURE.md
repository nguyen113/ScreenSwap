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
       +--> GlobalHotKeyService --> same left-click swap action
       +--> Settings / About windows
```

## Core principle

`ScreenSwapCore` owns deterministic domain models and geometry planning.

It must not depend on Accessibility APIs or status-bar UI.

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

`AccessibilityWindowService` owns OS-specific capability decisions. In
particular, a non-resizable window keeps its actual captured size; only its
planner-selected origin is clamped within the destination visible frame. The
pure mapping engine remains unaware of AX capabilities.
