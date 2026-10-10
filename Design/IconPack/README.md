# ScreenSwap icon assets

Imported from `ScreenSwap_Icon_Pack_v3_1_3_Option_A.zip` (v3.1.3, Option A).
Archive SHA-256: `a88eab9eaf9704bf8333595479619a35f1ec93176630d8da39ab47581053c4f0`.

The import preserves the original artwork bytes. The archive CRC and supplied
SHA-256 inventory were verified before integration.

- `MenuBar/`, `Motion/`, and `Color/` retain the editable SVG masters, including
  Call/Return designs.
- `ICON_REQUIREMENTS.md`, `PACK_README.md`, and `Motion.json` are the unchanged
  upstream design contract. References there to previews, Xcode catalogs and
  other exports describe the original archive, not files retained here.
- `../../Sources/ScreenSwapMac/Resources/StatusIcons` contains the active Swap,
  Move Left/Right, Call/Return, disabled and unavailable PNG templates and thirteen motion
  frames at @1x/@2x, plus the blue Swap illustration for About.
- `../../Packaging/ScreenSwap.icns` is the permanent blue Swap app identity.

Call/Return uses the connected templates and thirteen 220ms motion frames.
Its @1x/@2x runtime PNGs are direct CairoSVG exports of the retained masters,
with no runtime or package dependency on CairoSVG. App feedback settles on the
configured left-click mode; scrolling previews the middle-click mode. Vertical
and diagonal Move routes retain static native arrows because the pack supplies
only horizontal Move artwork; unresolved routes use a neutral Move template.
Runtime resources are copied by SwiftPM and included by `Packaging/pack-app.sh`; no Xcode asset-catalog compilation is needed.
