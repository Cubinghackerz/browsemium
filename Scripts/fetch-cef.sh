#!/usr/bin/env bash
#
# Fetch the pinned Chromium Embedded Framework binary distribution.
#
# CEF is not vendored in the repository: the macOS distribution is ~130 MB
# compressed and ~300 MB unpacked, so it is downloaded on demand and ignored by
# git. The version is pinned here and the SHA-1 is checked against the value CEF
# publishes in its own index (https://cef-builds.spotifycdn.com/index.json), so a
# tampered or truncated download cannot be built into an app.
#
# The pin deliberately trails the newest build on the branch by at least a week:
# CEF publishes a new build most days, and a build that has been out for a while
# is the one that has been exercised by other embedders. Bump the pin as part of
# an engine update, not on the day a build appears.
#
# Usage:
#   Scripts/fetch-cef.sh            # download and unpack if missing
#   Scripts/fetch-cef.sh --force    # re-download
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# CEF 152.0.6 (Chromium 152.0.7977.83), published 2026-09-07.
CEF_VERSION="152.0.6+g708dc14+chromium-152.0.7977.83"
CEF_SHA1="426836139b0ea7b7278aa0915cfae90eb460551f"
CEF_DIST="cef_binary_${CEF_VERSION}_macosarm64_minimal.tar.bz2"
CEF_URL="https://cef-builds.spotifycdn.com/${CEF_DIST}"

DEST="${ROOT}/Vendors/CEF"
UNPACKED="${DEST}/cef_binary_${CEF_VERSION}_macosarm64_minimal"
ARCHIVE="${DEST}/${CEF_DIST}"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -d "$UNPACKED" && "$FORCE" -eq 0 ]]; then
  echo "CEF already unpacked at $UNPACKED"
  # The build settings reach CEF through this stable path.
  ln -sfn "$(basename "$UNPACKED")" "${DEST}/current"
  exit 0
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This pin is for Apple silicon (macosarm64). Intel needs its own distribution." >&2
  exit 1
fi

mkdir -p "$DEST"

if [[ ! -f "$ARCHIVE" || "$FORCE" -eq 1 ]]; then
  echo "Downloading $CEF_DIST (~131 MB)…"
  curl -fL --retry 3 --progress-bar -o "$ARCHIVE" "$CEF_URL"
fi

echo "Verifying SHA-1…"
ACTUAL_SHA1="$(shasum -a 1 "$ARCHIVE" | awk '{ print $1 }')"
if [[ "$ACTUAL_SHA1" != "$CEF_SHA1" ]]; then
  echo "SHA-1 mismatch for $CEF_DIST" >&2
  echo "  expected $CEF_SHA1" >&2
  echo "  actual   $ACTUAL_SHA1" >&2
  rm -f "$ARCHIVE"
  exit 1
fi

echo "Unpacking…"
rm -rf "$UNPACKED"
tar -xjf "$ARCHIVE" -C "$DEST"

for required in "include/cef_app.h" "libcef_dll/CMakeLists.txt" "Release/Chromium Embedded Framework.framework"; do
  if [[ ! -e "${UNPACKED}/${required}" ]]; then
    echo "Distribution is missing ${required}" >&2
    exit 1
  fi
done

# A stable path for the build settings, so project.yml does not have to carry
# the version string of the day.
ln -sfn "$(basename "$UNPACKED")" "${DEST}/current"

echo "CEF ready at $UNPACKED"
echo "  stable path: ${DEST}/current"
echo "  framework:   ${DEST}/current/Release/Chromium Embedded Framework.framework"
echo "  wrapper:     build it with Scripts/build-cef-wrapper.sh"
