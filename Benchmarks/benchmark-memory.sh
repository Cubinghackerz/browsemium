#!/usr/bin/env bash
#
# Fair idle-memory comparison between Browsemium and Chrome.
#
# Method:
#   1. Start the fixture server and open the same ten pages in a clean profile.
#   2. Wait for load plus a settle period.
#   3. Sum the resident memory of the whole process group (browser + engine
#      helpers), not just the main process.
#   4. Repeat N times and compare medians.
#
# The 20% target is a release gate, not a marketing claim. If it fails, either
# keep optimizing or drop the comparative claim.
#
# Usage:
#   Benchmarks/benchmark-memory.sh --browsemium /Applications/Browsemium.app \
#       --chrome "/Applications/Google Chrome.app" --trials 5 --settle 60
set -euo pipefail

BROWSEMIUM_APP=""
CHROME_APP=""
TRIALS=5
SETTLE=60
PORT=8791
PAGES=(
  "01-article.html" "02-docs.html" "03-dashboard.html" "04-gallery.html" "05-form.html"
  "06-list.html" "07-canvas.html" "08-media.html" "09-longdoc.html" "10-report.html"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browsemium) BROWSEMIUM_APP="$2"; shift 2 ;;
    --chrome) CHROME_APP="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BROWSEMIUM_APP" || -z "$CHROME_APP" ]]; then
  echo "Usage: $0 --browsemium <path to Browsemium.app> --chrome <path to Google Chrome.app>" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

python3 "$(dirname "$0")/serve-fixtures.py" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

urls=()
for page in "${PAGES[@]}"; do
  urls+=("http://127.0.0.1:${PORT}/${page}")
done

# process_group_rss <pattern>
# Sums RSS (KB) for every process whose command line matches the pattern.
process_group_rss() {
  local pattern="$1"
  ps -axo rss=,command= | grep -F -- "$pattern" | grep -v grep | awk '{ sum += $1 } END { printf "%d", sum }'
}

# run_trial <app-path> <profile-flag> <match-pattern> <url...>
run_trial() {
  local app="$1"
  local profile="$2"
  local pattern="$3"
  shift 3

  local binary
  binary="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
  if [[ -z "$binary" ]]; then
    echo "Could not read CFBundleExecutable from $app" >&2
    return 1
  fi

  "$app/Contents/MacOS/$binary" "$profile" "${@}" >/dev/null 2>&1 &
  local pid=$!
  sleep "$SETTLE"

  local rss_kb
  rss_kb="$(process_group_rss "$pattern")"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo "$rss_kb"
}

median() {
  sort -n | awk '{ values[NR] = $1 } END { if (NR == 0) { print 0 } else if (NR % 2) { print values[(NR + 1) / 2] } else { print int((values[NR / 2] + values[NR / 2 + 1]) / 2) } }'
}

echo "Reference run configuration:"
echo "  trials:      $TRIALS"
echo "  settle:      ${SETTLE}s"
echo "  pages:       ${#PAGES[@]}"
echo "  fixtures:    http://127.0.0.1:${PORT}/"
echo

browsemium_results=()
chrome_results=()

for trial in $(seq 1 "$TRIALS"); do
  echo "Trial ${trial}/${TRIALS}"
  b_profile="$WORKDIR/browsemium-${trial}"
  c_profile="$WORKDIR/chrome-${trial}"
  mkdir -p "$b_profile" "$c_profile"

  b_rss="$(run_trial "$BROWSEMIUM_APP" "--profile-dir=$b_profile" "Browsemium" "${urls[@]}")"
  c_rss="$(run_trial "$CHROME_APP" "--user-data-dir=$c_profile" "Google Chrome" "${urls[@]}")"

  browsemium_results+=("$b_rss")
  chrome_results+=("$c_rss")
  echo "  Browsemium: ${b_rss} KB   Chrome: ${c_rss} KB"
done

b_median="$(printf '%s\n' "${browsemium_results[@]}" | median)"
c_median="$(printf '%s\n' "${chrome_results[@]}" | median)"

echo
echo "Median resident memory across the process group:"
echo "  Browsemium: ${b_median} KB"
echo "  Chrome:     ${c_median} KB"

if [[ "$c_median" -gt 0 ]]; then
  reduction=$(( (c_median - b_median) * 100 / c_median ))
  echo "  Reduction:  ${reduction}%"
  if [[ "$reduction" -ge 20 ]]; then
    echo "  Gate:       PASS (target is at least 20% lower than Chrome)"
  else
    echo "  Gate:       FAIL (do not publish a lower-memory claim)"
  fi
fi

echo
echo "Record the Mac model, RAM, macOS build, both browser versions, and power mode with these numbers."
echo "Cross-check once with Activity Monitor or Instruments before publishing any comparison."
