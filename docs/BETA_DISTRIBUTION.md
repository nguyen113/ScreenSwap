# Distribution

The current release is `1.0.0` (build `4`), tagged `v1.0.0`. Downloads remain
ad-hoc signed and unnotarized. The `--beta` packaging mode is used for this
signing path even though the GitHub release is not marked as a prerelease.
Tags, releases, and Homebrew tap updates are published after validation.

## Current ad-hoc distribution path

On macOS, create the distribution artifacts with:

```bash
Packaging/pack-app.sh --beta
```

The script builds the release executable, constructs `dist/ScreenSwap.app`,
ad-hoc signs it, verifies its code signature, creates
`dist/ScreenSwap-1.0.0.zip` and `dist/ScreenSwap-1.0.0.dmg`, and prints both
SHA-256 hashes. The
artifact names is derived from `Packaging/release-version.txt`. The app bundle's
`CFBundleShortVersionString` is `1.0.0` and `CFBundleVersion` is `4`.

An ad-hoc signature is deliberately not a Developer ID signature and does not
notarize the app. Gatekeeper may block the first launch. Users should follow
macOS's normal, per-app approval flow in System Settings → Privacy & Security;
they should not disable Gatekeeper globally. ScreenSwap also needs
Accessibility permission. Because these downloads do not use a stable
Developer ID identity, an update may require Accessibility approval again.

`spctl --assess` is intentionally not an ad-hoc validation gate: rejection is
expected for an ad-hoc, unnotarized build.

## Personal Homebrew Cask

Once the ZIP has been uploaded to the matching GitHub Release and its final
SHA-256 is known, the personal tap can use this Cask.

Install from the personal tap with:

```bash
brew install --cask nguyen113/tap/screenswap
```

```ruby
cask "screenswap" do
  version "1.0.0"
  sha256 "<FINAL_SHA256>"

  url "https://github.com/nguyen113/ScreenSwap/releases/download/v#{version}/ScreenSwap-#{version}.zip"
  name "ScreenSwap"
  desc "Swap windows between two selected displays"
  homepage "https://github.com/nguyen113/ScreenSwap"

  depends_on macos: ">= :sonoma"

  app "ScreenSwap.app"

  caveats do
    unsigned_accessibility
  end
end
```

This release is not Developer ID signed or notarized, so macOS may require normal
per-app approval in System Settings → Privacy & Security. Do not disable
Gatekeeper globally.

## Development, beta, and production modes

`Packaging/pack-app.sh` keeps the modes distinct:

- Development is the default. `--install --replace` installs
  `/Applications/ScreenSwap.app` and prefers the local, login-keychain-only
  `ScreenSwap Local Development` identity created by
  `Packaging/create-local-signing-identity.sh`.
- The ad-hoc path uses `--beta`, always ad-hoc signs, and creates versioned ZIP
  and DMG downloads. It needs no Apple Developer Program membership.
- Production uses `--release --signing-identity "Developer ID Application: …"
  --notary-profile NAME`. It requires an installed Developer ID Application
  identity and an existing notarytool keychain profile; no credentials are
  accepted by or stored in the repository.

The production flow applies the hardened runtime, timestamps the signature,
submits with `xcrun notarytool`, staples and validates the ticket, runs
Gatekeeper assessment, then archives and hashes the app. Missing identity or
notary profile fails before a build is signed or submitted.

The future upgrade path is therefore:

```text
beta ad-hoc signing
→ Apple Developer Program
→ Developer ID Application
→ hardened runtime
→ notarization
→ stapling
→ same GitHub Release and Homebrew Cask structure
```
