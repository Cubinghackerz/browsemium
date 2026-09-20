#!/usr/bin/env bash
#
# Sign the release artifacts and generate a signed Sparkle appcast.
#
# Requires the Sparkle tooling shipped with the resolved package and the
# repository's EdDSA private key (the public key belongs in Info.plist as
# SUPublicEDKey). The key is deliberately passed to Sparkle explicitly so the
# generated appcast gets a feed signature as well as signed archive entries.
#
# Usage:
#   SPARKLE_BIN=/path/to/sparkle/bin DOWNLOAD_URL_PREFIX=https://example.com/releases \
#       Scripts/release/generate-appcast.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SPARKLE_BIN:?Set SPARKLE_BIN to the Sparkle bin directory from .build/artifacts}"
: "${DOWNLOAD_URL_PREFIX:?Set DOWNLOAD_URL_PREFIX to the HTTPS base URL hosting release artifacts}"

SPARKLE_KEY_FILE="${SPARKLE_ED_KEY_FILE:-$HOME/.config/browsemium/sparkle-ed25519.key}"
if [[ ! -f "$SPARKLE_KEY_FILE" ]]; then
  echo "Missing Sparkle EdDSA key: $SPARKLE_KEY_FILE" >&2
  exit 1
fi

RELEASES_DIR="${ROOT}/build/releases"
mkdir -p "$RELEASES_DIR"

cp "${ROOT}/build/Browsemium.dmg" "$RELEASES_DIR/" 2>/dev/null || true

if [[ -z "$(ls -A "$RELEASES_DIR" 2>/dev/null)" ]]; then
  echo "No release artifacts found in $RELEASES_DIR" >&2
  exit 1
fi

"${SPARKLE_BIN}/generate_appcast" \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --maximum-versions 3 \
  --maximum-deltas 1 \
  "$RELEASES_DIR"

"${SPARKLE_BIN}/sign_update" \
  --verify \
  --ed-key-file "$SPARKLE_KEY_FILE" \
  "$RELEASES_DIR/appcast.xml"

echo "Signed appcast written to $RELEASES_DIR/appcast.xml"
echo "Verify that SUPublicEDKey in Info.plist matches the signing key and that SURequireSignedFeed is enabled."
