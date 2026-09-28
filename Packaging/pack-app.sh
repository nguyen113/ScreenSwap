#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h}/.."
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/ScreenSwapApp.app"
INSTALL_PATH="/Applications/ScreenSwapApp.app"
INSTALL=false
REPLACE=false
RELEASE=false
ALLOW_AD_HOC=false
SIGNING_IDENTITY="${SCREENSWAP_SIGNING_IDENTITY:-}"
LOCAL_DEVELOPMENT_IDENTITY="ScreenSwap Local Development"

while (( $# > 0 )); do
    case "$1" in
        --install) INSTALL=true; shift ;;
        --replace) REPLACE=true; shift ;;
        --release) RELEASE=true; shift ;;
        --allow-ad-hoc) ALLOW_AD_HOC=true; shift ;;
        --signing-identity)
            if (( $# < 2 )); then
                echo "error: --signing-identity requires a value" >&2
                exit 2
            fi
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: Packaging/pack-app.sh [options]"
            echo "  --install --replace --release --signing-identity NAME --allow-ad-hoc"
            echo "  Run Packaging/create-local-signing-identity.sh once to retain Accessibility approval across local builds."
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
    esac
done

# A local development identity is deliberately preferred for installed test
# builds. Unlike ad-hoc signing, its designated requirement survives each
# compiled binary, so macOS does not create a fresh Accessibility entry on
# every update. Production callers can still supply their own identity.
if [[ -z "$SIGNING_IDENTITY" ]]; then
    local_identity_hash="$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="$LOCAL_DEVELOPMENT_IDENTITY" '$0 ~ "\\\"" name "\\\"" { print $2; exit }')"
    if [[ -n "$local_identity_hash" ]]; then
        SIGNING_IDENTITY="$local_identity_hash"
    fi
fi

if $RELEASE && [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: --release requires --signing-identity or SCREENSWAP_SIGNING_IDENTITY" >&2
    exit 2
fi

if $RELEASE && [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "error: --release cannot use ad-hoc signing" >&2
    exit 2
fi

if $INSTALL && [[ -z "$SIGNING_IDENTITY" ]] && ! $ALLOW_AD_HOC; then
    echo "error: installed builds require a stable signing identity" >&2
    echo "       pass --signing-identity Developer-ID-Application-Identity for updates" >&2
    echo "       or explicitly opt into development behavior with --allow-ad-hoc" >&2
    exit 2
fi

if [[ "$SIGNING_IDENTITY" == "-" ]] && ! $ALLOW_AD_HOC; then
    echo "error: - is ad-hoc signing; pass --allow-ad-hoc for a development build" >&2
    exit 2
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "WARNING: creating an ad-hoc development build." >&2
    echo "WARNING: macOS Accessibility authorization may need to be granted again after an update." >&2
elif $INSTALL || $RELEASE; then
    echo "Using stable signing identity: $SIGNING_IDENTITY"
fi

cd "$ROOT_DIR"

echo "Building release binary..."
swift build -c release --product ScreenSwapApp
BIN_PATH="$(swift build -c release --show-bin-path)/ScreenSwapApp"

echo "Creating $APP_BUNDLE"
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/ScreenSwapApp"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Applying ad-hoc code signature..."
    codesign --force --sign - --timestamp=none "$APP_BUNDLE"
else
    echo "Applying code signature with stable identity..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

if $INSTALL; then
    if [[ -e "$INSTALL_PATH" ]]; then
        if ! $REPLACE; then
            echo "error: $INSTALL_PATH already exists; pass --replace to update it" >&2
            exit 1
        fi
        running_pids_text="$(pgrep -x ScreenSwapApp 2>/dev/null || true)"
        if [[ -n "$running_pids_text" ]]; then
            running_pids=("${(@f)running_pids_text}")
            echo "Stopping running ScreenSwapApp before replacing $INSTALL_PATH"
            kill -TERM "${running_pids[@]}" 2>/dev/null || true
            for _ in {1..50}; do
                if ! pgrep -x ScreenSwapApp >/dev/null 2>&1; then
                    break
                fi
                sleep 0.1
            done
            if pgrep -x ScreenSwapApp >/dev/null 2>&1; then
                echo "error: running ScreenSwapApp did not stop; refusing to replace the installed bundle" >&2
                exit 1
            fi
        fi
        echo "Replacing $INSTALL_PATH"
        rm -rf "$INSTALL_PATH"
    fi
    echo "Installing $INSTALL_PATH"
    ditto "$APP_BUNDLE" "$INSTALL_PATH"
    codesign --verify --deep --strict "$INSTALL_PATH"
    echo "Launching the newly installed ScreenSwapApp"
    open "$INSTALL_PATH"
fi

echo "Packaged app: $APP_BUNDLE"
if $INSTALL; then
    echo "Installed app: $INSTALL_PATH"
fi
