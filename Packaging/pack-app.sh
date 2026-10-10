#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "${0:A:h}/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="ScreenSwap"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
INFO_PLIST="$ROOT_DIR/Packaging/Info.plist"
APP_ICON="$ROOT_DIR/Packaging/ScreenSwap.icns"
RELEASE_VERSION_FILE="$ROOT_DIR/Packaging/release-version.txt"
LOCAL_DEVELOPMENT_IDENTITY="ScreenSwap Local Development"

MODE="development"
INSTALL=false
REPLACE=false
ALLOW_AD_HOC=false
SIGNING_IDENTITY="${SCREENSWAP_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${SCREENSWAP_NOTARY_PROFILE:-}"

usage() {
    cat <<'EOF'
Usage: Packaging/pack-app.sh [options]

Modes (choose at most one):
  (default)                    Development build; uses the local stable identity when available.
  --beta                       Ad-hoc signed beta ZIP and DMG; not Developer ID signed or notarized.
  --release                    Production build; requires Developer ID signing and notarization.

Options:
  --install                    Install a development build at /Applications/ScreenSwap.app.
  --replace                    Replace an existing installed development build.
  --allow-ad-hoc               Permit ad-hoc signing for a development install.
  --signing-identity NAME      Signing identity (required for --release).
  --notary-profile NAME        notarytool keychain profile (required for --release).

Run Packaging/create-local-signing-identity.sh once for stable local development
installs that retain Accessibility authorization across rebuilds.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --install) INSTALL=true; shift ;;
        --replace) REPLACE=true; shift ;;
        --beta)
            [[ "$MODE" == "development" ]] || fail "choose exactly one of --beta or --release"
            MODE="beta"
            shift
            ;;
        --release)
            [[ "$MODE" == "development" ]] || fail "choose exactly one of --beta or --release"
            MODE="production"
            shift
            ;;
        --allow-ad-hoc) ALLOW_AD_HOC=true; shift ;;
        --signing-identity)
            (( $# >= 2 )) || fail "--signing-identity requires a value"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            (( $# >= 2 )) || fail "--notary-profile requires a value"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done

if [[ "$MODE" != "development" ]] && $INSTALL; then
    fail "--install is only supported for development builds"
fi
if ! $INSTALL && $REPLACE; then
    fail "--replace requires --install"
fi
if [[ "$MODE" != "development" ]] && $ALLOW_AD_HOC; then
    fail "--allow-ad-hoc is only a development-install option"
fi

# A local development identity is deliberately preferred for installed test
# builds. Unlike ad-hoc signing, its designated requirement survives each
# compiled binary, so macOS does not create a fresh Accessibility entry on
# every update.
if [[ "$MODE" == "development" && -z "$SIGNING_IDENTITY" ]]; then
    local_identity_hash="$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="$LOCAL_DEVELOPMENT_IDENTITY" '$0 ~ "\\\"" name "\\\"" { print $2; exit }')"
    if [[ -n "$local_identity_hash" ]]; then
        SIGNING_IDENTITY="$local_identity_hash"
    fi
fi

case "$MODE" in
    development)
        if $INSTALL && [[ -z "$SIGNING_IDENTITY" ]] && ! $ALLOW_AD_HOC; then
            fail "installed development builds require the ScreenSwap Local Development identity; run Packaging/create-local-signing-identity.sh or explicitly pass --allow-ad-hoc"
        fi
        if [[ "$SIGNING_IDENTITY" == "-" ]] && ! $ALLOW_AD_HOC; then
            fail "- is ad-hoc signing; pass --allow-ad-hoc for a development build"
        fi
        [[ -n "$SIGNING_IDENTITY" ]] || SIGNING_IDENTITY="-"
        ;;
    beta)
        [[ -z "$SIGNING_IDENTITY" ]] || fail "--beta always uses ad-hoc signing; do not provide --signing-identity"
        SIGNING_IDENTITY="-"
        ;;
    production)
        [[ -n "$SIGNING_IDENTITY" ]] || fail "production packaging requires --signing-identity 'Developer ID Application: NAME (TEAMID)'"
        [[ "$SIGNING_IDENTITY" != "-" ]] || fail "production packaging cannot use ad-hoc signing"
        [[ -n "$NOTARY_PROFILE" ]] || fail "production packaging requires --notary-profile for xcrun notarytool"
        ;;
esac

[[ -f "$RELEASE_VERSION_FILE" ]] || fail "missing distribution version file: $RELEASE_VERSION_FILE"
[[ -f "$APP_ICON" ]] || fail "missing application icon: $APP_ICON"
release_version="$(< "$RELEASE_VERSION_FILE")"
[[ -n "$release_version" ]] || fail "distribution version is empty in $RELEASE_VERSION_FILE"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME-$release_version.zip"
DMG_PATH="$DIST_DIR/$APP_NAME-$release_version.dmg"

case "$MODE" in
    development)
        if [[ "$SIGNING_IDENTITY" == "-" ]]; then
            echo "WARNING: creating an ad-hoc development build." >&2
            echo "WARNING: macOS Accessibility authorization may need to be granted again after an update." >&2
        elif $INSTALL; then
            echo "Using local development signing identity: $SIGNING_IDENTITY"
        fi
        ;;
    beta)
        echo "Creating beta build: ad-hoc signed, not notarized for public Apple trust purposes."
        ;;
    production)
        echo "Creating production build with Developer ID signing and notarization."
        ;;
esac

cd "$ROOT_DIR"

echo "Building release binaries for Apple silicon and Intel Macs..."
swift build -c release --arch arm64 --product ScreenSwapApp
ARM_BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/ScreenSwapApp"
swift build -c release --arch x86_64 --product ScreenSwapApp
INTEL_BIN_PATH="$(swift build -c release --arch x86_64 --show-bin-path)/ScreenSwapApp"

echo "Creating $APP_BUNDLE"
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
lipo -create "$ARM_BIN_PATH" "$INTEL_BIN_PATH" -output "$APP_BUNDLE/Contents/MacOS/ScreenSwapApp"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/ScreenSwap.icns"
RESOURCE_BUNDLE="${ARM_BIN_PATH:h}/ScreenSwap_ScreenSwapMac.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || fail "missing status icon resource bundle: $RESOURCE_BUNDLE"
ditto "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/ScreenSwap_ScreenSwapMac.bundle"

if [[ "$MODE" == "production" ]]; then
    echo "Applying Developer ID signature with hardened runtime..."
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_BUNDLE"
elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Applying ad-hoc code signature..."
    codesign --force --sign - --timestamp=none "$APP_BUNDLE"
else
    echo "Applying local development code signature..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE"
fi
echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1

if [[ "$MODE" == "production" ]]; then
    leaf_authority="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    if [[ "$leaf_authority" != "Developer ID Application:"* ]]; then
        fail "production build must be signed with Developer ID Application (actual authority: ${leaf_authority:-unknown})"
    fi
    # notarytool accepts a ZIP, DMG, or PKG. This temporary archive is rebuilt
    # after stapling so the final distribution archive contains the ticket.
    rm -f "$ARCHIVE_PATH"
    echo "Creating notarization submission archive..."
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
    echo "Submitting app for notarization..."
    xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    echo "Assessing production bundle with Gatekeeper..."
    spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
    rm -f "$ARCHIVE_PATH"
fi

if [[ "$MODE" == "beta" || "$MODE" == "production" ]]; then
    rm -f "$ARCHIVE_PATH"
    echo "Creating $ARCHIVE_PATH"
    ditto -c -k --norsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
    archive_hash="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{ print $1 }')"
    echo "Artifact: $ARCHIVE_PATH"
    echo "SHA256: $archive_hash"
    dmg_stage="$(mktemp -d "$DIST_DIR/.screenswap-dmg.XXXXXX")"
    ditto "$APP_BUNDLE" "$dmg_stage/$APP_NAME.app"
    ln -s /Applications "$dmg_stage/Applications"
    rm -f "$DMG_PATH"
    echo "Creating $DMG_PATH"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$dmg_stage" -format UDZO "$DMG_PATH"
    rm -rf "$dmg_stage"
    hdiutil verify -quiet "$DMG_PATH"
    dmg_hash="$(shasum -a 256 "$DMG_PATH" | awk '{ print $1 }')"
    echo "Artifact: $DMG_PATH"
    echo "SHA256: $dmg_hash"
    if [[ "$MODE" == "beta" ]]; then
        echo "Beta limitation: this artifact is ad-hoc signed and not notarized; Gatekeeper approval may be required on first launch."
    fi
fi

designated_requirement() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

if $INSTALL; then
    if [[ -e "$INSTALL_PATH" ]]; then
        if ! $REPLACE; then
            echo "error: $INSTALL_PATH already exists; pass --replace to update it" >&2
            exit 1
        fi
        old_requirement="$(designated_requirement "$INSTALL_PATH")"
        new_requirement="$(designated_requirement "$APP_BUNDLE")"
        if [[ -n "$old_requirement" && -n "$new_requirement" && "$old_requirement" != "$new_requirement" ]]; then
            echo "error: signing identity/designated requirement changed" >&2
            echo "       refusing update because Accessibility authorization may be lost" >&2
            exit 1
        fi
        echo "Replacing $INSTALL_PATH"
        rm -rf "$INSTALL_PATH"
    fi
    # The public bundle was formerly ScreenSwapApp.app. Stop the internal
    # executable before every development install so an old and renamed bundle
    # cannot remain active concurrently. The legacy bundle is left on disk.
    running_pids_text="$(pgrep -x ScreenSwapApp 2>/dev/null || true)"
    if [[ -n "$running_pids_text" ]]; then
        running_pids=("${(@f)running_pids_text}")
        echo "Stopping running ScreenSwap before installing $INSTALL_PATH"
        kill -TERM "${running_pids[@]}" 2>/dev/null || true
        for _ in {1..50}; do
            if ! pgrep -x ScreenSwapApp >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        if pgrep -x ScreenSwapApp >/dev/null 2>&1; then
            echo "error: running ScreenSwap did not stop; refusing to install the bundle" >&2
            exit 1
        fi
    fi
    echo "Installing $INSTALL_PATH"
    ditto "$APP_BUNDLE" "$INSTALL_PATH"
    codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
    echo "Launching the newly installed ScreenSwap"
    open "$INSTALL_PATH"
fi

echo "Packaged app: $APP_BUNDLE"
if $INSTALL; then
    echo "Installed app: $INSTALL_PATH"
fi
