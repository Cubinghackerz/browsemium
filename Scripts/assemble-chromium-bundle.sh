#!/usr/bin/env bash
#
# Assemble the Chromium pieces inside a Browsemium Chromium app bundle.
#
# CEF mandates a specific bundle layout on macOS: the framework in
# Contents/Frameworks, and four helper app bundles (helper, GPU, plugin,
# renderer) so each process type can carry its own entitlements when the app is
# signed for distribution. Xcode does not know about those helpers, so they are
# created here and signed inside-out by Scripts/release/sign-chromium.sh.
#
# Usage:
#   Scripts/assemble-chromium-bundle.sh <path to .app> <path to helper binary>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Pass the app bundle path}"
HELPER_BINARY="${2:?Pass the helper executable path}"

CEF_CURRENT="${ROOT}/Vendors/CEF/current"
FRAMEWORK_SOURCE="${CEF_CURRENT}/Release/Chromium Embedded Framework.framework"
if [[ ! -d "$FRAMEWORK_SOURCE" ]]; then
  echo "CEF is not fetched. Run Scripts/fetch-cef.sh first." >&2
  exit 1
fi

APP_NAME="$(defaults read "$APP/Contents/Info.plist" CFBundleExecutable)"
BUNDLE_ID="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
BUILD_VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"

FRAMEWORKS="${APP}/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

echo "Embedding the CEF framework…"
rm -rf "${FRAMEWORKS}/Chromium Embedded Framework.framework"
cp -R "$FRAMEWORK_SOURCE" "${FRAMEWORKS}/Chromium Embedded Framework.framework"

# Xcode 26 requires the versioned framework layout with relative symlinks.
FRAMEWORK="${FRAMEWORKS}/Chromium Embedded Framework.framework"
if [[ ! -d "${FRAMEWORK}/Versions/A" ]]; then
  (
    cd "$FRAMEWORK"
    mkdir -p Versions/A
    mv "Chromium Embedded Framework" Libraries Resources Versions/A/ 2>/dev/null || true
    ln -sfn A Versions/Current
    ln -sfn "Versions/Current/Chromium Embedded Framework" "Chromium Embedded Framework"
    ln -sfn "Versions/Current/Libraries" Libraries
    ln -sfn "Versions/Current/Resources" Resources
  )
fi

echo "Creating helper bundles…"
# CEF derives helper names from the app executable: "<name> Helper.app" plus the
# parenthesized variants listed in CEF_HELPER_APP_SUFFIXES (cef_variables.cmake).
# The bundle id suffixes are the lowercase plist suffixes from the same list.
create_helper() {
  local name_suffix="$1"   # e.g. " (GPU)" — empty for the base helper
  local id_suffix="$2"     # e.g. ".gpu"   — empty for the base helper
  local name="${APP_NAME} Helper${name_suffix}"
  local helper_app="${FRAMEWORKS}/${name}.app"
  rm -rf "$helper_app"
  mkdir -p "${helper_app}/Contents/MacOS"

  cp "$HELPER_BINARY" "${helper_app}/Contents/MacOS/${name}"
  chmod +x "${helper_app}/Contents/MacOS/${name}"

  cat > "${helper_app}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.helper${id_suffix}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
}

create_helper "" ""
create_helper " (Alerts)" ".alerts"
create_helper " (GPU)" ".gpu"
create_helper " (Plugin)" ".plugin"
create_helper " (Renderer)" ".renderer"

echo "Bundle assembled at $APP"
