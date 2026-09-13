# Architecture

```text
StatusBarController --------\
HotKeyService ---------------+--> SwapCoordinator
                              |       |
                              |       +--> DisplayService
                              |       +--> AccessibilityWindowService
                              |       +--> WindowMappingEngine (ScreenSwapCore)
                              |
IconAnimationController ------/  visual feedback only
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
8. Store an in-memory pre-move snapshot for future undo architecture.
9. Apply moves.
10. Report success/failure to UI.

Never discover and mutate windows interleaved.
