#!/usr/bin/env bash
#
# Notarize and staple the Browsemium DMG.
#
# Credentials are read from the keychain profile named by NOTARY_PROFILE, so no
# secret ever appears in this script or in CI logs.
#
# Setup once:
#   xcrun notarytool store-credentials browsemium-notary \
#       --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
# Usage:
#   NOTARY_PROFILE=browsemium-notary Scripts/release/notarize.sh [path/to/Browsemium.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DMG_PATH="${1:-${ROOT}/build/Browsemium.dmg}"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "No DMG at $DMG_PATH. Run Scripts/release/create-dmg.sh first." >&2
  exit 1
fi

echo "Submitting $DMG_PATH for notarization…"
if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait
else
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE, or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID}"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "Stapling the notarization ticket…"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Checking Gatekeeper acceptance…"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "Notarized and stapled: $DMG_PATH"
