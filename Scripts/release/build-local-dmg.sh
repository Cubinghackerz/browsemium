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
#   BROWSEMIUM_BUILD_DIR=/tmp/browsemium-release Scripts/release/build-local-dmg.sh 2.1.0
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
BUILD_ROOT="${BROWSEMIUM_BUILD_DIR:-${ROOT}/build}"
LOCAL_BUILD_DIR="${BUILD_ROOT}/local"
APP_PATH="${LOCAL_BUILD_DIR}/Browsemium.app"
DMG_PATH="${BUILD_ROOT}/Browsemium-${VERSION}.dmg"
STAGING="$(mktemp -d)"
VALIDATION_PROFILE_DIR=""
PROFILE_PARENT="${HOME}/Library/Containers/com.browsemium.browser/Data/tmp"
PROFILE_ARGS=()

cleanup() {
  rm -rf "$STAGING"
  case "$VALIDATION_PROFILE_DIR" in
    "${PROFILE_PARENT}/browsemium-release-validation."*)
      rm -rf -- "$VALIDATION_PROFILE_DIR"
      ;;
  esac
}
trap cleanup EXIT

mkdir -p "$LOCAL_BUILD_DIR"

echo "Building Browsemium ${VERSION} (Release, ${ARCH_LABEL}, ad-hoc signed)…"
rm -rf "$APP_PATH"
xcodebuild \
  -project "${ROOT}/Browsemium.xcodeproj" \
  -scheme Browsemium \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "${LOCAL_BUILD_DIR}/DerivedData" \
  CONFIGURATION_BUILD_DIR="${LOCAL_BUILD_DIR}" \
  "${ARCH_FLAGS[@]}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(echo "$VERSION" | tr -cd '0-9')" \
  build > "${LOCAL_BUILD_DIR}/build.log" 2>&1 \
  || {
    echo "Build failed. Errors:" >&2
    grep -E "error:" "${LOCAL_BUILD_DIR}/build.log" | head -30 >&2
    echo "--- last 15 lines ---" >&2
    tail -15 "${LOCAL_BUILD_DIR}/build.log" >&2
    exit 1
  }

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
# before it is packaged, so nothing like that can be published again. These
# launches use a unique profile directory inside the app container so release
# validation never opens, kills, or changes the user's real browsing session.
echo "Launch test (10s)…"
LOG="${LOCAL_BUILD_DIR}/launch-test.log"
mkdir -p "$PROFILE_PARENT"
VALIDATION_PROFILE_DIR="$(mktemp -d "${PROFILE_PARENT}/browsemium-release-validation.XXXXXX")"
PROFILE_ARGS=("--profile-dir=${VALIDATION_PROFILE_DIR}")
"$APP_PATH/Contents/MacOS/Browsemium" "${PROFILE_ARGS[@]}" > "$LOG" 2>&1 &
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

# Crash recovery: the session must survive an abrupt kill. The app is started,
# killed with SIGKILL (no chance to flush anything), restarted, and the tab
# rows in its profile database are compared. A session that only survives a
# clean quit is not crash recovery.
echo "Crash-recovery test…"
PROFILE_DB="$(ls -t "${VALIDATION_PROFILE_DIR}"/profiles/*.sqlite 2>/dev/null | head -1 || true)"
# A marker file rather than a timestamp: `find -newermt "@epoch"` is not
# portable across the BSD find versions on CI runners, and a failing find
# inside a command substitution kills the script under `set -e` with no
# message at all.
CRASH_MARKER="${LOCAL_BUILD_DIR}/crash-marker"
touch "$CRASH_MARKER"
"$APP_PATH/Contents/MacOS/Browsemium" "${PROFILE_ARGS[@]}" > "${LOCAL_BUILD_DIR}/crash-test-1.log" 2>&1 &
CRASH_PID=$!
sleep 6
kill -9 "$CRASH_PID" 2>/dev/null || true
wait "$CRASH_PID" 2>/dev/null || true
TABS_BEFORE=""
if [ -n "$PROFILE_DB" ]; then
  TABS_BEFORE="$(sqlite3 "$PROFILE_DB" 'SELECT COUNT(*) FROM tabs' 2>/dev/null || true)"
fi
sleep 1
"$APP_PATH/Contents/MacOS/Browsemium" "${PROFILE_ARGS[@]}" > "${LOCAL_BUILD_DIR}/crash-test-2.log" 2>&1 &
CRASH_PID=$!
sleep 8
if ! kill -0 "$CRASH_PID" 2>/dev/null; then
  echo "The app did not survive a relaunch after SIGKILL — refusing to package." >&2
  tail -20 "${LOCAL_BUILD_DIR}/crash-test-2.log" >&2
  exit 1
fi
kill "$CRASH_PID" 2>/dev/null || true
wait "$CRASH_PID" 2>/dev/null || true
if [ -n "$PROFILE_DB" ] && [ -n "$TABS_BEFORE" ]; then
  TABS_AFTER="$(sqlite3 "$PROFILE_DB" 'SELECT COUNT(*) FROM tabs' 2>/dev/null || true)"
  if [ "$TABS_BEFORE" != "$TABS_AFTER" ]; then
    echo "The session changed across a crash: $TABS_BEFORE tabs before, $TABS_AFTER after." >&2
    exit 1
  fi
  echo "  relaunched cleanly after SIGKILL, session intact ($TABS_AFTER tabs)"
else
  echo "  relaunched cleanly after SIGKILL (no profile database yet)"
fi
CRASH_LOGS="$(find "${HOME}/Library/Logs/DiagnosticReports" -name 'Browsemium*' -newer "$CRASH_MARKER" 2>/dev/null | wc -l | tr -d ' ' || true)"
if [ -n "$CRASH_LOGS" ] && [ "$CRASH_LOGS" -gt 0 ]; then
  echo "A crash report was written during the recovery test — refusing to package." >&2
  find "${HOME}/Library/Logs/DiagnosticReports" -name 'Browsemium*' -newer "$CRASH_MARKER" >&2 || true
  exit 1
fi

mkdir -p "$BUILD_ROOT"
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
