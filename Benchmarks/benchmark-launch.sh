#!/usr/bin/env bash
#
# Launch-to-first-frame timing for Browsemium, from the app's own LaunchMetrics
# milestones (subsystem com.browsemium.launch).
#
# Method:
#   1. Refuse to run while any WebKit page process exists (another app's
#      activity would slow the launch) or while Browsemium is already running.
#   2. For each trial, launch the app on a fresh profile directory inside its
#      sandbox container, wait for the `idle` milestone (or the timeout), quit
#      it, and keep that trial's milestone log.
#   3. Summarise the trials: median and p90 per milestone. A trial that never
#      reaches first-frame and idle makes the whole run INVALID, and nothing is
#      reported as a result.
#
# What the numbers mean: milliseconds since the app's first mark, so kernel and
# dyld time before the app's code runs is not included, and the file cache is
# warm (nothing here runs `purge`, which needs root). Do not call it "cold
# launch" without saying so. It is a regression number for this app on this
# Mac, not a comparison with another browser, and it is not a marketing claim.
#
# Usage:
#   Benchmarks/benchmark-launch.sh --app /Applications/Browsemium.app --trials 10
#   Benchmarks/benchmark-launch.sh --from-logs DIR     # re-parse saved trial logs; launches nothing
#
# Options:
#   --app PATH       Browsemium.app to measure
#   --trials N       default 10
#   --timeout SEC    per-trial wait for `idle`, default 30
#   --output FILE    also write the JSON summary here
#   --keep-logs DIR  copy each trial's raw log here
#   --from-logs DIR  parse trial-*.log files in DIR instead of launching
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$HERE/parse-launch-metrics.py"
APP=""
TRIALS=10
TIMEOUT=30
OUTPUT=""
KEEP_LOGS=""
FROM_LOGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --keep-logs) KEEP_LOGS="$2"; shift 2 ;;
    --from-logs) FROM_LOGS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
  echo "--trials must be a positive integer" >&2
  exit 2
fi

summarize() {
  # summarize <expected trials> <log files...>
  local expected="$1"
  shift
  local json status=0
  json="$(python3 "$PARSER" --expected "$expected" "$@")" || status=$?
  echo "$json"
  [[ -n "$OUTPUT" ]] && echo "$json" > "$OUTPUT"
  return "$status"
}

if [[ -n "$FROM_LOGS" ]]; then
  logs=()
  while IFS= read -r file; do logs+=("$file"); done < <(find "$FROM_LOGS" -maxdepth 1 -name 'trial-*.log' | sort)
  if [[ ${#logs[@]} -eq 0 ]]; then
    echo "No trial-*.log files in $FROM_LOGS" >&2
    exit 2
  fi
  summarize "${#logs[@]}" "${logs[@]}"
  exit $?
fi

if [[ -z "$APP" ]]; then
  echo "Usage: $0 --app <path to Browsemium.app> [--trials N] [--timeout SEC] [--output FILE]" >&2
  exit 2
fi
[[ "$APP" != /* ]] && APP="$PWD/$APP"
if [[ ! -d "$APP" ]]; then
  echo "No app bundle at $APP" >&2
  exit 2
fi
BINARY="$(defaults read "$APP/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
if [[ -z "$BINARY" ]]; then
  echo "Could not read CFBundleExecutable from $APP" >&2
  exit 2
fi

# BROWSEMIUM_BENCH_WEBKIT_COUNT exists only so the refusal path can be tested
# without a running WebKit app; it supplies a count and nothing else.
webkit_page_process_count() {
  if [[ -n "${BROWSEMIUM_BENCH_WEBKIT_COUNT:-}" ]]; then
    echo "$BROWSEMIUM_BENCH_WEBKIT_COUNT"
    return 0
  fi
  ps -axo command= | grep -F -- "/com.apple.WebKit." | grep -v grep | wc -l | tr -d ' ' || true
}

browsemium_running() {
  [[ -n "${BROWSEMIUM_BENCH_RUNNING:-}" ]] && { echo "$BROWSEMIUM_BENCH_RUNNING"; return 0; }
  pgrep -f "$APP/Contents/MacOS/$BINARY" 2>/dev/null | wc -l | tr -d ' ' || true
}

count="$(webkit_page_process_count)"
if [[ "${count:-0}" -gt 0 ]]; then
  echo "Refusing to measure: $count WebKit page process(es) are already running." >&2
  echo "Quit Safari, Mail, and any other WebKit app, then run this again." >&2
  exit 3
fi
if [[ "$(browsemium_running)" -gt 0 ]]; then
  echo "Refusing to measure: Browsemium is already running. Quit it first." >&2
  exit 3
fi

WORKDIR="$(mktemp -d)"
CONTAINER_TMP="${HOME}/Library/Containers/com.browsemium.browser/Data/tmp"
cleanup() {
  rm -rf "$WORKDIR"
  find "$CONTAINER_TMP" -maxdepth 1 -name "browsemium-launch-*" -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$CONTAINER_TMP"
[[ -n "$KEEP_LOGS" ]] && mkdir -p "$KEEP_LOGS"

echo "Reference run configuration:"
echo "  trials:   $TRIALS"
echo "  timeout:  ${TIMEOUT}s per trial (waits for the idle milestone)"
echo "  profile:  fresh directory per trial"
echo "  note:     file cache is warm; times exclude kernel and dyld"
echo

logs=()
for trial in $(seq 1 "$TRIALS"); do
  profile="$CONTAINER_TMP/browsemium-launch-${trial}"
  rm -rf "$profile"; mkdir -p "$profile"
  started="$(date '+%Y-%m-%d %H:%M:%S')"
  "$APP/Contents/MacOS/$BINARY" "--profile-dir=$profile" >/dev/null 2>&1 &
  pid=$!

  waited=0
  logfile="$WORKDIR/trial-${trial}.log"
  : > "$logfile"
  while [[ "$waited" -lt "$TIMEOUT" ]]; do
    sleep 1
    waited=$(( waited + 1 ))
    log show --style compact --start "$started" \
      --predicate 'subsystem == "com.browsemium.launch"' > "$logfile" 2>/dev/null || true
    if python3 "$PARSER" --has idle --pid "$pid" "$logfile"; then
      break
    fi
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Page processes outlive a killed browser briefly; the next trial must start quiet.
  sleep 3

  # Keep only this process's lines, so a stale earlier run cannot leak in.
  grep -E "\[$pid:" "$logfile" > "$logfile.pid" || true
  mv "$logfile.pid" "$logfile"
  [[ -n "$KEEP_LOGS" ]] && cp "$logfile" "$KEEP_LOGS/"
  logs+=("$logfile")
  echo "  trial ${trial}/${TRIALS}: $(grep -c 'launch ' "$logfile" || true) milestone line(s)"
done

echo
summarize "$TRIALS" "${logs[@]}"
