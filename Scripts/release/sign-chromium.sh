#!/usr/bin/env bash
#
# Sign a Browsemium Chromium app bundle inside-out.
#
# The bundle contains code Xcode never sees: the CEF framework and four helper
# apps created by Scripts/assemble-chromium-bundle.sh. Nested code has to be
# signed before the code that contains it, and `codesign --deep` is not an
# acceptable substitute (it re-signs with the wrong entitlements).
#
# The helper entitlements are the ones Chromium requires: a JIT, writable
# executable memory, and no library validation for the framework it loads.
#
# Usage:
#   Scripts/release/sign-chromium.sh <path to .app> [signing identity]
#
# With no identity the app is signed ad-hoc, which is what local Debug builds
# need. Releases pass a Developer ID.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="${1:?Pass the app bundle path}"
IDENTITY="${2:--}"
TIMESTAMP_FLAG="--timestamp=none"
if [[ "$IDENTITY" != "-" ]]; then
  TIMESTAMP_FLAG="--timestamp"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/helper.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST

# The app's own entitlements, which Xcode generated into the bundle.
codesign -d --entitlements :- "$APP" > "${WORK}/app.entitlements" 2>/dev/null || true
if [[ ! -s "${WORK}/app.entitlements" ]]; then
  cat > "${WORK}/app.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
fi

FRAMEWORKS="${APP}/Contents/Frameworks"
FRAMEWORK="${FRAMEWORKS}/Chromium Embedded Framework.framework"

echo "Signing the CEF framework…"
if [[ -d "$FRAMEWORK" ]]; then
  # The framework's own helpers (if any) first, then the framework itself.
  find "${FRAMEWORK}/Versions/A/Libraries" -name "*.dylib" -print0 2>/dev/null |
    while IFS= read -r -d '' library; do
      codesign --force --sign "$IDENTITY" $TIMESTAMP_FLAG "$library"
    done || true
  codesign --force --sign "$IDENTITY" $TIMESTAMP_FLAG "$FRAMEWORK"
fi

echo "Signing helper bundles…"
for helper in "${FRAMEWORKS}"/*Helper*.app; do
  [[ -d "$helper" ]] || continue
  codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP_FLAG \
    --entitlements "${WORK}/helper.entitlements" "$helper"
done

echo "Signing the app…"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP_FLAG \
  --entitlements "${WORK}/app.entitlements" "$APP"

codesign --verify --strict --verbose=1 "$APP" >/dev/null 2>&1 || {
  echo "Signature verification failed." >&2
  exit 1
}
echo "Signed $APP"
