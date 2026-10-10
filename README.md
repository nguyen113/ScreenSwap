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
> Native macOS full-screen Spaces are not supported. Exit full screen before
> using Swap, Move, or Call / Return with that window.

## Version 1.0

[Download ScreenSwap v1.0.0](https://github.com/nguyen113/ScreenSwap/releases/tag/v1.0.0)
for Apple silicon and Intel Macs. This release adds focused-window Move,
Call / Return, configurable mouse actions, and a saved primary-display
preference to the window-swap workflow.

## Demo

[![Watch the ScreenSwap demo on YouTube](https://i.ytimg.com/vi/8VaTokzlOUM/hqdefault.jpg)](https://www.youtube.com/watch?v=8VaTokzlOUM)

## Highlights

- Swaps visible eligible windows across applications—not only the frontmost app.
- Supports two-display swaps on any active display topology; choose the active
  pair from the menu when three or more displays are connected.
- Lets you include or exclude individual windows, or use an `All windows` row
  for each selected display.
- Moves the focused window to the other selected display with a separate
  configurable shortcut (Control–Option–Shift–S by default), a middle-click on
  the menu-bar icon by default, or a menu command.
- Calls the topmost eligible window from the other selected display to the
  primary display and returns that same window with Control–Shift–C.
- Lets you choose ScreenSwap’s primary display independently of macOS.
- Lets you bind Swap, Move, or Call / Return to left and middle click; scroll
  over the icon to cycle the middle-click mode.
- Preserves proportional placement across displays with different resolutions,
  aspect ratios, and usable areas.
- Protects spanning, minimized, transient, non-movable, and off-screen windows.
- Preserves fixed-size windows and verifies writes after a move; if a moved
  window remains unavailable on its macOS Space, ScreenSwap attempts to restore
  its prior frame.
- Includes a configurable global shortcut (default: Control–Shift–S),
  Accessibility onboarding, optional launch at login, About, and Reduce Motion
  aware action feedback.

## Supported windows and limitations

ScreenSwap supports normal, overlapping, tiled, and maximized windows across
displays with different sizes and resolutions. Native macOS full-screen
windows live in separate Spaces and are left untouched; exit full screen to
include them. Spanning, minimized, transient, non-movable, and unavailable
windows are also excluded. Each action uses exactly two selected displays.

## Requirements

- macOS 14 or later
- Accessibility permission for ScreenSwap
- At least two active displays

## Install ScreenSwap

Choose one of these three methods. ScreenSwap runs in the menu bar, so it does
not open a regular application window.

> [!IMPORTANT]
> The v1.0.0 downloads are ad-hoc signed and are not Apple Developer ID signed
> or notarized. macOS may block its first launch. If that happens, follow
> [the per-app approval steps](#allow-screenswap-in-macos-security-settings).

### Option 1: Homebrew

Install from the [ScreenSwap Homebrew tap](https://github.com/nguyen113/homebrew-tap):

```bash
brew tap nguyen113/tap
brew trust --cask nguyen113/tap/screenswap
brew install --cask nguyen113/tap/screenswap
```

The trust command approves this personal tap’s cask. To update an existing
installation, run `brew update` followed by `brew upgrade --cask screenswap`.

### Option 2: Download from GitHub Releases

1. Download the DMG or ZIP from the
   [ScreenSwap v1.0.0 release](https://github.com/nguyen113/ScreenSwap/releases/tag/v1.0.0).
2. For a ZIP, open it and move the extracted `ScreenSwap.app` to `/Applications`.
   For a DMG, open it and drag ScreenSwap into Applications.
3. Open ScreenSwap from Applications.

### Option 3: Build from source

Install Xcode with Swift 6 support and Git, then run:

```bash
git clone https://github.com/nguyen113/ScreenSwap.git
cd ScreenSwap
./build-test.sh
Packaging/create-local-signing-identity.sh
Packaging/pack-app.sh --install --replace
```

The signing identity is created once and helps macOS retain Accessibility
permission across local rebuilds. The packaging command installs and launches
`/Applications/ScreenSwap.app`.

## Allow ScreenSwap in macOS Security Settings

If macOS blocks ScreenSwap, first try opening ScreenSwap from Applications.
Then open **System Settings → Privacy & Security**, scroll to **Security**, and
click **Open Anyway** for ScreenSwap. Confirm **Open** and authenticate if macOS
asks. The button appears after macOS has blocked a launch; it may be needed
again after an update. Do not disable Gatekeeper globally.

## Grant Accessibility permission

ScreenSwap needs Accessibility permission to move windows belonging to other
apps. When prompted, open **System Settings → Privacy & Security →
Accessibility** and enable ScreenSwap. If it is not listed, open ScreenSwap's
**Settings** from the menu bar and click **Grant Accessibility**. Relaunch the
app if macOS asks you to. Updates may require Accessibility approval again.

## Use ScreenSwap

1. Launch ScreenSwap and grant Accessibility access.
2. Right-click the menu-bar icon to choose displays and windows. Two displays
   are selected automatically; with three or more, select an unchecked display
   to replace one member of the pair. Use each display’s **All windows** row or
   individual checkboxes to choose windows for Swap.
3. Left-click the icon or press **Control–Shift–S** to swap selected windows.

### New features: quick guide

| Feature | How to use it |
| --- | --- |
| Move focused window | Focus a window, then middle-click the icon or press **Control–Option–Shift–S**. It moves to the other selected display. |
| Call / Return | Press **Control–Shift–C** to bring the topmost eligible window from the other display onto ScreenSwap’s primary display and bring it forward. Press again to return the same window to its saved display, position, and size. |
| Choose primary display | Right-click → **Primary Display** → choose a monitor, or **Follow macOS**. Choosing a monitor outside the pair adds it to the pair. The preference survives app restarts and does not change macOS display settings. |
| Customize mouse actions | Right-click → **Left Click** or **Middle Click** → choose Swap, Move, or Call / Return. Choosing the other button’s action exchanges their bindings. |
| Cycle middle-click action | Scroll over the icon to cycle between the two actions different from left click. The icon previews the choice until the pointer leaves. |
| Customize shortcuts / launch at login | Open **Settings…** from the right-click menu. Each shortcut stays tied to its named action, regardless of mouse bindings. |

Move and Call / Return work independently of the Swap checkboxes. Call requires
ScreenSwap’s primary display and one other display in the selected pair.
Return targets the same window even if you focus another window or resize the
called window; it clamps the saved frame if the source display’s usable area
has changed.

While Return is pending, return the window or choose **Cancel Return — Keep
Window Here** before using Swap, Move, or changing the primary display. Cancel
leaves the window in place. Failed placement retains **Retry Return / Recover
Called Window**. Make the window available and reselect the original pair to
retry; a missing window or disconnected display never redirects Return to
another window. Quitting ScreenSwap forgets the saved Return.

If the preferred primary display disconnects, ScreenSwap temporarily follows
macOS and labels the fallback in the menu. Reconnecting the same display ID
restores its primary role. If a dock assigns a new ID, select the monitor again.
Display-pair and window choices are retained only for the current app session.

## Safety and behavior

ScreenSwap snapshots eligible windows and plans the complete transaction before
the first Accessibility write. It rechecks display IDs and geometry before
mutation, and aborts without moving anything if the display topology changed
during the operation.

The menu-bar icon reflects the left-click action. Move shows the focused
window’s destination direction; Call changes to Return after a successful Call.
Successful actions show brief feedback, and Reduce Motion disables animation.
Permission and insufficient-display failures keep help and selection accessible.

## Report bugs

Use the [bug report template](https://github.com/nguyen113/ScreenSwap/issues/new?template=bug_report.yml)
for unexpected behavior and the [feature request template](https://github.com/nguyen113/ScreenSwap/issues/new?template=feature_request.yml)
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
git diff --check
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
- [GitHub project](https://github.com/nguyen113/ScreenSwap)
