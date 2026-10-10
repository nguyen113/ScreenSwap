# ScreenSwap Icon Pack v3.1.3 — Connected menu-bar style

10 October 2026. Supersedes v3.1.2 for Call/Return templates.

## What changed

The user prefers the earlier connected pane-and-arrow composition in `Preferred-MenuBar-Reference.jpg`. The v3.1.2 redraw moved the arrows into the panes, shortened their heads and enlarged the outline openings. Those extra changes are removed.

- **Call** templates and all 13 frame masters are restored exactly from v3.1.1, including the filled arrowheads and the prior shaft-tip fix.
- **Return** keeps the preferred mirrored composition, arrow height, shaft, head and pane proportions from v3.1.1. Only the outline roles change: its lower-left source/main pane is solid and its upper-right destination/second pane is dashed. The arrow points from solid to dashed.
- Call's main pane is upper-left and its secondary pane is lower-right. Return's main pane is lower-left and its secondary pane is upper-right. Their horizontal main/secondary convention stays left/right; their overlap order follows the preferred mirrored composition.
- The head-shaped dot remains fixed: each shaft stops 1.1pt inside its filled head. Round caps on exposed shaft tails and rounded frame dashes are deliberate.
- All color artwork is byte-identical to v3.1.2, including its semantically corrected purple Return. Swap, Move Left/Right and Unavailable templates also remain unchanged.

This preserves the earlier appearance while correcting Return's meaning. It does not reproduce the older Return's reversed solid/dashed identities. The older screenshot is a style reference; the user's explicit main-solid / secondary-dashed requirement governs the semantics.

## Visual sources and previews

`Approved-Reference.png` remains the authority for the glossy blue Swap, orange Move and purple Call family. `Approved-Option-A-Reference.png` remains the authority for the Option A Swap menu-bar silhouette. `Preferred-MenuBar-Reference.jpg` is the new Call/Return style reference, preserved unchanged.

`ScreenSwap_Connected_Style_v3_1_3.png` shows enlarged vector shapes and fresh native AppKit light/dark enabled/disabled captures. `ScreenSwap_Style_Comparison_v3_1_3.png` compares the earlier style, v3.1.2 and this correction. View exact-pixel samples at 100% zoom. The enlarged blocks are diagnostic enlargements, not literal menu-bar dimensions.

## Operations and state

| Action | Meaning | Shape |
|---|---|---|
| Swap | Exchange eligible windows between the two selected displays | Overlapping panes and opposing arrows |
| Move Right / Left | Move the frontmost eligible target to the selected destination | Single directional arrow |
| Call | Bring the topmost eligible secondary window onto primary | Dashed second → solid main |
| Return | Restore the same called window to its captured secondary display and frame | Solid main → dashed second |
| Disabled / unavailable | Action cannot run | Static dim action glyph or slash-marked Unavailable |

Call captures stable window identity, owner, display identifier and original frame before moving. It fills the primary visible frame, accounting for Dock/menu bar; it must not create a native full-screen Space. Commit Return only after successful placement. Return restores that same window, not the currently frontmost window. Commit Call only after restoration succeeds. Keep recovery information on partial failures; never move a called window off-screen when the original display is disconnected. Prevent overlapping operations and conflicting Swap/Move until Return or Cancel unless the application implements explicit transaction handling.

Use exactly the two configured displays. Respect ScreenSwap's eligibility/exclusion rules and unsupported windows/Spaces. Move direction follows physical destination geometry; tooltips must name displays. Up/Down glyphs are not supplied for vertical layouts. Accessibility permission, window selection, operation serialization, persistent recovery and error handling belong to the app; these assets do not implement AX window movement.

## Assets and Xcode integration

Editable SVG masters are in `Sources/Color`, `Sources/Color-Compact`, `Sources/MenuBar` and `Sources/Motion`. They use genuine paths/gradients, not embedded raster images. Color SVG soft shadows may vary across editors. PNG exports in `Color/PNG` cover 16, 32, 64, 128, 256, 512 and 1024px, for all actions and Light/Dark/Disabled. The compact masters reduce decoration at small sizes. Native `.icns` and ten-slot `.iconset` resources are under `Color`.

Default templates are 18×18pt, exported as 18×18px @1x and 36×36px @2x. Optional 22pt exports are also supplied. Templates contain black RGB and alpha only; AppKit supplies appearance tint. Hover/pressed treatment is native.

Add `Xcode/ScreenSwapIcons.xcassets` to the app target, resolving any existing conflicting asset names. Select `AppIcon` for the permanent blue Swap Dock identity. Its ten macOS slots cover 16, 32, 128, 256 and 512pt, each @1x/@2x. Mode illustrations do not automatically replace or switch Dock icons.

Template names are `SwapTemplate`, `MoveRightTemplate`, `MoveLeftTemplate`, `CallTemplate`, `ReturnTemplate`, `UnavailableTemplate`. Per-action dimmed assets append `DisabledTemplate` to the action stem. Native disabled buttons use full-alpha templates with `isEnabled = false`. Clickable unavailable actions can use baked-alpha disabled templates with the button enabled, routing activation to help/selection; do not double-dim them.

`ScreenSwapStatusIcons.swift` is unchanged and main-actor isolated. Retain its presenter for the lifetime of the status item. Call `show(actualMode)` before a new operation and on failure; call `completed(operation, next: actualNextState)` only after success. Asset names and integration remain compatible with v3.1.2. Color imagesets (`SwapLight`, etc.) are explicit 128pt mode illustrations with @1x/@2x representations.

## Motion and Reduced Motion

Idle and disabled icons never animate. Successful-action feedback uses 13 frames, including resting endpoints, over 12 equal intervals: Swap 200ms, Move 180ms, Call/Return 220ms. Amplitude remains 0.45pt for this menu-bar family. Call points inward; Return nudges outward toward the dashed second display. Display outlines are static for Call/Return. Window movement never waits for feedback. Move's settled direction must be recomputed; Call settles on Return, Return on Call, and Swap on Swap.

The Swift presenter checks `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` before and during playback, observes accessibility changes and cancels movement when Reduced Motion turns on. It shows the successful final state immediately. New state or availability cancels older playback. Each operation must be serialized by the app.

GIFs are non-looping inspection previews with twelve 20ms intervals and a 700ms final hold, not production timing. Production uses the template frame imagesets (`CallMotion00` through `CallMotion12`, etc.) and durations in `Animations/Motion.json`. Never assign the GIF directly to the status item.

## Verification and limits

The final catalog compiled with Apple's macOS `actool`, deployment target macOS 13, with no warnings. The unchanged Swift presenter previously passed Swift 6 type-checking. Twenty fresh native `NSStatusBarButton` captures cover 18pt light/dark enabled/disabled rendering on macOS 26.6.2 Retina. Transparent captures are composited on neutral backgrounds; wallpaper/translucency contrast, older OS versions and live pressed states remain app checks. @1x samples are inspected at their actual pixel dimensions.

The audit decodes image assets, parses SVG/JSON, resolves SVG gradients/filters and catalog filenames/dimensions, checks black-alpha templates and disabled alpha, validates motion endpoints and ICNS decoding, and checks original-reference integrity. Additional checks prove that Call masters match the earlier version, Return's pane/arrow geometry is retained while outline roles change, and every color asset remains identical to v3.1.2. SHA-256 inventories archived bytes; final ZIP CRC and file hashes are verified. Detailed counts are in `Validation/Asset-Validation.json`.

The colored art remains a close vector reconstruction, not a pixel-exact reproduction of the painted reference. The new menu-bar redraw remains subject to visual review. No ScreenSwap project was supplied: full app build, AX behavior, screen-disconnect recovery, rapid clicks and runtime Reduced Motion lifecycle require integration testing.
