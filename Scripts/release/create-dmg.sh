#!/usr/bin/env bash
#
# Build a distributable DMG from an exported, signed Browsemium.app.
#
# Usage:
#   Scripts/release/create-dmg.sh [path/to/Browsemium.app]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="${1:-${ROOT}/build/export/Browsemium.app}"
OUTPUT="${ROOT}/build/Browsemium.dmg"
STAGING="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
  echo "No app bundle at $APP_PATH. Run Scripts/release/build-archive.sh first." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$OUTPUT"
hdiutil create \
  -volname "Browsemium" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT"

hdiutil verify "$OUTPUT"
echo "DMG ready at $OUTPUT"
