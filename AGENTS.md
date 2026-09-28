# ScreenSwap implementation handoff

## Standing local testing instruction

Whenever the app is updated, build a fresh release from the current workspace,
package it, install it at `/Applications/ScreenSwapApp.app`, and launch the
installed app so it is immediately available for testing. Use
`Packaging/pack-app.sh --install --replace`; if this Mac has no stable signing
identity, explicitly add `--allow-ad-hoc` and note that Accessibility
authorization may need to be granted again.

For this Mac, run `Packaging/create-local-signing-identity.sh` once when no
Apple Development identity is available. It creates a login-keychain-only
development identity and `pack-app.sh` automatically uses it for installed
builds, preserving Accessibility approval across local rebuilds.

For an automated manual test, invoke the already-running app's command path
with `open -g 'screenswap://swap'`. This uses the app's existing Accessibility
authorization; do not create a separate window-moving CLI process.

This file is the implementation brief for the next coding agent. Read it before
changing code. The immediate objective is a small, working macOS version in
which one left click on the menu-bar status item swaps eligible windows between
exactly two active displays.

## Scope for this handoff

Implement only the click-to-swap vertical slice described below.

In scope:

- macOS 14 or newer
- exactly two active displays
- one left click on the existing status item triggers one swap attempt
- proportional mapping through the existing `ScreenSwapCore`
- Accessibility permission check and explicit system prompt after a user click
- AX window discovery, filtering, snapshotting, and mutation
- position-only movement for movable but non-resizable windows
- concise status-item feedback for success, partial failure, missing permission,
  and unsupported display count
- deterministic unit tests plus a documented manual two-display check

Out of scope for this handoff:

- global hotkeys
- settings and launch at login
- hover or execution animation
- undo
- 3+ display routing
- right click, middle click, and scrolling
- packaging, signing, notarization, and release automation

`backlog.yml` is the older full-product backlog. Its CORE-001 through CORE-007
work is already implemented even though its status fields are stale. It also
contains a duplicate `MVP-FLOW-002` key. Do not execute that entire backlog and
do not regress the public interface in `docs/CORE_PUBLIC_API.md`.

## Current repository state

- `ScreenSwapCore` contains the geometry models and complete two-display move
  planner.
- `ScreenSwapApp` creates a status item, but its click action only prints a
  placeholder.
- The package builds and all 6 current Swift Testing tests pass.
- The current tests cover only part of the documented core matrix.
- The working tree may contain user-owned `.DS_Store` and `.gitignore` changes.
  Preserve all unrelated changes; never clean or reset them.

## Non-negotiable behavior

1. Use one coordinate system end to end. AX window positions use the Quartz
   global coordinate system. Convert `NSScreen.frame` and `visibleFrame` from
   AppKit coordinates before creating `DisplaySnapshot` values. A useful pure
   conversion is `quartzY = mainDisplayHeight - appKitRect.maxY`; cover displays
   placed above and below the main display in tests.
2. Resolve every display ID from `NSScreenNumber`/`CGDirectDisplayID`. Never use
   an array index as an ID. Sort snapshots by ID before selecting display A and
   display B so tie behavior is deterministic.
3. Check Accessibility trust before enumerating displays or windows. If trust
   is missing, mutate no windows. Because the click is an explicit user action,
   it may request the system Accessibility prompt once and tell the user to
   click again after granting access.
4. Require exactly two displays. For 0, 1, or 3+ displays, enumerate/mutate no
   windows and return a structured unsupported-count result.
5. Snapshot all eligible windows before planning or applying any move. Never
   interleave discovery and mutation.
6. Create one complete move plan with `WindowMappingEngine.makeSwapMoves` before
   the first AX write. Spanning windows must remain untouched; the core already
   omits them using full display frames.
7. Exclude minimized, non-movable, sheet/dialog/popover, and non-window AX
   elements. Keep movable non-resizable standard windows, but change position
   only. Isolate read failures to the affected application/window.
8. Do not identify or log windows by title. Use an opaque snapshot-local ID and
   retain an in-memory ID-to-`AXUIElement` lookup only long enough to apply that
   snapshot's plan.
9. A failure on one window must not stop later planned moves. Return attempted,
   succeeded, and failed counts. Do not log document names or window titles.
10. Keep UI/AppKit/Accessibility code out of `ScreenSwapCore`.

## Target structure

Add a testable macOS integration library instead of placing more logic beside
top-level `main.swift`:

```text
Sources/ScreenSwapCore/          existing pure geometry and models
Sources/ScreenSwapMac/           coordinator, protocols, AppKit/AX adapters, status UI
Sources/ScreenSwapApp/main.swift thin executable bootstrap only
Tests/ScreenSwapCoreTests/       pure core regression tests
Tests/ScreenSwapMacTests/        fake-based flow tests and pure conversion/filter tests
```

Update `Package.swift` so `ScreenSwapMac` depends on `ScreenSwapCore`, the
executable depends on `ScreenSwapMac`, and `ScreenSwapMacTests` depends on both
`ScreenSwapMac` and `ScreenSwapCore`. Moving the existing app delegate/status
controller into `ScreenSwapMac` is acceptable. Keep only process startup in the
executable target.

All macOS integration and UI types should be `@MainActor` unless a type is a
pure immutable value. Do not add a third-party dependency.

## Atomic implementation backlog

Complete tasks in order. Keep each checkbox small enough to implement and test
without combining unrelated behavior.

### V1-00 — Establish and preserve the baseline

- [ ] Run `git status --short` and record which pre-existing changes are not
  yours.
- [ ] Run `./build-test.sh`; confirm it lists 6 tests and then runs 6 tests.
- [ ] Do not edit public core signatures unless a later item explicitly requires
  a backward-compatible addition.

Done when the untouched baseline is understood and passes.

### V1-01 — Add a testable macOS target seam

- [ ] Add the `ScreenSwapMac` library target and `ScreenSwapMacTests` test target.
- [ ] Move status-item/app-delegate code as needed without changing click behavior
  yet.
- [ ] Reduce `ScreenSwapApp/main.swift` to application bootstrap.
- [ ] Add one bootstrap smoke test that imports `ScreenSwapMac` without creating
  a live status item.
- [ ] Run `./build-test.sh`.

Done when the executable builds and macOS integration logic can be imported by
tests.

### V1-02 — Finish the core regression matrix before OS integration

Add table-driven or narrowly named tests for the existing engine:

- [ ] normalization with an offset visible-frame origin
- [ ] normalization with menu-bar/dock insets
- [ ] projection from unequal resolution and unequal aspect ratio
- [ ] projection from landscape to portrait
- [ ] clamp at left, right, top, and bottom edges
- [ ] clamp a partially off-screen frame without changing its valid size
- [ ] center ownership on A, on B, and exactly on the shared boundary (A wins)
- [ ] empty input, mixed A/B input order, and unknown display ID omission
- [ ] spanning detection uses full `frame`, not `visibleFrame`
- [ ] a boundary-touching window is moved rather than considered spanning

Do not change correct engine behavior merely to simplify a test.

Done when all documented cases in `docs/TESTING.md` have deterministic coverage.

### V1-03 — Implement and test display coordinate conversion

- [ ] Add a pure rectangle converter from AppKit global coordinates to AX/Quartz
  global coordinates.
- [ ] Test a main-display rectangle, a display to the right, a display above,
  and a display below the main display.
- [ ] Test visible-frame insets independently of the full display frame.

Done when no live `NSScreen` object is required to test coordinate conversion.

### V1-04 — Add display discovery

- [ ] Define `DisplayProviding` with one operation that returns current
  `[DisplaySnapshot]` values.
- [ ] Implement the live provider with `NSScreen.screens`.
- [ ] Read each stable ID from `NSScreenNumber` as a `CGDirectDisplayID`.
- [ ] Convert both `frame` and `visibleFrame` using V1-03.
- [ ] Sort by stable display ID.
- [ ] Make malformed/missing screen IDs an explicit provider failure rather
  than silently inventing an ID.

Done when a fake provider can supply 0, 1, 2, or 3 displays and the live adapter
builds.

### V1-05 — Add Accessibility authorization

- [ ] Define `AccessibilityAuthorizing` with a non-prompting `isTrusted` check
  and a separate `requestAccess()` action.
- [ ] Implement `isTrusted` with `AXIsProcessTrusted()`.
- [ ] Implement the explicit prompt with
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- [ ] Prevent repeated prompt calls during one permission-required click path.

Done when trust and prompt behavior can be faked independently in tests.

### V1-06 — Define window capture/apply boundary types

- [ ] Add an immutable captured-window value containing the existing
  `WindowSnapshot` plus `isResizable`.
- [ ] Define `WindowProviding` to capture one complete batch and `WindowApplying`
  to apply one planned move by opaque `WindowID`.
- [ ] Define structured per-window read/apply failures without titles or document
  content.
- [ ] Define a result that distinguishes full success, partial success, no
  permission, unsupported display count, and already-running.

Done when coordinator tests can be written entirely with fakes and core values.

### V1-07 — Add small AX read helpers

- [ ] Wrap AX attribute reads for string, Boolean, `CGPoint`, `CGSize`, and
  `[AXUIElement]` values.
- [ ] Validate `AXValueGetType` before extracting point or size values.
- [ ] Wrap `AXUIElementIsAttributeSettable` for position and size.
- [ ] Unit test filter/classification decisions using plain captured attribute
  values; do not require Accessibility permission in automated tests.

Done when raw Core Foundation casts are isolated in one adapter/helper.

### V1-08 — Enumerate and filter eligible windows

- [ ] Enumerate running applications except ScreenSwap itself and terminated
  applications.
- [ ] Read each application's `kAXWindowsAttribute`.
- [ ] For each AX window, read role/subrole, minimized state, position, size,
  position-settable, and size-settable.
- [ ] Keep standard top-level windows; reject minimized, non-window,
  sheet/dialog/popover/transient, and non-position-settable elements.
- [ ] Treat size-settable as the `isResizable` capability; do not reject a
  movable window only because size is not settable.
- [ ] Convert position and size into a `CGRect` without applying another Y flip.
- [ ] Assign `sourceDisplayID` with the existing core center-point method.
- [ ] Continue after one app/window read fails.

Done when capture returns a complete immutable batch and performs no AX writes.

### V1-09 — Retain opaque handles for one capture batch

- [ ] Generate a unique snapshot-local `WindowID` from PID plus an opaque token;
  an AX identifier may be included but must not be assumed present or unique.
- [ ] Build a fresh `[WindowID: AXUIElement]` lookup for every capture.
- [ ] Replace the previous lookup only after the new capture completes.
- [ ] Never persist the lookup and never include titles in IDs/logs.

Done when every captured snapshot can be resolved for apply and stale IDs fail
cleanly.

### V1-10 — Apply one window move

- [ ] Resolve the AX element from the current capture lookup.
- [ ] If resizable, set destination size and verify the AX call result.
- [ ] Set destination position and verify the AX call result.
- [ ] For non-resizable windows, skip size and still set position.
- [ ] Return structured success/failure for each attempted move.
- [ ] Add adapter tests through a fake AX client that assert write values and that
  non-resizable windows never receive a size write.

Setting size before final position is preferred because applications may clamp
an intermediate origin using the old size.

Done when one failed AX write is reported without a crash or sensitive logging.

### V1-11 — Implement the coordinator guard path

- [ ] Add a `@MainActor` `SwapCoordinator` with injected authorization, display,
  window, and mapping dependencies.
- [ ] Reject a second request while a swap is active and clear the guard with
  `defer` on every exit path.
- [ ] Check trust first.
- [ ] Fetch displays only when trusted.
- [ ] Reject any display count other than two before window capture.
- [ ] Add tests for untrusted and 0/1/3-display paths that prove window capture
  and AX writes were not called.

Done when guard failures are structured results with zero mutations.

### V1-12 — Implement the coordinator transaction

- [ ] Capture the complete eligible-window batch once.
- [ ] Extract all `WindowSnapshot` values from that immutable batch.
- [ ] Ask the mapping engine for one complete plan once.
- [ ] Begin AX writes only after capture and planning both finish.
- [ ] Match each move to its captured resize capability.
- [ ] Attempt every move even after an earlier failure.
- [ ] Return attempted, succeeded, and failed counts.
- [ ] Test exact call order: trust -> displays -> complete capture -> complete
  plan -> apply.
- [ ] Test a mixed batch containing A, B, spanning, and non-resizable windows.
- [ ] Test that an apply failure does not suppress later attempts.

Done when fake-based tests prove snapshot/plan/apply are separate phases.

### V1-13 — Wire the status-item click

- [ ] Construct live dependencies once in the app delegate and inject the
  coordinator into `StatusBarController`.
- [ ] Configure the button to send the action for left mouse release only.
- [ ] Replace the placeholder print with exactly one coordinator call.
- [ ] On missing permission, explicitly call `requestAccess()` once and update
  the tooltip to tell the user to grant access and click again.
- [ ] On unsupported display count, update the tooltip with the required count.
- [ ] On success/partial failure, update the tooltip with non-sensitive counts.
- [ ] Always restore the button to an enabled state after the attempt.
- [ ] Add a controller-level test using fakes; do not create a real status item in
  routine unit tests if a smaller action-handler object gives the same coverage.

Done when one synthetic click produces one coordinator request and no deferred
interaction is introduced.

### V1-14 — Automated verification gate

- [ ] Run `./build-test.sh` from the repository root.
- [ ] Confirm test discovery lists all core and macOS tests.
- [ ] Confirm the final run reports the same non-zero number of passing tests and
  zero failures.
- [ ] Run `git diff --check`.
- [ ] Review `git diff` for titles, document content, hard-coded display IDs, or
  array-index display identity.

Do not run `swift build` and `swift test` concurrently against the same `.build`
directory; SwiftPM serializes them and the output becomes misleading.

Done when all automated checks pass from a clean process invocation.

### V1-15 — Manual two-display acceptance gate

Automated tests cannot prove real AX permission or multi-monitor behavior. Run
this on a Mac with exactly two active displays:

- [ ] Start with `swift run ScreenSwapApp` and confirm the status icon appears.
- [ ] With Accessibility disabled, click once; confirm no window moves and the
  system prompt/instruction appears.
- [ ] Grant access, restart if macOS requires it, and click again.
- [ ] Place normal movable windows from Finder, a browser, and Terminal on both
  displays; confirm they exchange displays proportionally.
- [ ] Confirm all windows were snapshotted before the first visible move.
- [ ] Put one window across both display frames; confirm it remains untouched
  while other windows move.
- [ ] Include a minimized window; confirm it remains untouched.
- [ ] Include a movable non-resizable/special window if available; confirm only
  its position changes and no crash occurs.
- [ ] Temporarily test with one display and, if available, three displays;
  confirm no windows move and feedback is concise.
- [ ] Rapidly click twice; confirm no overlapping transactions occur.
- [ ] Record display arrangement, resolutions, applications, expected result,
  actual result, and pass/fail in `docs/validation/first-click-swap.md`.

Done when the manual record exists and the click-to-swap path passes on physical
hardware. If hardware is unavailable, explicitly mark this task blocked; never
claim automated tests replace it.

## Required test discipline

- Use Swift Testing (`import Testing`, `@Test`, `#expect`) to match the project.
- Test public behavior and call ordering through fakes; do not require real AX
  permission or physical displays in automated tests.
- Every bug fixed during implementation must receive a regression test first or
  in the same change.
- Run `./build-test.sh` after every completed backlog item that changes code.
- A task is not complete if tests are skipped, filtered, undiscovered, flaky, or
  merely compile without executing.

## Final handoff report

Report:

- completed task IDs from V1-00 through V1-15
- files changed
- exact discovered/passed test count
- automated command results
- manual two-display result, or the explicit reason it remains blocked
- remaining limitations within the stated scope
