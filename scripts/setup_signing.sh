#!/bin/bash
# FrameShare — by Anton Pushkin
# One-time setup: creates a self-signed "FrameShare Local Signing" certificate in your login keychain.
# Builds signed with it keep the same identity, so macOS remembers the Screen Recording
# permission across rebuilds. The certificate is only used to sign this app on this Mac.
set -euo pipefail
NAME="FrameShare Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:frameshare -name "$NAME"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P frameshare -T /usr/bin/codesign
echo "Created \"$NAME\". Now run ./scripts/build_app.sh --install"
echo "(The first build may ask to let codesign use the key: choose Always Allow.)"
