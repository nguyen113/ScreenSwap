# Multiple-window swap regression — 2026-09-29

## Status

A candidate fix is implemented, tested, signed, installed, and running.
The latest installed build passed four consecutive swaps of two native Finder
half tiles, including two round trips. Overall physical acceptance remains
open: an earlier layout produced a 13-point Finder height mismatch, and the
quarter, overlapping-window, and true-native-zoom physical cases have not
passed their required four-swap gates. Do not declare the complete bug resolved
or merge based on the successful half-pair run alone.

## Baseline and initial evidence

The initial working tree was clean. `./build-test.sh` discovered and passed
76 tests. The historical six-test handoff describes an older checkout; the
macOS integration and click path already existed here.

The already-running installed app was used for capture and swaps through
`open -g 'screenswap://diagnostics'` and `open -g 'screenswap://swap'`.
No separate Accessibility window-moving process was created.

Two non-mirrored physical displays were active:

- ID 2, LG ULTRAFINE: physical 3840×2160; logical full frame
  `(0,0,1920,1080)`.
- ID 3: physical 2560×1600; logical full frame `(1920,267,1280,800)`.

Stage Manager remained enabled throughout. Initially the visible frames were
`(0,30,1920,968)` and `(1920,297,1280,770)`. Later captures also observed
`(0,30,1920,1050)` and `(1920,297,1280,688)`. No Stage Manager or Dock setting
was changed by the implementation or test automation.

The initial 06:54 ICT swap requested distinct left/right half frames. Both
raw AX zoom states were unknown, so it did not confirm the truthy-zoom
hypothesis. One window initially retained its old width despite successful
AX calls. On the requested repeat at 06:56, requested and AX readback half
frames were correct, but one window reported `result=not_visible`. The user
confirmed Finder was hidden in Stage Manager while Edge remained visible.

The initial diagnostic URL enabled unified logging but did not enable the
file sink. That inconsistency is fixed; subsequent evidence came from
`$TMPDIR/screenswap-diagnostics.log`.

## Implementation

- Capture an explicit ordinary, windowedMaximized, nativeZoomed, or
  nativeFullScreen semantic mode. A truthy green-button state requires
  source-visible-frame geometry before it becomes nativeZoomed. Half and
  quarter tiles remain ordinary and never press the zoom button.
- Keep raw presentation information separate. Retiling a previously maximized
  Quartz window to a half/quarter discards the retained maximization intent.
- Retain each captured PID/Quartz-window-number key transaction-locally,
  replacing/clearing the lookup on every capture and capture failure.
- Verify the exact captured identity. One same-app Quartz window cannot
  verify a different window with identical geometry.
- Verify full-size Quartz bounds as well as AX geometry. A thumbnail or a
  still-scaled Stage Manager animation does not establish visibility.
- Recheck the entire batch on each existing verification poll. A window that
  passed an earlier poll cannot stay cached as successful while another stage
  transition hides it. The existing deadline and polling interval are unchanged.
- After all planned writes, snapshot windows whose AX geometry is correct but
  whose exact identity is hidden. Attempt one AXRaise on each of those exact
  captured handles, then verify the entire batch again. If raising changes AX
  geometry, reapply that same planned frame once. Failed or ineffective recovery
  remains a verification failure, with the existing rollback policy.
- Scope Enhanced UI handling to ordinary/windowed geometry updates and restore
  its original value on success or failure. Preserve it when built-in VoiceOver
  or Switch Control is active. This addresses independently animated AX writes.
- Normalize at most two-point native half/quarter decoration discrepancies
  before the strict spanning check. The observed right half extended one point
  past the shared display boundary and was previously omitted. Genuine spanning
  windows remain untouched; ScreenSwapCore is unchanged.
- Use intersection over union for capture matching. A physical run exposed tiny
  Finder tooltip surfaces winning the previous containment match.
- Add opt-in PID, runtime-key presence, semantic mode, requested frame, exact
  identity, geometry, visibility, and Quartz-frame diagnostics. No titles or
  document names are logged.

The core public API, selected display-pair routing, per-window selection,
full-topology ownership/spanning checks, topology-change zero-write protection,
native-full-screen exclusion/safety boundary, and visibility-failure rollback policy are preserved.
No delay, frontmost-only routing, frame deduplication, global activation, or
native-group reconstruction was added.

## Automated gate

After rebasing the fix onto current main, `./build-test.sh`: **125 discovered,
125 passed**, zero failures. The Swift Testing parameterized cases execute in
addition to those discovered functions.
The full suite runs without physical displays or Accessibility authorization.
`git diff --check`: passed.

Added regressions cover the required two-half/four-quarter truthy-zoom models
through four swaps, true native zoom cleanup after an ignored resize, exact
same-app overlapping identities, a missing second identity, stale capture keys,
retiled maximization, native tile boundary decoration, tooltip/thumbnail matching,
80%-scaled animation rejection, Enhanced UI restoration, diagnostic file output,
bounded exact-window recovery, and batch re-verification across stage changes.
Existing native-zoom tests and native-full-screen exclusion tests pass. The old
truthy-zoom test fixture was corrected to actually fill the source visible
frame.

Evidence: `/tmp/screenswap-fix-tests.log`.

## Installation gate

`Packaging/pack-app.sh --install --replace`: passed. A fresh release was packaged,
signed using the existing stable ScreenSwap Local Development identity, installed
at `/Applications/ScreenSwapApp.app`, and launched. No ad-hoc signing was used.
`codesign --verify --deep --strict /Applications/ScreenSwapApp.app`: passed.
The installed process was confirmed running. Packaging evidence:
`/tmp/screenswap-pack-fix.log`.

## Physical runs

### Before targeted visibility recovery

A clean same-display Finder pair on ID 2 had native halves
`(0,30,960,1050)` / `(960,30,960,1050)`. Both were planned, requested as
separate destination halves, and had correct AX readbacks. One exact Quartz
identity became a thumbnail, ending around `(1801,625,75,114)`.
Verification detected notVisible and rollback ran. Subsequent swaps did not
restore a complete two-window round trip. This run failed.

Evidence: `/tmp/screenswap-final-four-swap-{1,2,3,4}.log` and
`/tmp/screenswap-physical-before-four.log`.

### Recovery build, first four-swap run

The pair started on ID 3 at `(1920,297,640,688)` /
`(2560,297,640,688)`. A windowed-maximized Code window started on ID 2.

1. Both Finder halves moved to ID 2 and verified. Code became a Stage Manager
   thumbnail; exact-window AXRaise brought it back to full-size visibility.
2. All three windows moved and verified.
3. Both Finder identities remained present, but one requested height 1050
   read back as 1037 after the existing size retry. Verification correctly
   remained pending and timed out. This is a geometry failure.
4. Both Finder identities remained visible, but the short height propagated
   to 679 instead of 688 on ID 3. The complete round-trip gate failed.

Evidence: `/tmp/screenswap-recovery-four-{1,2,3,4}.log` and
`/tmp/screenswap-recovery-fixture.log`.

This run also exposed verification accepting an approximately 80%-scaled
animation as full-size. That false-success risk was fixed and regression-tested
before the final installed-build run below.

### Latest installed build, four-swap half-pair run

The native Finder pair was reset on ID 3 to
`(1920,297,640,770)` / `(2560,297,640,770)`. Code was windowed-maximized on
ID 2. The visible frames stayed at heights 968 / 770 in these four captures.
Every command used the installed app's swap URL. All three distinct identities
matched full-size Quartz records at final verification on every swap.

| Swap | Finder destinations | Result |
| --- | --- | --- |
| 1 | ID 2: `(0,30,960,967)` / `(960,30,960,967)` | Both verified; one-point size adjustment within tolerance |
| 2 | ID 3: `(1920,297,640,770)` / `(2560,297,640,770)` | Both verified; original layout restored |
| 3 | ID 2: `(0,30,960,967)` / `(960,30,960,967)` | Both verified |
| 4 | ID 3: `(1920,297,640,770)` / `(2560,297,640,770)` | Both verified; second round trip restored |

Code also retained its full-visible-frame layout within one point. This specific
half-pair/windowed-maximized run passed the diagnostic gate. It does not establish
that the earlier 1050/688 layout or every Stage Manager configuration now passes.

Evidence: `/tmp/screenswap-strict-four-{1,2,3,4}.log` and
`/tmp/screenswap-strict-fixture.log`.

### Quarter-fixture attempt and cleanup

Two disposable Finder windows were created in temporary validation folders.
macOS's native quarter-arrangement command included Code rather than all four
Finder windows; two Finder windows remained hidden in a different stage. Capture
confirmed the fixture did not contain four eligible Finder quarters. No swaps
were counted against this invalid fixture. The two disposable windows were
closed; the original Finder pair was restored as native halves on ID 3 and the
Code fill geometry was restored. A final capture confirmed both Finder half
frames again at `(1920,297,640,770)` / `(2560,297,640,770)`.

## Physical gate still open

| Required case | Automated | Physical |
| --- | --- | --- |
| Two native same-app halves, four swaps | Pass | Latest layout passes; earlier taller layout fails height preservation |
| Four native quarters, four swaps | Pass | Incomplete fixture; not validated |
| Two same-app overlapping windows, four swaps and cycling | Pass | Not validated |
| True native zoom, four swaps | Pass | Not validated; windowed maximization was tested |
| Original mixed Edge/Finder Stage Manager disappearance | Exact recovery and detection covered | Initial failure reproduced; final mixed-app case not revalidated |

The remaining known failure is an AX-acknowledged Finder resize that settles
13 points short in the earlier layout. Stage Manager recovery is bounded and
cannot be assumed to preserve every stage/group configuration. No physical
acceptance claim should be inferred from passing fake tests.

## Handoff

- V1-00 completed for this bug-fix baseline: clean tree and 76 tests passing.
- V1-14 completed: 125 discovered/passed, zero failures, diff check passed.
- V1-01 through V1-13 are pre-existing integration work, not newly completed
  backlog items in this change.
- V1-15 remains incomplete for the specific failed/unvalidated physical cases
  above. Hardware is available; the limitation is physical behavior/setup.
- No merge, commit, or pull request was created.

Changed files:

- Sources/ScreenSwapMac/Accessibility/AccessibilityClient.swift
- Sources/ScreenSwapMac/Accessibility/AccessibilityWindowService.swift
- Sources/ScreenSwapMac/Accessibility/AccessibilityGeometryUpdateScope.swift
- Sources/ScreenSwapMac/Accessibility/CapturedPresentationMode.swift
- Sources/ScreenSwapMac/Accessibility/VisibleWindowMatcher.swift
- Sources/ScreenSwapMac/AppDependencies.swift
- Sources/ScreenSwapMac/Diagnostics/DiagnosticsConfiguration.swift
- Sources/ScreenSwapMac/Swap/SwapCoordinator.swift
- Sources/ScreenSwapMac/Swap/SwapTypes.swift
- Tests/ScreenSwapMacTests/Accessibility/AccessibilityWindowServiceTests.swift
- Tests/ScreenSwapMacTests/Accessibility/VisibleWindowMatcherTests.swift
- Tests/ScreenSwapMacTests/DiagnosticsConfigurationTests.swift
- Tests/ScreenSwapMacTests/Swap/CoordinatorTests.swift
- docs/validation/multiple-window-swap.md
