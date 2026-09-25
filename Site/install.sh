#!/bin/bash
# Browsemium installer / updater.
#
# The downloaded artifact must pass four independent checks before installation:
# the published SHA-256, Developer ID signature, expected Apple team identity,
# and Apple's notarization/Gatekeeper assessment.
#
# Re-running this after a new release updates the app in place. Everything the
# browser stores — tabs, history, bookmarks, profiles, passwords, settings —
# lives in the app's container under ~/Library/Containers, not inside
# Browsemium.app, so replacing the bundle never touches it.

set -euo pipefail

REPO="Cubinghackerz/browsemium"
CHECKSUM_URL="https://browsemium.vercel.app/checksum.txt"
TEAM_ID_URL="https://browsemium.vercel.app/team-id.txt"
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
CHECKSUM_LINE="$(curl -fsSL "$CHECKSUM_URL")"
EXPECTED="$(printf '%s' "$CHECKSUM_LINE" | awk '{print $1}')"
EXPECTED_FILE="$(printf '%s' "$CHECKSUM_LINE" | awk '{print $2}')"
ACTUAL="$(shasum -a 256 "$TMP/Browsemium.dmg" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ] || [ "$EXPECTED_FILE" != "$(basename "$ASSET_URL")" ]; then
  echo "✗ Checksum mismatch. Download may be corrupted — aborting." >&2
  echo "  expected: ${EXPECTED:-<none>}" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

echo "→ Verifying notarization…"
xcrun stapler validate "$TMP/Browsemium.dmg" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=4 "$TMP/Browsemium.dmg"

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

if ! codesign --verify --deep --strict "$TMP/Browsemium.app" >/dev/null 2>&1; then
  echo "✗ The downloaded app failed signature verification — aborting." >&2
  exit 1
fi

EXPECTED_TEAM_ID="$(curl -fsSL "$TEAM_ID_URL" | tr -d '[:space:]')"
ACTUAL_TEAM_ID="$(codesign -dv --verbose=4 "$TMP/Browsemium.app" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
AUTHORITIES="$(codesign -dv --verbose=4 "$TMP/Browsemium.app" 2>&1 | awk -F= '/^Authority=/{print $2}')"
if ! printf '%s\n' "$EXPECTED_TEAM_ID" | grep -Eq '^[A-Z0-9]{10}$' \
   || [ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ] \
   || ! printf '%s\n' "$AUTHORITIES" | grep -q '^Developer ID Application:'; then
  echo "✗ The app is not signed by Browsemium's expected Developer ID team — aborting." >&2
  exit 1
fi
if ! spctl --assess --type execute --verbose=4 "$TMP/Browsemium.app"; then
  echo "✗ Gatekeeper rejected the app — aborting." >&2
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
