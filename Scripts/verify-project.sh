#!/usr/bin/env bash
#
# Regenerate the Xcode project and fail if the committed project drifted from
# project.yml. Keeps the reproducible-project contract honest.
#
# Usage:
#   Scripts/verify-project.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -d Browsemium.xcodeproj ]]; then
  echo "No committed Browsemium.xcodeproj. Run: xcodegen generate --spec project.yml" >&2
  exit 1
fi

BACKUP="$(mktemp -d)"
cp -R Browsemium.xcodeproj "$BACKUP/"
trap 'rm -rf "$BACKUP"' EXIT

xcodegen generate --spec project.yml

if ! diff -r --exclude="xcuserdata" "$BACKUP/Browsemium.xcodeproj" Browsemium.xcodeproj >/dev/null; then
  echo "Browsemium.xcodeproj is out of date. Regenerate it and commit the result." >&2
  diff -r --exclude="xcuserdata" "$BACKUP/Browsemium.xcodeproj" Browsemium.xcodeproj | head -40 >&2
  exit 1
fi

echo "Browsemium.xcodeproj matches project.yml"
