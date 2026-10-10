# Release v1.0.0 validation

Date: 2026-10-10. Version: `1.0.0`; macOS bundle build: `4`.

## Automated and distribution checks

- `./build-test.sh`: 181 tests discovered and passed.
- `git diff --check`: passed.
- `plutil -lint Packaging/Info.plist`: passed.
- Gitleaks scanned the current tracked/non-ignored source tree and all reachable
  Git history (`--all`): no secrets found.
- `Packaging/pack-app.sh --beta`: built the release executable for `arm64` and
  `x86_64`, assembled the universal app, verified its ad-hoc signature, and
  created the ZIP and DMG.
- `lipo -archs`: confirmed both `x86_64` and `arm64` in the packaged executable.
- `unzip -tq`: ZIP integrity passed. Extracted app signature verification
  passed; bundle version/build match `1.0.0`/`4`, and all 153 packaged icon PNGs
  match source names and SHA-256 hashes.
- `hdiutil verify`: DMG integrity passed.

The artifacts are ad-hoc signed and unnotarized. No Developer ID identity is
available for this release. Gatekeeper assessment is not a pass criterion for
this signing path; per-app approval and Accessibility access are documented.

## Artifact SHA-256

```text
59545c4406bf22fc5780e322e8e3a295ef413b54ee40b6754c6c6047fe76f002  ScreenSwap-1.0.0.zip
aee7d36d31ad567f539d834707bf4a8ab860759f5628739e08c7b06f780dc7d7  ScreenSwap-1.0.0.dmg
```

## Physical validation status

This release preparation changes documentation, version metadata, and two
polling tests to use the existing fake clock. The initial GitHub CI run exposed
a scheduling stall that hit the real 500 ms verification deadline in a
poll-count test; the fake clock makes those assertions deterministic. No window
behavior was changed and no new physical display/window test was performed.
The earlier Call/Return build was user-confirmed as working, as recorded in
[Call/Return validation](call-return.md). That confirmation predates the newer
primary-display preference and foregrounding fix.

The primary-display override and Call/Return foregrounding scenarios remain
physically unconfirmed; see [primary-display validation](primary-display.md)
and [foregrounding validation](call-foregrounding.md). Real Accessibility
permission, display layouts, application-specific window behavior, and macOS
Spaces still require physical validation. Native full-screen Spaces remain
unsupported.
