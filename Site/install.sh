#!/bin/bash
# Browsemium installer / updater.
#
# The downloaded artifact is checked against the published release manifest
# (release.json) before anything is installed: the manifest's version, file
# name, and SHA-256 must match the latest GitHub release exactly, and the DMG
# must pass hdiutil's integrity check. The app bundle is then verified
# according to the manifest's signing mode:
#
#   adhoc      preview builds — valid code signature, expected bundle id and
#              version, sandbox entitlement present, no get-task-allow, and
#              both arm64 and x86_64 slices. Not notarized by Apple; the
#              warning is printed before the app is copied.
#   notarized  release builds — all of the above plus stapler validation,
#              Gatekeeper assessment, the expected Developer ID team, and a
#              notarized ticket.
#
# Re-running this after a new release updates the app in place. Everything the
# browser stores — tabs, history, bookmarks, profiles, passwords, settings —
# lives in the app's container under ~/Library/Containers, not inside
# Browsemium.app, so replacing the bundle never touches it.
#
# Overrides (used by the test suite; safe to ignore):
#   BROWSEMIUM_SITE_URL      base for release.json/team-id.txt
#   BROWSEMIUM_RELEASE_API   "latest release" endpoint
#   BROWSEMIUM_APP_PATH      install target (default /Applications/Browsemium.app)
#   BROWSEMIUM_LAUNCH        set to 0 to skip launching after install

set -euo pipefail

REPO="Cubinghackerz/browsemium"
SITE_URL="${BROWSEMIUM_SITE_URL:-https://browsemium.vercel.app}"
RELEASE_API="${BROWSEMIUM_RELEASE_API:-https://api.github.com/repos/$REPO/releases/latest}"
MANIFEST_URL="${BROWSEMIUM_MANIFEST_URL:-$SITE_URL/release.json}"
TEAM_ID_URL="$SITE_URL/team-id.txt"
APP="${BROWSEMIUM_APP_PATH:-/Applications/Browsemium.app}"
LAUNCH="${BROWSEMIUM_LAUNCH:-1}"
TMP="$(mktemp -d)"
MOUNT=""
OLD=""

cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "✗ $1" >&2
  exit 1
}

json_field() {
  printf '%s' "$1" | grep -oE "\"$2\":[[:space:]]*\"[^\"]*\"" | cut -d'"' -f4 | head -n1
}

launch_app() {
  [ "$LAUNCH" = "1" ] || return 0
  open -a "$APP" 2>/dev/null || open "$APP"
}

echo "→ Resolving the latest release…"
RELEASE_JSON="$(curl -fsSL "$RELEASE_API")" || fail "Could not reach the release feed."
LATEST_TAG="$(json_field "$RELEASE_JSON" tag_name)"
LATEST_VERSION="${LATEST_TAG#v}"
ASSET_URL="$(printf '%s' "$RELEASE_JSON" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.dmg"' \
  | cut -d'"' -f4 | head -n1)"
[ -n "$ASSET_URL" ] && [ -n "$LATEST_VERSION" ] || fail "No DMG found in the latest release."

echo "→ Reading the published release manifest…"
MANIFEST="$(curl -fsSL "$MANIFEST_URL")" || fail "Could not read the release manifest."
MANIFEST_VERSION="$(json_field "$MANIFEST" version)"
MANIFEST_FILE="$(json_field "$MANIFEST" file)"
MANIFEST_SHA="$(json_field "$MANIFEST" sha256)"
SIGNING_MODE="$(json_field "$MANIFEST" signing)"
MANIFEST_TEAM="$(json_field "$MANIFEST" teamId)"
MANIFEST_BUNDLE_ID="$(json_field "$MANIFEST" bundleId)"

case "$SIGNING_MODE" in
  adhoc|notarized) ;;
  *) fail "Release manifest has an unknown signing mode: '${SIGNING_MODE:-<missing>}'" ;;
esac
[ -n "$MANIFEST_SHA" ] || fail "Release manifest is missing the SHA-256 checksum."

# The manifest is the published contract: if it does not describe the exact
# asset the latest release serves, something is out of sync — abort rather
# than guess.
if [ "$MANIFEST_VERSION" != "$LATEST_VERSION" ] \
   || [ "$MANIFEST_FILE" != "$(basename "$ASSET_URL")" ]; then
  echo "✗ Published metadata does not match the latest release — aborting." >&2
  echo "  manifest: ${MANIFEST_VERSION:-<none>} ${MANIFEST_FILE:-<none>}" >&2
  echo "  release:  $LATEST_VERSION $(basename "$ASSET_URL")" >&2
  exit 1
fi

INSTALLED_VERSION=""
if [ -d "$APP" ]; then
  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi
if [ -n "$INSTALLED_VERSION" ] && [ "$INSTALLED_VERSION" = "$MANIFEST_VERSION" ]; then
  echo "✓ Browsemium $INSTALLED_VERSION is already the latest release."
  if ! pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
    launch_app
  fi
  exit 0
fi

echo "→ Downloading ${MANIFEST_FILE}…"
curl -fSL --progress-bar -o "$TMP/$MANIFEST_FILE" "$ASSET_URL"

echo "→ Verifying DMG integrity…"
hdiutil verify "$TMP/$MANIFEST_FILE" >/dev/null \
  || fail "The downloaded DMG is damaged — aborting."

echo "→ Verifying SHA-256…"
ACTUAL="$(shasum -a 256 "$TMP/$MANIFEST_FILE" | awk '{print $1}')"
if [ "$ACTUAL" != "$MANIFEST_SHA" ]; then
  echo "✗ Checksum mismatch. Download may be corrupted — aborting." >&2
  echo "  expected: $MANIFEST_SHA" >&2
  echo "  actual:   $ACTUAL" >&2
  exit 1
fi

if [ "$SIGNING_MODE" = "notarized" ]; then
  echo "→ Verifying notarization…"
  xcrun stapler validate "$TMP/$MANIFEST_FILE" >/dev/null \
    || fail "Notarization ticket is missing from the DMG."
  spctl --assess --type open --context context:primary-signature --verbose=4 "$TMP/$MANIFEST_FILE" \
    || fail "Gatekeeper rejected the DMG."
fi

echo "→ Mounting…"
MOUNT="$(hdiutil attach "$TMP/$MANIFEST_FILE" -nobrowse -readonly | tail -n1 | grep -o '/Volumes/.*')"
[ -d "$MOUNT/Browsemium.app" ] || fail "DMG did not contain Browsemium.app"

# Stage the new bundle fully before the old one moves — a failed copy must
# never leave the Mac without a working Browsemium.
cp -R "$MOUNT/Browsemium.app" "$TMP/Browsemium.app"
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
MOUNT=""

echo "→ Verifying the app bundle…"
codesign --verify --deep --strict "$TMP/Browsemium.app" >/dev/null 2>&1 \
  || fail "The downloaded app failed signature verification — aborting."

APP_BINARY="$TMP/Browsemium.app/Contents/MacOS/Browsemium"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TMP/Browsemium.app/Contents/Info.plist" 2>/dev/null || true)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$TMP/Browsemium.app/Contents/Info.plist" 2>/dev/null || true)"
EXPECTED_BUNDLE_ID="${MANIFEST_BUNDLE_ID:-com.browsemium.browser}"
[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] \
  || fail "Unexpected bundle identifier '${BUNDLE_ID:-<none>}' — aborting."
[ "$BUNDLE_VERSION" = "$MANIFEST_VERSION" ] \
  || fail "Bundle version '${BUNDLE_VERSION:-<none>}' does not match the release — aborting."

ENTITLEMENTS="$(codesign -d --entitlements - "$TMP/Browsemium.app" 2>/dev/null || true)"
printf '%s' "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox" \
  || fail "The app is missing its sandbox entitlement — aborting."
printf '%s' "$ENTITLEMENTS" | grep -q "get-task-allow" \
  && fail "The app carries a debug entitlement — aborting."

ARCHS="$(lipo -archs "$APP_BINARY" 2>/dev/null || file "$APP_BINARY" || true)"
for arch in arm64 x86_64; do
  printf '%s' "$ARCHS" | grep -qw "$arch" \
    || fail "The app is missing the $arch architecture — aborting."
done

if [ "$SIGNING_MODE" = "adhoc" ]; then
  echo
  echo "  Browsemium $MANIFEST_VERSION is an ad-hoc signed preview build — it is"
  echo "  not notarized by Apple yet. The checksum, signature, sandbox, and"
  echo "  architectures above were verified, but macOS may still block the first"
  echo "  launch. If it does: System Settings → Privacy & Security → Open Anyway."
  echo
else
  EXPECTED_TEAM_ID="$MANIFEST_TEAM"
  if [ -z "$EXPECTED_TEAM_ID" ]; then
    EXPECTED_TEAM_ID="$(curl -fsSL "$TEAM_ID_URL" | tr -d '[:space:]')" || true
  fi
  SIGNATURE_INFO="$(codesign -dv --verbose=4 "$TMP/Browsemium.app" 2>&1 || true)"
  ACTUAL_TEAM_ID="$(printf '%s\n' "$SIGNATURE_INFO" | awk -F= '/^TeamIdentifier=/{print $2}')"
  AUTHORITIES="$(printf '%s\n' "$SIGNATURE_INFO" | awk -F= '/^Authority=/{print $2}')"
  if ! printf '%s\n' "$EXPECTED_TEAM_ID" | grep -Eq '^[A-Z0-9]{10}$' \
     || [ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ] \
     || ! printf '%s\n' "$AUTHORITIES" | grep -q '^Developer ID Application:'; then
    fail "The app is not signed by Browsemium's expected Developer ID team — aborting."
  fi
  spctl --assess --type execute --verbose=4 "$TMP/Browsemium.app" \
    || fail "Gatekeeper rejected the app — aborting."
fi

if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
  echo "→ Quitting the running copy (your session restores on relaunch)…"
  osascript -e 'quit app "Browsemium"' 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
    fail "Browsemium did not quit in time. Quit it yourself and re-run."
  fi
fi

INSTALL_DIR="$(dirname "$APP")"
mkdir -p "$INSTALL_DIR"
if [ -d "$APP" ]; then
  if [ -n "$INSTALLED_VERSION" ]; then
    echo "→ Updating $INSTALLED_VERSION → ${MANIFEST_VERSION}…"
  else
    echo "→ Replacing the existing copy…"
  fi
  OLD="$TMP/Browsemium-old.app"
  mv "$APP" "$OLD"
else
  echo "→ Installing to ${INSTALL_DIR}…"
fi

if ! cp -R "$TMP/Browsemium.app" "$APP"; then
  echo "✗ Install failed — restoring the previous copy." >&2
  [ -n "$OLD" ] && mv "$OLD" "$APP" && OLD=""
  exit 1
fi

echo "✓ Browsemium $MANIFEST_VERSION installed — your tabs, history, and profiles are untouched."
if [ "$LAUNCH" = "1" ]; then
  echo "  Launching."
  launch_app
fi
