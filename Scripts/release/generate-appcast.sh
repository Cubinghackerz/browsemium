#!/usr/bin/env bash
#
# Sign the release artifacts and generate a signed Sparkle appcast.
#
# Requires the Sparkle tooling shipped with the resolved package and an EdDSA
# private key stored in the login keychain (generate once with Sparkle's
# generate_keys tool; the public key belongs in Info.plist as SUPublicEDKey).
#
# Usage:
#   SPARKLE_BIN=/path/to/sparkle/bin DOWNLOAD_URL_PREFIX=https://example.com/releases \
#       Scripts/release/generate-appcast.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SPARKLE_BIN:?Set SPARKLE_BIN to the Sparkle bin directory from .build/artifacts}"
: "${DOWNLOAD_URL_PREFIX:?Set DOWNLOAD_URL_PREFIX to the HTTPS base URL hosting release artifacts}"

RELEASES_DIR="${ROOT}/build/releases"
mkdir -p "$RELEASES_DIR"

cp "${ROOT}/build/Browsemium.dmg" "$RELEASES_DIR/" 2>/dev/null || true

if [[ -z "$(ls -A "$RELEASES_DIR" 2>/dev/null)" ]]; then
  echo "No release artifacts found in $RELEASES_DIR" >&2
  exit 1
fi

"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --maximum-versions 3 \
  --maximum-deltas 1 \
  "$RELEASES_DIR"

echo "Signed appcast written to $RELEASES_DIR/appcast.xml"
echo "Verify that SUPublicEDKey in Info.plist matches the signing key and that SURequireSignedFeed is enabled."
