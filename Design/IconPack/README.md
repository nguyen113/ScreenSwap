# ScreenSwap icon assets

Imported from `ScreenSwap_Icon_Pack_v3_1_3_Option_A.zip` (v3.1.3, Option A).
Archive SHA-256: `a88eab9eaf9704bf8333595479619a35f1ec93176630d8da39ab47581053c4f0`.

The import preserves the original artwork bytes. The archive CRC and supplied
SHA-256 inventory were verified before integration.

- `MenuBar/`, `Motion/`, and `Color/` retain the editable SVG masters, including
  deferred Call/Return designs.
- `ICON_REQUIREMENTS.md`, `PACK_README.md`, and `Motion.json` are the unchanged
  upstream design contract. References there to previews, Xcode catalogs and
  other exports describe the original archive, not files retained here.
- `../../Sources/ScreenSwapMac/Resources/StatusIcons` contains the active Swap,
  Move Left/Right, disabled and unavailable PNG templates and thirteen motion
  frames at @1x/@2x, plus the blue Swap illustration for About.
- `../../Packaging/ScreenSwap.icns` is the permanent blue Swap app identity.

Call/Return remains deferred in `../../backlog.yml`; importing its editable
masters does not enable window operations. App feedback always settles on Swap,
which remains the left-click action. Vertical moves stay static because this
pack supplies no vertical arrows. Runtime resources are copied by SwiftPM and
included by `Packaging/pack-app.sh`; no Xcode asset-catalog compilation is needed.
