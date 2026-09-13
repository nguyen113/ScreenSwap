# Product

## Problem

People using a preferred larger display plus a smaller secondary display often keep their active work on one screen and progress/status information on the other. Changing focus means manually moving several windows.

## MVP promise

One click or one global shortcut swaps the eligible window layouts between exactly two active displays.

The layout should feel preserved even when the displays differ in resolution or aspect ratio.

## MVP

- macOS
- exactly 2 active displays
- menu-bar utility
- left click -> swap
- global shortcut -> swap
- proportional position/size preservation
- Accessibility permission onboarding
- short hover animation representing the swap
- graceful message when display count is not exactly 2

## Deferred

- 3+ monitors
- right click
- middle click
- scroll-wheel interactions
- display locking
- Windows

## Spanning windows

A window that has positive-area overlap with both displays is left in place during a swap. ScreenSwap does not move or resize it.
