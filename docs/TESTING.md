# Testing

## Automated

Use `swift test` for deterministic core logic.

Core geometry tests should cover at least:

- equal-size displays
- different resolutions
- 16:9 to 16:10
- landscape to portrait
- window at each edge
- maximized-like window
- partially off-screen input
- minimum-size-like window
- center-point ownership helper behavior
- spanning window remains in place and is omitted from the move plan
- clamping on target display

## Manual

Physical two-monitor validation is required for Accessibility integration.

Suggested applications:

- Finder
- Safari/Chrome
- Terminal
- Xcode
- Notes
- Slack/Teams

Manual acceptance must verify that all windows are snapshotted before any are moved.
