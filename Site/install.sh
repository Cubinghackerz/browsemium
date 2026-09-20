#!/bin/bash
# Browsemium installer / updater.
#
# Apps fetched through a web browser get a quarantine flag, which is what makes
# macOS say "Apple can't check it for malicious software". Files fetched with
# curl carry no quarantine flag, so this install path opens without a warning.
#
# Integrity is still verified: the DMG's SHA-256 is checked against a checksum
# served from browsemium.vercel.app, a different host than the download.
#
# Re-running this after a new release updates the app in place. Everything the
# browser stores — tabs, history, bookmarks, profiles, passwords, settings —
# lives in the app's container under ~/Library/Containers, not inside
# Browsemium.app, so replacing the bundle never touches it.

set -euo pipefail

REPO="Cubinghackerz/browsemium"
CHECKSUM_URL="https://browsemium.vercel.app/checksum.txt"
APP="/Applications/Browsemium.app"
TMP="$(mktemp -d)"
MOUNT=""
OLD=""

cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "→ Resolving the latest release…"
RELEASE_JSON="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")"
LATEST_TAG="$(printf '%s' "$RELEASE_JSON" | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | cut -d'"' -f4 | head -n1)"
LATEST_VERSION="${LATEST_TAG#v}"
ASSET_URL="$(printf '%s' "$RELEASE_JSON" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.dmg"' \
  | cut -d'"' -f4 | head -n1)"

if [ -z "$ASSET_URL" ] || [ -z "$LATEST_VERSION" ]; then
  echo "✗ No DMG found in the latest release." >&2
  exit 1
fi

INSTALLED_VERSION=""
if [ -d "$APP" ]; then
  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi
if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
  echo "✓ Browsemium $INSTALLED_VERSION is already the latest release."
  if ! pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
    open -a "$APP"
  fi
  exit 0
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

# Stage the new bundle fully before the old one moves — a failed copy must
# never leave the Mac without a working Browsemium.
cp -R "$MOUNT/Browsemium.app" "$TMP/Browsemium.app"
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
MOUNT=""

if ! codesign --verify --strict "$TMP/Browsemium.app" >/dev/null 2>&1; then
  echo "✗ The downloaded app failed signature verification — aborting." >&2
  exit 1
fi

if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
  echo "→ Quitting the running copy (your session restores on relaunch)…"
  osascript -e 'quit app "Browsemium"' 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
    echo "✗ Browsemium did not quit in time. Quit it yourself and re-run." >&2
    exit 1
  fi
fi

if [ -d "$APP" ]; then
  if [ -n "$INSTALLED_VERSION" ]; then
    echo "→ Updating $INSTALLED_VERSION → ${LATEST_VERSION}…"
  else
    echo "→ Replacing the existing copy…"
  fi
  OLD="$TMP/Browsemium-old.app"
  mv "$APP" "$OLD"
else
  echo "→ Installing to /Applications…"
fi

if ! cp -R "$TMP/Browsemium.app" /Applications/; then
  echo "✗ Install failed — restoring the previous copy." >&2
  [ -n "$OLD" ] && mv "$OLD" "$APP" && OLD=""
  exit 1
fi

echo "✓ Browsemium $LATEST_VERSION installed — your tabs, history, and profiles are untouched. Launching."
open -a "$APP"
