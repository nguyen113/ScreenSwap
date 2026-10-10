# Configurable primary display validation

Date: 2026-10-10.

## Automated results

`./build-test.sh` passed with 179 tests discovered and executed.
`git diff --check` passed.

`Packaging/pack-app.sh --install --replace` built and signed the app using the
existing local development identity, verified its signature, installed it at
`/Applications/ScreenSwap.app` and launched it. The process was confirmed
running. Live menu appearance and physical window movement were not directly
verified by the agent.

New regression coverage checks preference persistence/reset, invalid IDs,
stable display identity with reordered enumeration, missing-display fallback,
reconnection, unchanged snapshot coordinates, shared inventory/pair selection,
permission before display/window reads, menu changes without inventory
discovery, choosing a third display, disabled changes during a pending Return,
Call toward a configured monitor rather than macOS primary, frozen roles before
capture, and Return restoring its saved route despite preference changes.

## Physical checks still required

- Right-click ScreenSwap and choose **Primary Display**. Choose the monitor
  opposite macOS primary; confirm its heading is marked **Primary** and the
  submenu checkmark survives an app restart.
- Place overlapping eligible windows on the other selected display. Invoke
  Call/Return: its topmost window should move to the configured primary. Invoke
  again after repositioning/resizing it: it should restore its original frame.
- Confirm primary-display choices are disabled until Return or Cancel. macOS
  display arrangement and the system primary setting must remain unchanged.
- With three or more monitors, choosing an unselected primary must add it to
  the pair. Check only the selected pair participates in Swap, Move and Call.
- Disconnect the chosen display, refresh the menu, and confirm the explicit
  fallback label. Reconnect and refresh; its primary role resumes if its CG
  display ID is unchanged. Select it into the pair before invoking Call.
- Choose **Follow macOS** and verify Call uses macOS primary again. Check
  unequal monitor sizes, monitors above/below one another and Dock insets.

These physical override scenarios have not yet been user-confirmed. The earlier
user confirmation applies to the Call/Return feature before this preference was
added.
