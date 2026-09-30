# Beta distribution

ScreenSwap's first beta is `0.1.0-beta.1` (build `1`). Its future Git tag is
`v0.1.0-beta.1`, but this repository does not create tags, releases, or a
Homebrew tap automatically.

## Current beta path

On macOS, create the local beta artifact with:

```bash
Packaging/pack-app.sh --beta
```

The script builds the release executable, constructs `dist/ScreenSwap.app`,
ad-hoc signs it, verifies its code signature, creates
`dist/ScreenSwap-0.1.0-beta.1.zip`, and prints the archive's SHA-256. The
archive name is derived from `Packaging/release-version.txt`. The app bundle's
`CFBundleShortVersionString` remains the valid macOS version `0.1.0`; do not
use it to name distribution artifacts.

An ad-hoc signature is deliberately not a Developer ID signature and does not
notarize the app. Gatekeeper may block the first launch. Users should follow
macOS's normal, per-app approval flow in System Settings → Privacy & Security;
they should not disable Gatekeeper globally. ScreenSwap also needs
Accessibility permission. As beta versions do not use a stable Developer ID
identity, an update may occasionally require Accessibility approval again.

`spctl --assess` is intentionally not a beta validation gate: rejection is
expected for an ad-hoc, unnotarized build.

## Future personal Homebrew Cask

Once the ZIP has been uploaded to the matching GitHub Release and its final
SHA-256 is known, a personal tap can use this Cask. It is documentation only;
do not publish it until the release exists.

Once that tap exists, the intended beta installation command is:

```bash
brew install --cask nguyen113/tap/screenswap
```

```ruby
cask "screenswap" do
  version "0.1.0-beta.1"
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

This beta is not Developer-ID signed or notarized, so macOS may require normal
per-app approval in System Settings → Privacy & Security. Do not disable
Gatekeeper globally.

## Development, beta, and production modes

`Packaging/pack-app.sh` keeps the modes distinct:

- Development is the default. `--install --replace` installs
  `/Applications/ScreenSwap.app` and prefers the local, login-keychain-only
  `ScreenSwap Local Development` identity created by
  `Packaging/create-local-signing-identity.sh`.
- Beta uses `--beta`, always ad-hoc signs, and creates the versioned ZIP. It
  needs no Apple Developer Program membership.
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
