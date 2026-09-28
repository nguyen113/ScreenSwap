# ScreenSwap repository guide

This file contains stable architecture and contribution rules for ScreenSwap.
It is not a release plan or a historical implementation handoff.

## Product scope

ScreenSwap is a macOS 14+ menu-bar app that swaps eligible windows between one
selected pair of active displays. A Mac may have two or more connected
displays, but each transaction operates on exactly two selected displays; other
displays remain untouched.

The app includes per-window selection, a configurable global shortcut
(Control-Shift-S by default), settings, launch-at-login support, Accessibility
onboarding, About/support links, hover feedback that honors Reduce Motion, and
an in-memory pre-swap snapshot reserved for future undo support.

## Architecture

- `ScreenSwapCore` is the pure geometry and display/window mapping layer. Keep
  it free of AppKit, Accessibility, Quartz adapters, and UI code.
- `ScreenSwapMac` owns macOS integration: Accessibility, display discovery,
  selection, swap coordination, settings, hotkeys, diagnostics, and status UI.
- `ScreenSwapApp` is the thin executable bootstrap.
- Tests mirror this separation in `Tests/ScreenSwapCoreTests` and
  `Tests/ScreenSwapMacTests`.
- Do not add third-party dependencies without a clear, reviewed need.

## Transaction and privacy invariants

1. Use Quartz global coordinates end to end for Accessibility window geometry.
   Convert AppKit screen frames before creating `DisplaySnapshot` values.
2. Use stable `CGDirectDisplayID` values, never display-array positions, for
   display identity. Keep selection deterministic.
3. Check Accessibility trust before enumerating displays or windows. A missing
   permission must not mutate any window.
4. Capture every eligible window before planning or applying any move. Make the
   complete move plan before the first Accessibility write.
5. A spanning window stays untouched. Minimized, transient, non-movable, and
   unavailable windows are excluded.
6. A movable non-resizable window receives a position write only. When an
   operation cannot be verified, use the existing best-effort restoration path.
7. A failure for one window must not suppress later planned moves; report
   structured attempted, succeeded, and failed counts.
8. Treat Accessibility handles and `WindowID` values as transaction-local.
   Retain menu choices using `RuntimeWindowKey` (process ID plus Quartz window
   number), never titles.
9. Do not log window titles, document contents, credentials, or other private
   desktop data.

## Selection behavior

- With two active displays, they are the selected pair. With three or more,
  users select exactly two displays from the status-item menu.
- Per-window choices are retained by `RuntimeWindowKey` while the corresponding
  runtime window remains available. Display-pair selection is maintained
  separately using stable `CGDirectDisplayID` values.
- A selected window participates in the next swap only when it is eligible on
  the selected display pair.
- Native full-screen windows confirmed through Accessibility can be included
  automatically even when Quartz omits them. Other AX-only windows must be
  shown as unavailable rather than selected.

## Development and validation

Use the repository's canonical automated validation command:

```bash
./build-test.sh
git diff --check
```

`build-test.sh` locates `Testing.framework`, builds the package, verifies test
discovery is nonzero, and runs the suite. Do not substitute raw `swift test` as
the required gate because it may omit the framework configuration.

Add or update deterministic regression coverage for every behavior change.
Physical validation remains necessary for Accessibility permission, real
displays, full-screen windows, and macOS Spaces; record relevant manual results
in the pull request.

For local macOS integration work, package and launch the current build when
manual testing is needed:

```bash
Packaging/pack-app.sh --install --replace
open -g 'screenswap://swap'
```

The packaging script uses a stable local signing identity when available. If it
must use ad-hoc signing, Accessibility approval may need to be granted again.

## Repository hygiene

- Keep changes focused and preserve unrelated work already in the working tree.
- Do not commit `.DS_Store`, build products, DerivedData, local environment
  files, signing material, or credentials.
- Before publishing a release or changing repository visibility, run the
  documented checks and review both the current tree and reachable Git history
  for secrets.
- Treat `README.md`, `docs/ARCHITECTURE.md`, and the public behavior as the
  current product documentation. Update them with meaningful behavior changes.
