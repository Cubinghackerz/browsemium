#!/usr/bin/env bash
#
# Fixture-driven tests for Site/install.sh — no network, no /Applications.
#
# Each case builds a fake Browsemium.app (a real Mach-O binary, ad-hoc signed
# with chosen entitlements), packs it into a real DMG, and runs the installer
# against file:// fixtures for the release manifest and the "latest release"
# feed. Asserts the exit code and the message that should accompany it.
#
#   Scripts/tests/installer/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALLER="$ROOT/Site/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
VERSION="9.9.9"
FILE="Browsemium-${VERSION}.dmg"

info()  { printf '  %s\n' "$*"; }
ok()    { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s — %s\n' "$1" "$2"; }

# --- fixture builders ---------------------------------------------------

build_app() {
  # dest version bundle_id archs(universal|arm64) entitlements(sandbox|debug|none)
  local app="$1" version="$2" bid="$3" archs="$4" ents="$5"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bid}</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleExecutable</key><string>Browsemium</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
  printf 'int main(void){return 0;}\n' > "$WORK/main.c"
  if [[ "$archs" == "universal" ]]; then
    clang -arch arm64 -arch x86_64 -o "$app/Contents/MacOS/Browsemium" "$WORK/main.c"
  else
    clang -arch "$archs" -o "$app/Contents/MacOS/Browsemium" "$WORK/main.c"
  fi
  if [[ "$ents" != "none" ]]; then
    local ents_file="$WORK/ents-${ents}.plist"
    cat > "$ents_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
$( [[ "$ents" == "debug" ]] && printf '<key>get-task-allow</key><true/>' )
</dict></plist>
EOF
    codesign --force --sign - --entitlements "$ents_file" "$app" >/dev/null 2>&1
  else
    codesign --force --sign - "$app" >/dev/null 2>&1
  fi
}

build_dmg() {
  # app dmg
  local staging="$WORK/staging-$2"
  rm -rf "$staging"; mkdir -p "$staging"
  cp -R "$1" "$staging/Browsemium.app"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname Browsemium -srcfolder "$staging" -ov -format UDZO "$2" >/dev/null
}

write_manifest() {
  # dir signing sha app_file
  cat > "$1/release.json" <<EOF
{
  "version": "${VERSION}",
  "tag": "v${VERSION}",
  "file": "$4",
  "sha256": "$3",
  "signing": "$2",
  "bundleId": "com.browsemium.browser",
  "teamId": "",
  "minimumMacOS": "14.0"
}
EOF
}

write_latest() {
  # path dmg_url
  cat > "$1" <<EOF
{"tag_name":"v${VERSION}","assets":[{"browser_download_url":"$2"}]}
EOF
}

new_case() {
  # name -> echoes site dir; creates install dir
  local site="$WORK/site-$1"
  mkdir -p "$site" "$WORK/install-$1"
  printf '%s' "$site"
}

run_installer() {
  # name extra_env... -> prints exit code on stdout (log at $WORK/log-NAME)
  local name="$1"; shift
  set +e
  env BROWSEMIUM_SITE_URL="file://$WORK/site-$name" \
      BROWSEMIUM_RELEASE_API="file://$WORK/latest-$name.json" \
      BROWSEMIUM_APP_PATH="$WORK/install-$name/Browsemium.app" \
      BROWSEMIUM_LAUNCH=0 \
      PATH="$WORK/shims:$PATH" "$@" \
      bash "$INSTALLER" > "$WORK/log-$name" 2>&1
  local code=$?
  set -e
  printf '%s' "$code"
}

expect() {
  # name expected_code grep_pattern
  local name="$1" want="$2" pattern="$3" code
  code="$(cat "$WORK/code-$name" 2>/dev/null || true)"
  if [[ "$code" != "$want" ]]; then
    bad "$name" "exit $code (wanted $want): $(tail -3 "$WORK/log-$name" | LC_ALL=C tr '\n' ' ')"
    return
  fi
  if ! grep -q "$pattern" "$WORK/log-$name"; then
    bad "$name" "missing '$pattern' in: $(tail -3 "$WORK/log-$name" | LC_ALL=C tr '\n' ' ')"
    return
  fi
  ok "$name"
}

run() { # name
  run_installer "$1" > "$WORK/code-$1"
}

# A `cp` shim that can fail one destination substring — used to exercise the
# installer's rollback path without touching real state.
mkdir -p "$WORK/shims"
cat > "$WORK/shims/cp" <<'EOF'
#!/bin/bash
if [[ -n "${BROWSEMIUM_BLOCK_COPY:-}" ]]; then
  last=""
  for a in "$@"; do last="$a"; done
  case "$last" in *"$BROWSEMIUM_BLOCK_COPY"*) exit 1 ;; esac
fi
exec /bin/cp "$@"
EOF
chmod +x "$WORK/shims/cp"

# --- cases ---------------------------------------------------------------

info "Building fixtures…"

# 1. Happy path: valid universal app, adhoc manifest.
SITE="$(new_case happy)"
build_app "$WORK/good.app" "$VERSION" com.browsemium.browser universal sandbox
build_dmg "$WORK/good.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-happy.json" "file://$SITE/$FILE"
run happy
expect happy 0 "installed"
[[ -x "$WORK/install-happy/Browsemium.app/Contents/MacOS/Browsemium" ]] \
  && ok "happy-binary-present" || bad "happy-binary-present" "app not installed"

# 2. Checksum mismatch.
SITE="$(new_case checksum)"
cp "$WORK/site-happy/$FILE" "$SITE/$FILE"
write_manifest "$SITE" adhoc "0000000000000000000000000000000000000000000000000000000000000000" "$FILE"
write_latest "$WORK/latest-checksum.json" "file://$SITE/$FILE"
run checksum
expect checksum 1 "Checksum mismatch"
[[ ! -e "$WORK/install-checksum/Browsemium.app" ]] \
  && ok "checksum-nothing-installed" || bad "checksum-nothing-installed" "app present"

# 3. Wrong bundle identifier.
SITE="$(new_case bundleid)"
build_app "$WORK/wrongid.app" "$VERSION" com.notbrowsemium.browser universal sandbox
build_dmg "$WORK/wrongid.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-bundleid.json" "file://$SITE/$FILE"
run bundleid
expect bundleid 1 "Unexpected bundle identifier"

# 4. Bundle version does not match the manifest.
SITE="$(new_case bundleversion)"
build_app "$WORK/wrongver.app" "9.9.8" com.browsemium.browser universal sandbox
build_dmg "$WORK/wrongver.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-bundleversion.json" "file://$SITE/$FILE"
run bundleversion
expect bundleversion 1 "Bundle version"

# 5. Missing sandbox entitlement.
SITE="$(new_case nosandbox)"
build_app "$WORK/nosandbox.app" "$VERSION" com.browsemium.browser universal none
build_dmg "$WORK/nosandbox.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-nosandbox.json" "file://$SITE/$FILE"
run nosandbox
expect nosandbox 1 "sandbox entitlement"

# 6. Debug entitlement present.
SITE="$(new_case debugent)"
build_app "$WORK/debug.app" "$VERSION" com.browsemium.browser universal debug
build_dmg "$WORK/debug.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-debugent.json" "file://$SITE/$FILE"
run debugent
expect debugent 1 "debug entitlement"

# 7. Missing x86_64 slice.
SITE="$(new_case armonly)"
build_app "$WORK/armonly.app" "$VERSION" com.browsemium.browser arm64 sandbox
build_dmg "$WORK/armonly.app" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-armonly.json" "file://$SITE/$FILE"
run armonly
expect armonly 1 "missing the x86_64"

# 8. Malformed DMG.
SITE="$(new_case baddmg)"
printf 'this is not a disk image' > "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-baddmg.json" "file://$SITE/$FILE"
run baddmg
expect baddmg 1 "damaged"

# 9. Manifest/release mismatch (manifest names a different file).
SITE="$(new_case manifestmismatch)"
cp "$WORK/site-happy/$FILE" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "Browsemium-other.dmg"
write_latest "$WORK/latest-manifestmismatch.json" "file://$SITE/$FILE"
run manifestmismatch
expect manifestmismatch 1 "does not match"

# 10. Manifest declares notarized but the artifact is ad-hoc: stapler must fail it.
SITE="$(new_case notarized)"
cp "$WORK/site-happy/$FILE" "$SITE/$FILE"
write_manifest "$SITE" notarized "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-notarized.json" "file://$SITE/$FILE"
run notarized
expect notarized 1 "Notarization ticket"

# 11. Rollback: the final copy fails, the previous copy must come back.
SITE="$(new_case rollback)"
cp "$WORK/site-happy/$FILE" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-rollback.json" "file://$SITE/$FILE"
build_app "$WORK/install-rollback/Browsemium.app" "9.9.0" com.browsemium.browser universal sandbox
run_installer rollback BROWSEMIUM_BLOCK_COPY="install-rollback/Browsemium.app" > "$WORK/code-rollback"
expect rollback 1 "restoring the previous copy"
RESTORED="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$WORK/install-rollback/Browsemium.app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$RESTORED" == "9.9.0" ]] \
  && ok "rollback-restored" || bad "rollback-restored" "found version '${RESTORED:-<none>}'"

# 12. Already-current shortcut.
SITE="$(new_case current)"
cp "$WORK/site-happy/$FILE" "$SITE/$FILE"
write_manifest "$SITE" adhoc "$(shasum -a 256 "$SITE/$FILE" | awk '{print $1}')" "$FILE"
write_latest "$WORK/latest-current.json" "file://$SITE/$FILE"
build_app "$WORK/install-current/Browsemium.app" "$VERSION" com.browsemium.browser universal sandbox
run current
expect current 0 "already the latest"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
