# First-click swap validation

## Automated baseline history

Revision: b2590fc
Date: 2026-09-28
Result: 71 / 71 tests passed
Command: `./build-test.sh`
`git diff --check`: PASS

The historical validation entries below retain the test counts current when
those runs were performed. The current working tree adds fixed-size placement
and Space-visibility rollback coverage; its 2026-09-28 run reports 74 / 74
tests passed.

Status: **AX transaction validated; visual mixed-mode acceptance blocked by macOS Space assignment**

The automated suite validates the complete fake-based transaction and reports
69 discovered and passing tests. It cannot grant macOS Accessibility access,
observe real `NSScreen` arrangements, or safely move windows on physical
displays, so this record must be completed on a Mac before claiming V1-15.

## Manual run record

- Date: 2026-09-21 (partial environment validation), 2026-09-22 (mixed presentation-mode validation)
- macOS version (14+): macOS 14+ target confirmed by the installed app's `LSMinimumSystemVersion`; exact host version not recorded.
- Display arrangement and stable IDs: two active, non-mirrored displays detected; stable IDs not collected because the menu-bar-only installed app cannot be inspected through the available UI automation surface.
- Display resolutions and visible-frame insets: LG ULTRAFINE (main) 3840x2160 / UI 1920x1080 at 60 Hz; built-in Display 2560x1600 / UI 1280x800 at 60 Hz. Visible-frame insets not collected.
- Applications/windows used: the current ad-hoc ScreenSwap build was installed and running; no test windows were moved.
- Installed-app launch/liveness: pass — `/Applications/ScreenSwapApp.app` is a macOS 14+ LSUIElement app, its signature verified, and its process was running after replacement.
- Automation limitation: the available UI automation service cannot bind to an LSUIElement/status-only application and cannot enumerate the menu-bar button; a direct attachment attempt timed out. Its click could therefore not be targeted safely; no Accessibility setting or window position was changed.
- Build provenance limitation: the current source was built and installed on 2026-09-21, but its status-item click has not been physically exercised through the available automation surface.
- Outcome feedback finding: QA-BUG-001 is fixed in source. A click now presents an immediate transient status popover with a safe outcome message; the existing tooltip remains as supplemental feedback.
- Requested presentation behavior: keep the menu-bar widget unchanged; preserve both zoomed-window and macOS full-screen-Space state while exchanging displays. Recorded as QA-FEATURE-001; not yet physically validated.
- Update-authorization regression: QA-BUG-002 is fixed in the packaging flow but remains pending physical TCC persistence validation. Release/update installs now require a configured stable signing identity, ad-hoc development installs emit an explicit warning, and replacement stops any running `ScreenSwapApp` process before installing and launching the new bundle.
- Presentation-state regression: QA-BUG-003 has transition-completion and auxiliary/widget filtering in source. Ordinary applications may expose zoom/full-screen buttons without readable selected/value state; that state now remains unknown and follows the normal move path without toggling either control. Recorded as QA-BUG-004. Do not mark QA-FEATURE-001 or QA-BUG-003 physically validated until a two-swap round trip and ordinary-window swap both pass.
- Visible-window scope requirement: a swap now considers eligible windows from all non-terminated applications, but moves only AX windows that can be matched one-to-one with the Quartz on-screen window list. Stage Manager-hidden windows are skipped with a non-sensitive `notVisible` reason and never receive AX writes.
- Repeat-swap regression: QA-BUG-005 now has a stateful four-invocation fake-AX gate. It verifies visible ordinary and known-presentation windows move on every invocation, swaps 2 and 4 restore original geometry/state, Stage Manager-hidden windows remain untouched, and a prior partial failure does not poison the next swap.
- Second-switch diagnostic requirement: QA-BUG-006 now exposes per-invocation, non-sensitive capture/apply diagnostics. The installed bundle can enable them with `open -g 'screenswap://diagnostics'`; this runs within its existing Accessibility authorization and records no titles or document content.
- Repeated-swap coverage gap: first-swap behavior does not demonstrate stability. QA-BUG-005 requires a stateful four-invocation automated cycle and a four-click physical validation, with results recorded after each swap.
- Physical second-swap finding: the earlier failure is resolved for the unequal-display mixed-mode fixture. The 2026-09-22 fresh installed-build round trip below captured and applied both windows on the forward and return invocations.
- Delayed-geometry regression: an AX size write no longer waits for an immediate per-window readback before the matching position write is sent. This prevents background applications with delayed AX updates from being classified as failed before their move is fully dispatched; final verification remains asynchronous and bounded.
- Right-click menu behavior: QA-FEATURE-002 is implemented in source; manual installed-app validation remains pending.

### Mixed native/full-screen physical validation — 2026-09-22

- Installed build: `/Applications/ScreenSwapApp.app`, signed with the local
  stable development identity and launched by `Packaging/pack-app.sh --install
  --replace`.
- Displays: ID 2 main, frame `1920x1080`, visible frame `1920x968` with
  menu-bar/dock insets; ID 3 external, frame `1280x800`, visible frame
  `1280x770`.
- Windows: one Edge window in a native macOS full-screen Space and one Codex
  window maximized in the normal, windowed desktop. The two displays have
  unequal dimensions and visible-frame insets.
- Trigger: `open -g 'screenswap://swap'`, using the installed bundle's existing
  Accessibility authorization. Before/after captures were taken for both
  displays for each swap; native full-screen Spaces are verified by AX
  diagnostics because ordinary display screenshots show only the active Space.
- First mixed swap: **pass**. Both windows were captured. Edge moved to display
  1 and remained native full screen; Codex moved to display 2 and remained
  windowed-maximized.
- Return swap: **pass**. Both windows were captured again. Edge returned to
  display 2 still native full screen; Codex returned to display 1 still
  windowed-maximized.
- Evidence: `/private/tmp/screenswap-mixed-mode/20260922-002642-mixed-reverse-*.png`
  and `/private/tmp/screenswap-mixed-mode/20260922-002717-mixed-roundtrip-*.png`.
  The corresponding diagnostics recorded two eligible windows on both
  invocations and destination targets of the complete display frame for native
  full screen and the visible frame for windowed maximization.
- Result at the time: the AX transaction completed. This did not prove visual
  acceptance; the later user-provided before/after captures supersede the
  earlier pass claim below.

### Fresh installed-build mixed-mode round trip — 2026-09-22 00:50–00:51 ICT

- Build: current workspace packaged, signed, installed, and relaunched with
  `Packaging/pack-app.sh --install --replace`; the installed bundle retained
  its existing Accessibility authorization.
- Setup: one windowed-maximized standard window on display ID 3 and one native
  full-screen standard window on display ID 2. Display 2 full/visible frames
  were `1920x1080` / `1920x968`; display 3 full/visible frames were `1280x800`
  / `1280x770`.
- Diagnostic mode: enabled through `open -g 'screenswap://diagnostics'` in the
  already-authorized installed app. Its capture records opaque ordinals,
  geometry, display IDs, and presentation state only.
- Forward invocation: `20260922-005021-final-roundtrip-forward`. The
  windowed-maximized window moved ID 3 → ID 2 and was applied to
  `x=0,y=30,w=1920,h=968`. The native full-screen window moved ID 2 → ID 3,
  exited full screen, was positioned on the destination, and its direct AX
  full-screen restore was confirmed.
- Return invocation: `20260922-005048-final-roundtrip-return`. The
  windowed-maximized window moved ID 2 → ID 3 and was applied to
  `x=1920,y=297,w=1280,h=770`. The native full-screen window moved ID 3 → ID
  2 and its full-screen restore was confirmed. A settled read-only capture
  then reported the windowed candidate as `full_screen=false` on ID 3 and the
  native candidate as `full_screen=true` with full frame `1920x1080` on ID 2.
- Screenshots: before and after each invocation were saved as
  `/private/tmp/screenswap-mixed-mode/20260922-005021-final-roundtrip-forward-*.png`
  and
  `/private/tmp/screenswap-mixed-mode/20260922-005048-final-roundtrip-return-*.png`.
  Because macOS renders native full screen in a separate Space, AX state and
  destination geometry are the conclusive proof for that mode; the screenshots
  visually confirm the distinct windowed versus native-full-screen surfaces.
- Result at the time: AX reported a pass. The later visual evidence below
  invalidates this as a physical acceptance result.

### Repeat after system sleep — 2026-09-22 05:59–06:00 ICT

- The same installed app and fixture were retested after a `pmset sleepnow`
  sleep/wake cycle. Both swaps again captured two eligible windows.
- Forward evidence:
  `/private/tmp/screenswap-mixed-mode/20260922-055941-retest-after-sleep-forward-*.png`.
  Return evidence:
  `/private/tmp/screenswap-mixed-mode/20260922-060004-retest-after-sleep-return-*.png`.
- Result at the time: AX reported the expected state. The later visual evidence
  below invalidates this as a physical acceptance result.

### Final all-display capture — 2026-09-22 06:07 ICT

- Captured both physical displays before and after one installed-app URL swap:
  `/private/tmp/screenswap-final-layout-test/20260922-060730-one-last-test-*.png`.
- Before: the windowed-maximized window was on ID 2 at its visible frame and
  the native full-screen window was on ID 3. After: their destinations and
  modes were reversed. The AX trace captured two eligible windows, confirmed
  both native-full-screen transitions, and the settled capture reported the
  windowed candidate on ID 3 and native full-screen candidate on ID 2.
- Result at the time: AX reported a pass. The subsequent user-provided visual
  capture shows the ordinary window was not visible on the destination, so this
  is not a physical pass.

### Visual acceptance correction — 2026-09-22 06:10 ICT

- User-provided before/after captures show a windowed Codex window on the main
  display before the swap. After the swap, the visible surfaces are two Notes
  windows; Codex is not visible on the external display.
- Environment detail: the main display has three macOS desktop Spaces while
  the external display has one. With separate Spaces, public Accessibility
  APIs can set an individual window's global frame but cannot assign that
  window to a destination display's active desktop Space.
- Conclusion: the AX geometry and full-screen transition reports are necessary
  but insufficient for visual acceptance. The windowed Codex frame can be
  positioned on the external display while remaining associated with an
  inactive Space on the main display. Native full-screen transitions can make
  that mismatch visible as the old app surface remaining on the target.
- Result: **blocked** for swapping visible windows across displays with unequal
  per-display Space counts. Reliable per-window Space migration requires
  private WindowServer/Dock APIs or UI automation of Mission Control, neither
  of which belongs in this accessibility-based application. Do not report this
  scenario as physically passing or retry it without changing the Space setup.

### Visibility-verification regression — 2026-09-22 06:23 ICT

- Change: after a normal window's AX position and size match its destination,
  measured swaps now also require a one-to-one Quartz on-screen match. Native
  full-screen windows remain exempt because Quartz can omit their dedicated
  Space despite AX-confirmed full-screen state.
- Automated coverage: `accessibilityServiceDoesNotVerifyWindowHiddenInAnotherSpace`
  models the failure mode where AX retains the destination frame while Quartz
  no longer reports the ordinary window as visible. The full suite passed with
  69 tests.
- Physical repeat: captures in
  `/private/tmp/screenswap-visibility-test/20260922-062310/` again showed the
  ordinary maximized window absent from its destination surface. The installed
  app logged `result=not_visible` for that window throughout its bounded
  verification period, so the measured result is a partial failure rather than
  a false success.
- Result: the implementation now reports this unsupported multi-Space outcome
  honestly, but cannot repair the underlying macOS Space assignment.

### QA-FEATURE-001 implementation note

The macOS integration captures presentation state from public AX button
elements and their readable selected/value state. When a state is known, the
adapter exits it, moves/resizes the window, and restores it on the destination;
zoomed windows use the destination visible frame. AX does not provide one
universal reliable zoom-state attribute across applications, so any non-full-
screen window that substantially fills its source display's visible frame also
preserves that visible-frame geometry on the destination without pressing an
unverified zoom control. Other windows retain the core's proportional mapping.
Full-screen state is never inferred from bounds.

When macOS adjusts an unequal-display destination frame between clicks, the
integration retains maximized intent only through the next capture using the
opaque Quartz window-server number already returned by the on-screen list. It
does not retain AX handles, titles, document names, or window content.

### QA-BUG-003 implementation note

Known zoom/full-screen transitions now wait for AX state confirmation before
geometry writes and after restoration. Geometry writes are also observed before
the next presentation action. If a transition or presentation state cannot be
confirmed within the bounded policy, that window is left untouched or returned
as a structured failure. AX windows with auxiliary subroles or known
Notification Center/Dock/Control Center hosts are excluded before planning.
Unreadable presentation state is deliberately not excluded: it follows the
normal geometry path and never presses either presentation control.

### QA-FEATURE-002 implementation note

The status button listens for left and right mouse-up independently. Left
mouse-up invokes the existing measured swap path exactly once. Right mouse-up
opens a native `NSMenu` containing only `Exit ScreenSwap`; it never invokes
the swap path. Selecting that item terminates the current ScreenSwap process
through `NSApplication`, without sending termination requests to other apps.

### QA-BUG-001 implementation note

`StatusItemFeedbackCatalog` maps every structured swap outcome to a
non-sensitive title and message. `StatusPopoverFeedbackPresenter` displays
that payload immediately after the click without changing the status icon,
placement, or enabled appearance. Automated coverage verifies success, partial
failure, missing permission, unsupported display count, and already-running
payloads.

### QA-BUG-002 implementation note

`Packaging/pack-app.sh` accepts a stable identity through
`--signing-identity` or `SCREENSWAP_SIGNING_IDENTITY`. `--release` and
installed builds require that identity unless the developer explicitly opts
into `--allow-ad-hoc`; ad-hoc builds warn that macOS may require Accessibility
authorization again after an update. Replacement waits for every
`ScreenSwapApp` process to exit before removing the installed bundle, then
launches the newly installed app. Automated checks cover shell syntax, help
output, and the missing-identity guards. They do not prove TCC persistence.

### Automated-test limits

The fakes intentionally model a readable application list, a deterministic
Quartz on-screen window list, synchronous AX frame writes, and deterministic
presentation-button state changes. macOS can instead delay AX updates, expose
a button without a readable state, or virtualize windows through Stage
Manager. The tests therefore validate the visibility gate and modeled states,
but cannot establish first- or second-click behavior on physical hardware.

### Remaining manual scenarios

- Accessibility initially disabled and prompt/click-again behavior: not run; changing the system Accessibility setting was intentionally avoided.
- Proportional two-display exchange, snapshot-before-first-move, spanning, minimized, and movable non-resizable cases: not run because the status-item click could not be targeted.
- One-display/three-display and rapid double-click guard paths: covered by automated fakes; physical check pending.
- QA-BUG-003 exact regression: repeat two swaps with maximized/full-screen windows and desktop widgets; confirm the second swap returns to the pre-first-swap arrangement and widgets never move.
- QA-BUG-005 manual check: perform four alternating swaps with visible ordinary and zoomed/full-screen windows from more than one app; confirm swaps 2 and 4 restore the original arrangement, then induce or observe one partial failure and confirm the following click succeeds.
- Maximized-window manual check: maximize a standard zoom-capable window on
  each display, swap, and confirm each one fills the destination display's
  visible frame even when its AX zoom-button state is unavailable. Repeat the
  swap to confirm unequal display resolutions do not turn it into a
  proportional-sized window.
- QA-BUG-006 diagnostic check: use a freshly built installed app, enable the
  already-authorized app's safe trace with `open -g 'screenswap://diagnostics'`,
  then perform the first and second swaps. Record only opaque ordinals,
  display geometry, presentation state, and aggregate counts; do not record
  titles, document names, or AX identifiers.
- QA-FEATURE-002 manual check: right-click the installed status item, confirm
  `Exit ScreenSwap` appears, confirm no swap occurs, then select it and confirm
  only ScreenSwap exits. Relaunch and left-click once to confirm the normal swap
  path remains unchanged.
- QA-FEATURE-003 manual check: arrange visible movable windows from App A and
  App B across both displays, then place a third app's windows in a hidden
  Stage Manager group. Click once; confirm visible App A and App B windows move
  while every hidden group window remains untouched.
- Overall result: the mixed-mode URL-triggered physical acceptance remains
  blocked by macOS Space assignment. The installed app now detects and reports
  the visible-window failure as partial rather than success. The broader V1-15
  manual matrix, including a human-operated menu-bar-click check, remains
  pending.

## Procedure

1. Run `swift run ScreenSwapApp` with exactly two active displays.
2. Disable Accessibility for ScreenSwap, click once, and confirm no window moves and the system prompt/instruction appears.
3. Grant access, restart if macOS requires it, and click again.
4. Place normal movable windows from Finder, a browser, and Terminal on both displays. Confirm they exchange proportionally.
5. Zoom a standard Finder, browser, or Terminal window so it fills the source display's visible frame. Swap and confirm it fills the destination display's visible frame and remains zoomed.
6. Put a browser or Terminal window into a macOS full-screen Space. Swap and confirm it is restored as full screen on the destination display.
7. Put one window across both full display frames, minimize another, and include a movable non-resizable/special window if available. Confirm the documented exclusions and position-only behavior.
8. Temporarily test one and, if available, three displays. Confirm no windows move and the status feedback is concise.
9. Rapidly click twice and confirm there are no overlapping transactions.
10. For the visible-window scope check, place windows from multiple apps on
    the displays and hide a separate app's group in Stage Manager. Record that
    every visible eligible window moves and every hidden-group window receives
    no movement.
11. For the second-click diagnostic run, stop any older ScreenSwap process,
    build the current source, and launch the resulting executable with
    `SCREENSWAP_DIAGNOSTICS=1 "$(swift build -c release --show-bin-path)/ScreenSwapApp"`.
    Capture the two safe `[ScreenSwapPerf]` lines described above before making
    a pass/fail claim. If the existing Accessibility grant applies only to the
    installed bundle, rebuild/install with the same stable signing identity
    before this check; do not change the system permission setting merely to
    obtain a test result.
12. For the update regression check, configure a stable Developer ID
    Application identity and build/install with
    `Packaging/pack-app.sh --release --install --replace
    --signing-identity "Developer ID Application: Example"`.
13. Grant Accessibility access to the installed app, perform a successful
    swap, build a newer version with the same identity, and repeat the
    replacement command while the app is running.
14. Confirm the old process stops, the new process launches, the existing
    System Settings authorization remains associated, and the new process can
    swap windows without a second grant. Record the actual signing identity,
    designated requirement, and pass/fail result.
