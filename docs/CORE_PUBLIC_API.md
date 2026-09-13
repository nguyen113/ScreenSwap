# CORE-001…CORE-006 Public API Contract

This contract exists so independent implementations can be evaluated by the same external black-box test suite.

It defines **interface names and observable behavior**, not implementation details.

All three benchmark arms must preserve this contract.

## Types

### `NormalizedWindowGeometry`

A public `Equatable` and `Sendable` value type with four `Double` properties:

```swift
public let x: Double
public let y: Double
public let width: Double
public let height: Double
```

and a public initializer accepting all four values.

The values are normalized relative to a display's `visibleFrame`.

### Existing models

Keep the existing public models:

- `DisplaySnapshot`
- `WindowID`
- `WindowSnapshot`
- `WindowMove`

## `WindowMappingEngine`

Create a public `Sendable` value type:

```swift
public struct WindowMappingEngine: Sendable
```

with a public empty initializer.

It must expose the following methods.

### 1. Normalize

```swift
public func normalize(
    windowFrame: CGRect,
    in sourceVisibleFrame: CGRect
) -> NormalizedWindowGeometry
```

Observable behavior:

```text
x      = (window.minX - source.minX) / source.width
y      = (window.minY - source.minY) / source.height
width  = window.width / source.width
height = window.height / source.height
```

Normalization itself does **not** clamp values.

For this MVP benchmark, callers provide positive non-zero visible-frame width and height.

### 2. Project

```swift
public func project(
    normalized: NormalizedWindowGeometry,
    onto destinationVisibleFrame: CGRect
) -> CGRect
```

Observable behavior:

```text
x      = destination.minX + normalized.x * destination.width
y      = destination.minY + normalized.y * destination.height
width  = normalized.width * destination.width
height = normalized.height * destination.height
```

Projection itself does **not** clamp.

### 3. Clamp

```swift
public func clamp(
    frame: CGRect,
    to destinationVisibleFrame: CGRect
) -> CGRect
```

Observable behavior:

- If projected width exceeds destination width, width becomes destination width and X becomes destination minX.
- If projected height exceeds destination height, height becomes destination height and Y becomes destination minY.
- Otherwise preserve width/height and clamp origin so the whole frame fits inside the destination visible frame.
- A frame already fully inside the destination remains unchanged.

Do not invent an OS-specific minimum window size.

### 4. Assign a window to one of two displays

```swift
public func sourceDisplayID(
    for windowFrame: CGRect,
    displayA: DisplaySnapshot,
    displayB: DisplaySnapshot
) -> UInt32
```

Use the **window center point**.

- center inside only A -> A
- center inside only B -> B
- exact tie/shared-boundary case -> **displayA wins deterministically**

The benchmark uses two display frames that are sufficient to resolve ownership under these rules.

### 5. Build the complete swap plan

```swift
public func makeSwapMoves(
    windows: [WindowSnapshot],
    displayA: DisplaySnapshot,
    displayB: DisplaySnapshot
) -> [WindowMove]
```

Observable behavior:

- Preserve input order among windows that produce moves.
- Before mapping, detect whether a window has **positive-area intersection with both `displayA.frame` and `displayB.frame`**.
- Such a spanning window is omitted from the returned move plan and therefore remains untouched.
- Merely touching a display boundary is not spanning.
- Spanning detection uses the full display `frame`, not `visibleFrame`.
- A non-spanning window whose `sourceDisplayID == displayA.id` maps to B.
- A non-spanning window whose `sourceDisplayID == displayB.id` maps to A.
- Normalize using the source display `visibleFrame`.
- Project onto the destination display `visibleFrame`.
- Clamp the projected result.
- Input snapshots are not mutated.
- Empty input returns an empty array.
- A window whose `sourceDisplayID` matches neither A nor B is omitted from the returned plan.

The engine returns a plan only. It must not call AppKit window APIs or Accessibility APIs.
