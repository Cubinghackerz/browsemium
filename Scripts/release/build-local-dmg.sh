#!/usr/bin/env bash
#
# Build an installable DMG without a Developer ID.
#
# This is the "download it and try it" path: a Release build, ad-hoc signed,
# with the sandbox entitlements intact, packaged with an Applications symlink
# so it installs by dragging.
#
# What it is not: notarized. Gatekeeper will warn the first time it is opened
# on another Mac ("Apple could not verify…"), and the user has to allow it in
# System Settings > Privacy & Security. On this Mac it opens normally. Public
# distribution still needs a Developer ID and Scripts/release/notarize.sh.
#
# Usage:
#   Scripts/release/build-local-dmg.sh [version] [--universal]
#
# Builds the host architecture by default because a universal build compiles
# every dependency twice and takes several minutes. Pass --universal for a DMG
# that runs on both Apple silicon and Intel.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="1.0"
UNIVERSAL=0
for argument in "$@"; do
  case "$argument" in
    --universal) UNIVERSAL=1 ;;
    *) VERSION="$argument" ;;
  esac
done

# Set ARCHS rather than passing -arch: a generic destination already implies an
# architecture, and xcodebuild rejects both together.
if [[ "$UNIVERSAL" == "1" ]]; then
  ARCH_FLAGS=(ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
  ARCH_LABEL="universal"
else
  ARCH_FLAGS=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
  ARCH_LABEL="$(uname -m)"
fi
BUILD_DIR="${ROOT}/build"
APP_PATH="${BUILD_DIR}/local/Browsemium.app"
DMG_PATH="${BUILD_DIR}/Browsemium-${VERSION}.dmg"
STAGING="$(mktemp -d)"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

mkdir -p "${BUILD_DIR}/local"

echo "Building Browsemium ${VERSION} (Release, ${ARCH_LABEL}, ad-hoc signed)…"
rm -rf "$APP_PATH"
xcodebuild \
  -project "${ROOT}/Browsemium.xcodeproj" \
  -scheme Browsemium \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${BUILD_DIR}/local/DerivedData" \
  CONFIGURATION_BUILD_DIR="${BUILD_DIR}/local" \
  "${ARCH_FLAGS[@]}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(echo "$VERSION" | tr -cd '0-9')" \
  build > "${BUILD_DIR}/local/build.log" 2>&1 \
  || { tail -30 "${BUILD_DIR}/local/build.log" >&2; exit 1; }

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build did not produce Browsemium.app" >&2
  exit 1
fi

echo "Verifying the bundle…"
codesign --verify --strict --verbose=2 "$APP_PATH"
if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "app-sandbox"; then
  echo "  sandbox entitlement: present"
else
  echo "  sandbox entitlement: MISSING — refusing to package" >&2
  exit 1
fi
if codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
  echo "  get-task-allow present in a Release build — refusing to package" >&2
  exit 1
fi

# A Release build once shipped that crashed on launch: optimisation exposed a
# memory bug that Debug hid. The bundle has to prove it starts and stays up
# before it is packaged, so nothing like that can be published again.
echo "Launch test (10s)…"
LOG="${BUILD_DIR}/local/launch-test.log"
"$APP_PATH/Contents/MacOS/Browsemium" > "$LOG" 2>&1 &
LAUNCH_PID=$!
sleep 10
if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
  echo "The built app exited within 10 seconds — refusing to package." >&2
  tail -20 "$LOG" >&2
  exit 1
fi
kill "$LAUNCH_PID" 2>/dev/null || true
wait "$LAUNCH_PID" 2>/dev/null || true
if grep -qiE "fatal error|Trace/BPT trap|Segmentation fault" "$LOG"; then
  echo "The launch test logged a crash — refusing to package." >&2
  tail -20 "$LOG" >&2
  exit 1
fi
echo "  launched and stayed up for 10s"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Browsemium" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

echo
echo "DMG ready:  $DMG_PATH  (${SIZE})"
echo "SHA-256:    ${SHA}"
echo
echo "Ad-hoc signed and NOT notarized. It opens normally on this Mac; other Macs"
echo "will show a Gatekeeper warning that the user must allow once in"
echo "System Settings > Privacy & Security."
