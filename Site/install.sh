#!/bin/bash
# Browsemium installer.
#
# Apps fetched through a web browser get a quarantine flag, which is what makes
# macOS say "Apple can't check it for malicious software". Files fetched with
# curl carry no quarantine flag, so this install path opens without a warning.
#
# Integrity is still verified: the DMG's SHA-256 is checked against a checksum
# served from browsemium.vercel.app, a different host than the download.

set -euo pipefail

REPO="Cubinghackerz/browsemium"
CHECKSUM_URL="https://browsemium.vercel.app/checksum.txt"
TMP="$(mktemp -d)"
MOUNT=""

cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "→ Resolving the latest release…"
ASSET_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.dmg"' \
  | cut -d'"' -f4 | head -n1)"

if [ -z "$ASSET_URL" ]; then
  echo "✗ No DMG found in the latest release." >&2
  exit 1
fi

echo "→ Downloading $(basename "$ASSET_URL")…"
curl -fSL --progress-bar -o "$TMP/Browsemium.dmg" "$ASSET_URL"

echo "→ Verifying SHA-256…"
EXPECTED="$(curl -fsSL "$CHECKSUM_URL" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$TMP/Browsemium.dmg" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "✗ Checksum mismatch. Download may be corrupted — aborting." >&2
  echo "  expected: ${EXPECTED:-<none>}" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

echo "→ Mounting…"
MOUNT="$(hdiutil attach "$TMP/Browsemium.dmg" -nobrowse -readonly | tail -n1 | grep -o '/Volumes/.*')"
if [ ! -d "$MOUNT/Browsemium.app" ]; then
  echo "✗ DMG did not contain Browsemium.app" >&2
  exit 1
fi

if pgrep -f "/Applications/Browsemium.app/Contents/MacOS" >/dev/null 2>&1; then
  echo "→ Quitting the running copy…"
  osascript -e 'quit app "Browsemium"' 2>/dev/null || true
  sleep 1
fi

echo "→ Installing to /Applications…"
rm -rf /Applications/Browsemium.app
cp -R "$MOUNT/Browsemium.app" /Applications/

echo "✓ Installed — launching."
open -a /Applications/Browsemium.app
