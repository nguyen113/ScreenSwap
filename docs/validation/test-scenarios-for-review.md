# ScreenSwap: Mac with two screens — test cases for review

Updated 2026-09-22. **Review draft; no tests executed in this task.**

This plan focuses on one Mac running macOS 14+ with exactly two active,
non-mirrored screens. It replaces the previous broad checklist. Every case
keeps both screens connected. Tests for other display counts, distribution,
and unrelated product features are outside this review.

## Shared setup and pass criteria

- Use `/Applications/ScreenSwap.app` built from the workspace under test.
  Record build identity, macOS version, Accessibility authorization, and whether
  “Displays have separate Spaces” and Stage Manager are enabled.
- Label the physical screens **A** and **B** by ascending stable display ID;
  record which is built-in/external and which is primary. A does not necessarily
  mean the primary or left screen.
- Record both full frames and visible frames in Quartz coordinates, in logical
  points, plus display scaling. Do not calculate geometry from pixel resolution.
- Start with extended desktop, Stage Manager off, and ordinary desktop Spaces.
  Enable special modes only in the cases that require them.
- Use disposable Finder, browser, Terminal, and Notes windows. Give windows
  test-record aliases W1, W2, etc.; do not use their titles as identifiers.
- Inventory every eligible on-screen window before testing. ScreenSwap acts on
  all eligible windows, so an extra visible app changes expected counts.
- Unless a case says otherwise, grant Accessibility access, place one ordinary
  resizable window on each screen, and wait for animations to settle.
- **Trigger:** one left mouse release on the status item. For geometry automation,
  Codex may use `open -g 'screenswap://swap'` through the already-running app.
  Record which trigger was used; URL results do not prove mouse routing.
- **Swap cycle:** capture initial state S0; trigger and record S1; wait until the
  transaction completes; trigger and record S2; repeat for S3 and S4. Do not
  reposition windows between these four invocations.
- Normal eligible windows go to the opposite screen. Expected position and size
  come from normalized source-visible-frame geometry projected into the
  destination visible frame, then clamped by ScreenSwapCore. Compare all four
  frame components with a 2-point tolerance for ordinary resizable windows.
- For unchanged layouts and unconstrained geometry, S2/S4 should match S0 and
  S3 should match S1. Clamping, app minimum sizes, and fixed-size windows can
  make the mapping irreversible: compare each step to its own expected target
  instead of promising an exact return to S0.
- Excluded windows must retain frame and presentation state. Every planned
  window must be accounted for; attempted = succeeded + failed. AX write
  acceptance alone is insufficient evidence of physical movement.
- Record PASS, FAIL, BLOCKED with reason, or NOT RUN. Unavailable window types
  or hardware arrangements are BLOCKED, never assumed to pass.

**Priority:** P0 = essential acceptance and repeat-swap regressions;
P1 = two-screen compatibility and recovery. A case is one scenario; explicitly
listed variants receive separate result records. **Physical** means the installed
app on real displays; **Fake** means deterministic Swift Testing coverage.

## Essential two-screen behavior

| ID | Priority / method | Setup | Action | Expected result |
|---|---|---|---|---|
| TS01 | P0 · Physical | W1 on A and W2 on B; ordinary medium windows, no spanning. | Perform one swap cycle. | W1 goes A→B→A→B→A; W2 goes B→A→B→A→B. Each frame matches its target, including clicks 2 and 4; no missing or duplicated moves. |
| TS02 | P0 · Physical | Two browser windows on A, Finder and Terminal windows on B; only one app focused. | Perform one swap cycle. | All four eligible windows move every time, including background-app windows and both windows from the same app. |
| TS03 | P0 · Physical | Put all eligible windows on A; B has none. Repeat with all on B. | Two swaps per variant. | First swap transfers all windows to the empty screen; second transfers them back. Empty source side does not block the operation. |
| TS04 | P0 · Physical | Small, medium, tall/narrow, and large ordinary windows distributed across A/B; keep below maximization threshold. | Perform one swap cycle. | Each retains proportional placement/size subject to explicit app constraints; no window is omitted because of its size. |
| TS05 | P0 · Physical | Minimize all test windows and remove other eligible windows from the active desktop. | Trigger twice. | Both invocations report no eligible moves; minimized windows remain minimized; no false success claiming moved windows. |
| TS06 | P0 · Physical | W1 on A, W2 on B. | Swap once; manually resize/reposition W1 within its new screen, close W2, and open W3; swap again. | Second swap uses fresh positions and inventory: W1 maps from its new frame, W3 participates, and closed W2 is not targeted. |

## Window eligibility and boundaries

| ID | Priority / method | Setup | Action | Expected result |
|---|---|---|---|---|
| TS07 | P0 · Physical + Fake | One ordinary window overlaps positive area on both full screen frames; another window is wholly on each screen. | Perform one swap cycle. | Spanning window never moves/resizes; the two ordinary windows exchange normally. Fake variant covers overlap only in menu-bar/Dock regions. |
| TS08 | P1 · Physical + Fake | Window touches the shared screen edge exactly without crossing; run once from each side. | Swap and return. | Touching window is eligible and moves; zero-area contact is not spanning. |
| TS09 | P0 · Physical | Minimized W1, ordinary W2 and W3 on opposite screens. | Swap twice, then restore W1. | W2/W3 swap normally. W1 remained minimized and retains its pre-test frame when restored. |
| TS10 | P1 · Physical + Fake | Movable, non-resizable standard window on A, then B; choose a window whose unchanged size fits both screens. | Swap twice per variant. | Only position changes; width/height stay constant. Fake AX trace contains no size writes for this window. |
| TS11 | P1 · Physical + Fake | Sheet/dialog/popover plus ordinary eligible window in another app. Test each excluded type separately. | Swap and return. | Excluded element receives no direct geometry writes; ordinary window moves. A sheet may follow its parent through macOS behavior, which must not be mistaken for a direct ScreenSwap write. |
| TS12 | P0 · Physical + Fake | Desktop widgets visible; ordinary windows on A/B. | Perform one swap cycle. | Ordinary windows move; widgets and system auxiliary windows receive no moves or presentation actions. |
| TS13 | P0 · Physical + Fake | Enable Stage Manager; record visible ordinary windows across apps plus one window in an inactive group. | Perform one swap cycle, then activate the hidden group to inspect it. | Eligible visible windows swap; inactive-group window received no writes and retains its geometry. Re-record visibility before each invocation. |

## Maximized and native full-screen windows

Windowed maximization means filling the visible desktop while staying in its
ordinary Space. Native full screen means a macOS full-screen Space. Verify these
states separately; a screenshot of the ordinary desktop cannot prove where a
native full-screen window is located.

| ID | Priority / method | Setup | Action | Expected result |
|---|---|---|---|---|
| TS14 | P0 · Physical + Fake | Windowed-maximized W1 on A; ordinary W2 on B. Use unequal visible-frame sizes. | Perform one swap cycle. | W1 fills destination visible frame each time and remains windowed; W2 follows proportional mapping. Return swaps preserve maximization. |
| TS15 | P0 · Physical + Fake | Windowed-maximized window on each screen; include differing Dock/menu-bar insets. | Perform one swap cycle. | Both fill their respective destination visible frames on every invocation, without shrinking into ordinary proportional windows on return. |
| TS16 | P1 · Physical + Fake | Visually maximized window with unavailable AX zoom state; fake missing state if no suitable live app exists. | Swap and return. | Destination visible-frame geometry is preserved without pressing an unverified zoom control; no native full-screen inference from bounds. |
| TS17 | P0 · Physical + Fake | Native full-screen W1 on A; ordinary W2 on B. Record Space configuration and full-screen state. | Perform one swap cycle; inspect W1's destination Space after each swap. | W1 relocates to opposite screen and restores native full screen each time; W2 remains ordinary. Temporarily locked AX geometry does not silently omit W1. |
| TS18 | P0 · Physical + Fake | Native full-screen browser on one screen; windowed-maximized Codex or another app on the other. | Perform one swap cycle. | Both are captured and moved on all four invocations; native full screen and windowed maximization remain distinct, including clicks 2 and 4. |
| TS19 | P1 · Physical + Fake | Native full-screen window on each screen. | Perform one swap cycle. | Both exchange physical screens and retain native full-screen state. Confirm through AX state plus destination-Space inspection, not desktop screenshots alone. |

## Two-screen layouts and usable geometry

Reset the fixture after each layout change. Keep exactly two active screens.
For each case use one ordinary window on each screen; perform a full swap cycle.

| ID | Priority / method | Setup / variants | Expected result |
|---|---|---|---|
| TS20 | P0 · Physical + Fake | Unequal landscape sizes and scaling; external screen to the right. | Proportional geometry uses logical visible frames, not physical pixels; four swaps remain correct. This is the default acceptance configuration. |
| TS21 | P1 · Physical + Fake | External screen left of main screen, with negative X origin. | Correct opposite-screen placement; no sign errors or off-screen destinations. |
| TS22 | P1 · Physical + Fake | External screen above main; separately below main. | Correct Quartz Y conversion in both variants; no vertical mirroring or double Y flip. |
| TS23 | P1 · Physical + Fake | One landscape and one portrait screen. | Both directions preserve normalized geometry with expected clamping. |
| TS24 | P1 · Physical + Fake | Change primary screen between completed cycles; separately focus an app on the non-primary screen without changing primary. | Physical destination stays correct; focused screen is not mistaken for coordinate origin or stable display identity. |
| TS25 | P1 · Physical + Fake | Windows at left/right/top/bottom edges and each corner, on each screen. Also test partly outside the desktop's outer edge without spanning. | Destination is clamped to its usable frame; valid dimensions are preserved. Compare per-step targets if the starting frame is clipped. |
| TS26 | P1 · Physical + Fake | Dock on bottom/left/right and auto-hide on/off where supported; record new visible frames before each cycle. | Geometry honors current usable area. Windowed-maximized windows fill the destination visible frame, excluding reserved insets. |
| TS27 | P1 · Physical + Fake | Resizable app window with a minimum size larger than its proportional target on the smaller screen. | Record requested and actual frame; do not report verified success outside tolerance. Other windows still move. Treat the app constraint as an explicit compatibility limitation, not a reason to weaken all geometry checks. |

## Permissions, interaction, and recovery with both screens connected

| ID | Priority / method | Setup | Action | Expected result |
|---|---|---|---|---|
| TS28 | P0 · Physical + Fake | Accessibility disabled; windows on both screens. | Click once; grant access; wait without clicking; then explicitly click again (restart if required by macOS). | First click moves nothing and prompts once with clear guidance. Grant alone does not trigger a delayed swap. Next explicit click swaps. Fake trace proves trust check precedes enumeration. |
| TS29 | P0 · Physical + Fake | Authorized app and normal two-screen fixture. | Trigger twice rapidly; after completion trigger once deliberately. | No overlapping transactions. A request arriving during the active transaction is rejected; if it arrives after completion it is a legitimate second swap. Final deliberate request works. Record accepted invocation count rather than assuming a double-click equals one transaction. |
| TS30 | P0 · Fake; physical if reproducible | Three planned windows; force size/position failure or disappearance of one window between capture/apply. | Swap, remove the injected fault, swap again. | Failure is attributed to one window; later planned windows are attempted; counts are correct. Next invocation succeeds without stale IDs or a stuck running guard. |
| TS31 | P1 · Fake; physical if reproducible | Model delayed AX frame reads and delayed native-full-screen transitions as separate variants. | Trigger one swap per variant, then another after completion. | Position write is not suppressed by delayed size readback; confirmation is bounded; timeout is an explicit failure. No false verified success or poisoned next invocation. |
| TS32 | P0 · Physical + Fake | Normal fixture on A/B; status item visible. | Left-click once; inspect feedback. Right-click, dismiss menu, right-click and select Exit. Relaunch for remaining work. | Left click invokes one swap; feedback is concise and button recovers. Opening/dismissing right-click menu performs no swap. Exit terminates only ScreenSwap. |
| TS33 | P1 · Physical + Fake | Installed app already running and authorized. | Invoke `open -g 'screenswap://swap'` once; separately send an unrelated command in the fake routing test. | Valid URL invokes the same swap path with existing permission; invalid command causes no swap. No separate window-moving process is used. |
| TS34 | P1 · Physical | Stable two-screen layout; 2, 10, then 20 eligible test windows where practical. | Perform one swap cycle at each count. | All expected windows are accounted for on each invocation; no progressive omissions or failures. Record dispatch/completion latency per invocation. Timing is observational until an explicit latency budget is agreed. |

## Evidence and execution order

1. Confirm the installed build and both display frames. Run TS01 first to detect
   the recorded second-swap regression immediately.
2. Run the remaining P0 cases, prioritizing TS14, TS15, TS17, and TS18. Record
   each of the four invocations independently, even if the first succeeds.
3. Run P1 compatibility cases, resetting fixtures between cases and restoring
   original display/Stage Manager configuration afterward.
4. For automated coverage, use Swift Testing and fake AX clients. Assert full
   capture and one complete plan before the first write, stable display IDs,
   opaque snapshot-local window IDs, and continuation after errors. Run the
   full `./build-test.sh` suite; record actual discovery/pass counts.
5. If code changes, follow AGENTS.md: test, package/install/launch the fresh
   release with `Packaging/pack-app.sh --install --replace` and stable local
   signing identity. A documentation-only refinement requires no app rebuild.

For each case store: ID/variant, build, environment, trigger, initial window
inventory, expected targets, actual frames/states, safe evidence, and result.
For swap cycles use this per-invocation record:

| Step | Expected direction | Planned / attempted / succeeded / failed | Actual geometry/state | Result |
|---|---|---|---|---|
| S0 | Initial inventory | — | Record baseline | — |
| S1 | Each eligible window to opposite screen | Record counts | Compare with expected targets | NOT RUN |
| S2 | Return direction using fresh capture | Record counts | Check return, especially presentation state | NOT RUN |
| S3 | Opposite screen again | Record counts | Check for omissions/drift | NOT RUN |
| S4 | Return direction again | Record counts | Check baseline where mapping is reversible | NOT RUN |

Opt-in diagnostics may record discovered, eligible, skipped-by-reason, planned,
attempted, succeeded, failed, and verification outcome for each invocation.
Use those to distinguish second-click capture, planning, and apply failures.
Never log titles or document contents; use blank test documents for screenshots.
Phase ordering needs a fake/event trace; screenshots alone cannot prove it.
Keep new physical results in `docs/validation/first-click-swap.md` without
replacing historical records.

**Acceptance:** all P0 cases must pass on the current build; a blocked P0 case
leaves acceptance incomplete. Report P1 failures and blocked variants explicitly;
do not claim universal two-screen compatibility from one arrangement. This draft
does not define behavior for mirrored displays, ordinary windows on inactive
Spaces, or display removal/sleep during a transaction.
