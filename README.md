# ScreenSwap

[![Support ScreenSwap on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/C3N027TX55)

ScreenSwap is a macOS menu-bar app for moving windows between two selected
displays in one action. It is designed for people who regularly switch their
working layout between a laptop display and external monitors.

On a Mac with three or more displays, choose the two displays that form the
active swap pair; all other displays remain untouched. ScreenSwap is built on
public macOS Accessibility and Quartz APIs and keeps its geometry planning in a
small, deterministic Swift core.

> [!IMPORTANT]
> ScreenSwap v0.1 does not move native macOS full-screen Spaces. Exit full
> screen before swapping that application.

## Project status

ScreenSwap is an early macOS release. It is useful for its supported
two-display workflow, but physical validation across different displays, apps,
and macOS Spaces is still important before relying on it in a critical setup.

## Highlights

- Swaps visible eligible windows across applications—not only the frontmost app.
- Supports two-display swaps on any active display topology; choose the active
  pair from the menu when three or more displays are connected.
- Lets you include or exclude individual windows, or use an `All windows` row
  for each selected display.
- Preserves proportional placement across displays with different resolutions,
  aspect ratios, and usable areas.
- Protects spanning, minimized, transient, non-movable, and off-screen windows.
- Preserves fixed-size windows and verifies writes after a move; if a moved
  window remains unavailable on its macOS Space, ScreenSwap attempts to restore
  its prior frame.
- Includes a configurable global shortcut (default: Control–Shift–S),
  Accessibility onboarding, optional launch at login, About, and Reduce Motion
  aware hover feedback.

## ⚠️ Important limitation: native macOS full-screen windows

ScreenSwap v0.1 does **not** move applications that are using macOS **native
full-screen mode**.

Native full-screen is the mode where macOS creates a separate Space/virtual
desktop for the application.

For example:

```text
Finder → View / Enter Full Screen
Safari → Enter Full Screen
Xcode → Enter Full Screen
```

These windows are intentionally left untouched by ScreenSwap.

### Why?

A native full-screen window is managed by macOS as both a window and a
dedicated Space.

During development, moving these Spaces indirectly by exiting full screen,
moving the window, and restoring full screen could leave stale WindowServer
surfaces on the previous display.

To avoid corrupt-looking desktops, ghost windows, or requiring a
Finder/Dock/macOS restart, ScreenSwap v0.1 does not modify native full-screen
Spaces.

### Supported

ScreenSwap supports normal windowed layouts, including:

- Normal windows
- Multiple windows on the same display
- Overlapping windows
- 50:50 tiled windows
- Quarter-screen tiled windows
- Windowed/maximized windows
- Different display sizes and resolutions
- Selecting individual windows to swap
- Selecting which two displays to swap when 3+ displays are connected

### Not supported in v0.1

- Native macOS full-screen Spaces
- Moving a native full-screen application from one display to another
- Multi-display rotation involving more than two displays in one transaction

To include a full-screen application in a swap:

1. Exit macOS native full-screen mode.
2. Leave the application as a normal or maximized window.
3. Run ScreenSwap.

Native full-screen support may be investigated for a future release if it can
be implemented safely using macOS-supported behavior.

## Requirements

- macOS 14 or later
- Accessibility permission for ScreenSwap
- At least two active displays

## Use ScreenSwap

1. Launch ScreenSwap and grant Accessibility access when prompted.
2. With two displays, they are automatically the active swap pair.
3. With three or more displays, right-click the menu-bar item and select an
   unchecked display to replace a member of the pair.
4. Use the `All windows` row or individual window rows to choose which windows
   move. Window choices are retained while a display is outside the active pair.
5. Left-click the menu-bar item or press Control–Shift–S to swap the selected
   windows between the active pair.

Display checkmarks choose *which monitors participate*. The nested window
checkmarks choose *which windows participate*. A window on an unselected
display is shown but disabled; it will not be moved.

## Safety and behavior

ScreenSwap snapshots eligible windows and plans the complete transaction before
the first Accessibility write. It rechecks display IDs and geometry before
mutation, and aborts without moving anything if the display topology changed
during the operation.

The app intentionally does not implement three-way rotation or general
N-display routing. Every transaction remains a normal two-display swap.

macOS does not provide a reliable public API for moving arbitrary foreign-app
windows between Spaces. ScreenSwap therefore leaves native full-screen Spaces
untouched in v0.1.

## Build from source

```bash
git clone https://github.com/nguyen113/ScreenSwap-Mac.git
cd ScreenSwap-Mac
./build-test.sh
```

To package, install, and launch a local build:

```bash
Packaging/pack-app.sh --install --replace
```

The script uses a stable local signing identity when one is available. If you
need to create one first, run:

```bash
Packaging/create-local-signing-identity.sh
```

Ad-hoc signing is opt-in (`--allow-ad-hoc`) and may require granting
Accessibility access again. Release packages must use an explicit Developer ID
Application identity.

GitHub releases currently provide source archives. A notarized distributable
application bundle is not yet provided for every release.

## Report bugs

Use the [bug report template](https://github.com/nguyen113/ScreenSwap-Mac/issues/new?template=bug_report.yml)
for unexpected behavior and the [feature request template](https://github.com/nguyen113/ScreenSwap-Mac/issues/new?template=feature_request.yml)
for ideas. Include the app version, macOS version, display count, selected
displays, and reproduction steps—but never window titles, document contents,
credentials, or other sensitive desktop information.

For security issues, follow the private reporting guidance in
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development

`ScreenSwapCore` contains pure display/window geometry and the unchanged
two-display mapping engine. `ScreenSwapMac` contains the Accessibility,
display-discovery, selection, status-item, settings, and hotkey adapters.

Run the complete automated suite with:

```bash
./build-test.sh
```

The tests use Swift Testing and fakes for Accessibility and display services;
they do not replace physical validation with real displays and Accessibility
permission. See [the architecture notes](docs/ARCHITECTURE.md) for transaction
and selection-state details.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md)
for the development workflow. Please keep changes focused, preserve the
two-display transaction boundary, add deterministic regression coverage for
behavior changes, and run `./build-test.sh` plus `git diff --check` before
opening a pull request.

## Support

If ScreenSwap saves you a little desktop shuffling, you can support its
development on Ko-fi:

[![Support ScreenSwap on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/C3N027TX55)

## License

ScreenSwap is released under the MIT License.

See [LICENSE](LICENSE) for details.

## Reference material

- [Core public API](docs/CORE_PUBLIC_API.md)
- [Architecture](docs/ARCHITECTURE.md)
- [GitHub project](https://github.com/nguyen113/ScreenSwap-Mac)
