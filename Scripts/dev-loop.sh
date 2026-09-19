#!/usr/bin/env bash
# Watches Browsemium sources and, on every change, rebuilds the app and
# relaunches it so the running browser always reflects the latest edits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/.build-stamp"
APP="$HOME/Library/Developer/Xcode/DerivedData/Browsemium-euclzbktcfmxhvfhepobawvmwcvy/Build/Products/Debug/Browsemium.app"

touch "$STAMP"

echo "[dev-loop] watching $ROOT for changes"
while true; do
    sleep 4
    CHANGED=$(find "$ROOT/Packages/BrowsemiumKit/Sources" "$ROOT/BrowsemiumApp" \
        -name '*.swift' -newer "$STAMP" 2>/dev/null | head -1)
    if [ -z "$CHANGED" ]; then
        continue
    fi
    touch "$STAMP"
    echo "[dev-loop] change detected: $CHANGED — rebuilding"
    if xcodebuild -project "$ROOT/Browsemium.xcodeproj" -scheme Browsemium \
        -configuration Debug -destination 'platform=macOS' build \
        > /tmp/browsemium-devloop-build.log 2>&1; then
        echo "[dev-loop] build succeeded — relaunching"
        osascript -e 'quit app "Browsemium"' >/dev/null 2>&1
        sleep 1
        open "$APP"
    else
        echo "[dev-loop] build failed — see /tmp/browsemium-devloop-build.log"
        grep -E "error:" /tmp/browsemium-devloop-build.log | head -5
    fi
done
