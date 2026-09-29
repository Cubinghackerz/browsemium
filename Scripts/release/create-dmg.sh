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
mkdir -p "${ROOT}/build"
STAGING="$(mktemp -d)"
MOUNT="$(mktemp -d)"
DMG_WORK="$(mktemp -d "${ROOT}/build/browsemium-dmg.XXXXXX")"
RW_DMG="${DMG_WORK}/Browsemium-rw.dmg"
READY_DMG="${DMG_WORK}/Browsemium.dmg"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then
    hdiutil detach "$MOUNT" -quiet || true
  fi
  rm -rf "$STAGING"
  rm -rf "$MOUNT"
  rm -rf "$DMG_WORK"
}
trap cleanup EXIT

if [[ ! -d "$APP_PATH" ]]; then
  echo "No app bundle at $APP_PATH. Run Scripts/release/build-archive.sh first." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$ROOT/Brand/dmg-background.png" "$STAGING/.background/background.png"
cp "$ROOT/Brand/Browsemium.icns" "$STAGING/.VolumeIcon.icns"

hdiutil create \
  -volname "Browsemium" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  "$RW_DMG"

hdiutil attach "$RW_DMG" -nobrowse -quiet -mountpoint "$MOUNT"
MOUNTED=1
# hdiutil has no -volicon flag; the volume's custom-icon bit makes
# .VolumeIcon.icns visible in Finder.
xcrun SetFile -a C "$MOUNT"
osascript - "$MOUNT" <<'APPLESCRIPT' &
on run argv
    set mountPath to item 1 of argv
    set mountFolder to POSIX file mountPath as alias
    set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias
    tell application "Finder"
        open mountFolder
        set current view of front window to icon view
        set toolbar visible of front window to false
        set statusbar visible of front window to false
        set bounds of front window to {100, 100, 820, 580}
        set options to icon view options of front window
        set arrangement of options to not arranged
        set icon size of options to 112
        set background picture of options to backgroundFile
        set position of item "Browsemium.app" of front window to {180, 255}
        set position of item "Applications" of front window to {540, 255}
        close front window
        open mountFolder
        update front window without registering applications
    end tell
end run
APPLESCRIPT
LAYOUT_PID=$!
for ((layout_wait = 0; layout_wait < 15; layout_wait++)); do
  if ! kill -0 "$LAYOUT_PID" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$LAYOUT_PID" 2>/dev/null; then
  kill "$LAYOUT_PID"
fi
if wait "$LAYOUT_PID"; then
  echo "Finder layout saved."
else
  echo "Finder layout was unavailable; keeping a verified DMG without the custom window arrangement." >&2
fi
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
hdiutil convert "$RW_DMG" -format UDZO -o "$READY_DMG" -ov

hdiutil verify "$READY_DMG"
mv -f "$READY_DMG" "$OUTPUT"
echo "DMG ready at $OUTPUT"
