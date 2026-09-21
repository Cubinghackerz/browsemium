#!/usr/bin/env bash
#
# Build libcef_dll_wrapper from the pinned CEF distribution.
#
# CEF's binary distribution ships the C++ wrapper as source and expects CMake to
# build it. This script does the same job with clang directly, so the project
# needs no CMake (and no generator step) just to link CEF. The flags mirror the
# ones in cmake/cef_variables.cmake for a release build on macOS.
#
# Run Scripts/fetch-cef.sh first.
#
# Usage:
#   Scripts/build-cef-wrapper.sh            # build if missing
#   Scripts/build-cef-wrapper.sh --force    # rebuild
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CEF_ROOT="$(find "${ROOT}/Vendors/CEF" -maxdepth 1 -type d -name "cef_binary_*_macosarm64_minimal" 2>/dev/null | sort | tail -1)"

if [[ -z "$CEF_ROOT" ]]; then
  echo "No CEF distribution found. Run Scripts/fetch-cef.sh first." >&2
  exit 1
fi

WRAPPER_SRC="${CEF_ROOT}/libcef_dll"
BUILD_DIR="${CEF_ROOT}/build"
ARCHIVE="${BUILD_DIR}/libcef_dll_wrapper.a"
OBJECT_DIR="${BUILD_DIR}/obj"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -f "$ARCHIVE" && "$FORCE" -eq 0 ]]; then
  echo "Wrapper already built at $ARCHIVE"
  exit 0
fi

mkdir -p "$BUILD_DIR"

# Wrapper sources: everything under libcef_dll plus the two Objective-C++ files
# the macOS loader needs.
SOURCES_FILE="${BUILD_DIR}/sources.txt"
{
  find "$WRAPPER_SRC" -name "*.cc"
  echo "${WRAPPER_SRC}/wrapper/cef_scoped_library_loader_mac.mm"
  echo "${WRAPPER_SRC}/wrapper/cef_scoped_sandbox_context_mac.mm"
} | sort > "$SOURCES_FILE"

SOURCE_COUNT="$(wc -l < "$SOURCES_FILE" | tr -d ' ')"
echo "Compiling ${SOURCE_COUNT} wrapper sources…"

rm -rf "$OBJECT_DIR"
mkdir -p "$OBJECT_DIR"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export CEF_ROOT WRAPPER_SRC OBJECT_DIR

compile_one() {
  local source="$1"
  local relative="${source#"$WRAPPER_SRC"/}"
  local object="${OBJECT_DIR}/${relative//\//_}.o"
  # -DWRAPPING_CEF_SHARED is required for every wrapper translation unit; the
  # rest mirror CEF's own release flags.
  clang++ -c "$source" -o "$object" \
    -std=c++20 \
    -DWRAPPING_CEF_SHARED \
    -I"$CEF_ROOT" \
    -I"$CEF_ROOT/include" \
    -I"$WRAPPER_SRC" \
    -O2 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fvisibility-inlines-hidden \
    -Wno-unused-parameter -Wno-comment -Wno-deprecated-declarations -Wno-sign-compare \
    -mmacosx-version-min=14.0
  echo "$object"
}
export -f compile_one

# shellcheck disable=SC2016
xargs -P "$JOBS" -I{} bash -c 'compile_one "$@"' _ {} < "$SOURCES_FILE" > /dev/null

rm -f "$ARCHIVE"
libtool -static -o "$ARCHIVE" "$OBJECT_DIR"/*.o > /dev/null 2>&1 \
  || ar rcs "$ARCHIVE" "$OBJECT_DIR"/*.o

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Wrapper archive was not produced." >&2
  exit 1
fi

echo "Wrapper ready at $ARCHIVE"
