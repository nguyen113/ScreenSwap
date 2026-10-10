# Call/Return foregrounding validation

Date: 2026-10-10.

## Reported behavior

The user reported that Call moved the window onto the configured primary
display but left it behind an active Edge browser window. The user confirmed
that Edge was maximized on the normal desktop, not in a native full-screen
Space.

## Change and automated results

Call/Return now foregrounds the owning application and raises the exact
transaction-local window after its geometry move. The live adapter selects its
main/focused window and uses AXFrontmost before AXRaise, with an AppKit
activation fallback. Ordinary swap visibility recovery retains its existing
raise-only behavior.

`./build-test.sh` passed with 181 tests discovered and executed.
`git diff --check` passed. The new integration regression models a maximized
active Edge window, a called window in another app and another window in the
called app. It requires activation before raising, checks movement precedes
foregrounding, verifies the exact window becomes frontmost on Call and Return,
and checks the other windows' geometry stays unchanged. Activation failure
produces a partial failure and retains Return recovery; stale captured handles
still cannot be used.

`Packaging/pack-app.sh --install --replace` built the app, preserved the local
development signing identity, verified its signature, installed it at
`/Applications/ScreenSwap.app` and launched it. The process was confirmed running.

## Physical check still required

With Edge maximized on the normal desktop of the configured primary display,
place a normal eligible window in another app on the other selected display.
Invoke Call from the configured click binding and from Control–Shift–C. Confirm
the called window appears above Edge and receives focus. Invoke Return and
confirm that same window restores its saved display and geometry. Also check
the case where both windows belong to the same application.

The foreground fix has not yet been physically confirmed by the user. Native
full-screen Spaces remain outside this normal-desktop scenario.
