# Architecture

```text
StatusBarController --> SwapCoordinator
                         |       |
                         |       +--> AccessibilityAuthorizing
                         |       +--> DisplayProviding
                         |       +--> AccessibilityWindowService
                         |       |      (capture, apply, verify, restore)
                         |       +--> WindowMappingEngine (ScreenSwapCore)
                         |
                         +--> optional performance recorder
```

## Core principle

`ScreenSwapCore` owns deterministic domain models and geometry planning.

It must not depend on Accessibility APIs or status-bar UI.

## Swap transaction

1. Validate Accessibility permission.
2. Discover active displays.
3. Require exactly two displays.
4. Snapshot all eligible windows.
5. Detect windows that span both displays and exclude them from the move plan.
6. Assign each remaining window to a source display.
7. Compute the complete destination move plan.
8. Apply every planned move, continuing after individual failures.
9. Verify successful ordinary-window writes against both AX geometry and the
   Quartz on-screen window list.
10. If a window has the expected AX geometry but remains offscreen after the
    bounded verification window, best-effort restore its captured AX frame.
11. Report non-sensitive counts and outcome to the status item.

Never discover and mutate windows interleaved.

`AccessibilityWindowService` owns OS-specific capability decisions. In
particular, a non-resizable window keeps its actual captured size; only its
planner-selected origin is clamped within the destination visible frame. The
pure mapping engine remains unaware of AX capabilities.
