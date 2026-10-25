#!/bin/bash
# Builds the throwaway sandboxed bundle in a temp directory, launches it,
# sends it Apple events, and quits it. Launches a tiny background app, so run
# it only when you are at the machine.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
app="$work/Throwaway.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/Throwaway.sdef" "$app/Contents/Resources/"
swiftc -O "$here/main.swift" -o "$app/Contents/MacOS/Throwaway"
codesign --force --sign - --entitlements "$here/ent.plist" "$app"
xmllint --noout --xinclude --dtdvalid /System/Library/DTDs/sdef.dtd "$here/Throwaway.sdef" && echo "sdef validates" || echo "sdef does NOT validate"
open -g "$app"; sleep 3
id=com.browsemium.spike.throwaway
for script in \
  "tell application id \"$id\" to open location \"https://example.com/a\"" \
  "tell application id \"$id\" to get tab titles"; do
  echo "== $script"
  perl -e 'alarm 30; exec @ARGV' osascript -e "$script" || echo "failed or timed out ($?)"
done
pkill -f "$app/Contents/MacOS/Throwaway" || true
echo "work directory: $work"
