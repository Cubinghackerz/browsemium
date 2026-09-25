#!/usr/bin/env bash
#
# Archive Browsemium for distribution.
#
# Requires: full Xcode selected, a Developer ID Application certificate in the
# login keychain, and a matching team ID. Exits non-zero if any prerequisite is
# missing so a release can never silently ship an unsigned build.
#
# Usage:
#   DEVELOPMENT_TEAM=ABCDE12345 Scripts/release/build-archive.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${ROOT}/build"
ARCHIVE_PATH="${BUILD_DIR}/Browsemium.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple Developer team ID}"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required (xcode-select -p currently points at Command Line Tools)." >&2
  exit 1
fi

if [[ ! -f "${ROOT}/Browsemium.xcodeproj/project.pbxproj" ]]; then
  echo "Generating the Xcode project from project.yml…"
  (cd "$ROOT" && xcodegen generate --spec project.yml)
fi

mkdir -p "$BUILD_DIR"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

ARCHIVE_ARGS=(
  archive
  -project "${ROOT}/Browsemium.xcodeproj"
  -scheme Browsemium
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  CODE_SIGN_STYLE=Automatic
)
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${ARCHIVE_ARGS[@]}" | xcbeautify
else
  xcodebuild "${ARCHIVE_ARGS[@]}"
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_PATH"

APP_PATH="${EXPORT_PATH}/Browsemium.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Export did not produce Browsemium.app" >&2
  exit 1
fi

echo "Verifying signature and entitlements…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - "$APP_PATH" | tee "${BUILD_DIR}/entitlements.txt"

if grep -q "get-task-allow" "${BUILD_DIR}/entitlements.txt"; then
  echo "Release build contains the get-task-allow entitlement." >&2
  exit 1
fi

echo "Archive ready at $APP_PATH"
