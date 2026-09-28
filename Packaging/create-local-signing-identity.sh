#!/bin/zsh

# Creates one persistent, local-only code-signing identity for ScreenSwap
# development installs. A stable certificate makes the application's
# designated requirement stable across rebuilds, allowing macOS to retain its
# Accessibility authorization for the installed bundle.

set -euo pipefail

IDENTITY_NAME="ScreenSwap Local Development"
KEYCHAIN_PATH="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "Local ScreenSwap signing identity already exists."
    exit 0
fi

WORK_DIR="$(mktemp -d -t screenswap-signing)"
trap 'rm -rf "$WORK_DIR"' EXIT

PRIVATE_KEY="$WORK_DIR/private-key.pem"
CERTIFICATE="$WORK_DIR/certificate.pem"
PROFILE="$WORK_DIR/signing-profile.conf"
ARCHIVE="$WORK_DIR/identity.p12"
ARCHIVE_PASSWORD="$(openssl rand -hex 24)"

cat > "$PROFILE" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $IDENTITY_NAME
OU = Local Development
O = ScreenSwap

[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE" \
    -config "$PROFILE" >/dev/null 2>&1
# macOS Security.framework cannot import OpenSSL 3's default PKCS#12
# algorithms, so force its legacy-compatible archive format.
openssl pkcs12 -export -legacy -macalg sha1 -out "$ARCHIVE" \
    -inkey "$PRIVATE_KEY" -in "$CERTIFICATE" \
    -passout "pass:$ARCHIVE_PASSWORD" >/dev/null 2>&1

security import "$ARCHIVE" -k "$KEYCHAIN_PATH" -P "$ARCHIVE_PASSWORD" -T /usr/bin/codesign >/dev/null
# The certificate is trusted only by this login keychain. This is necessary
# for a self-signed certificate to form a stable trusted code requirement.
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" "$CERTIFICATE" >/dev/null

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "error: local ScreenSwap signing identity was not created" >&2
    exit 1
fi

echo "Created local ScreenSwap signing identity. Future installed builds will preserve Accessibility authorization."
