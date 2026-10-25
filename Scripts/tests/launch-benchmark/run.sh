#!/usr/bin/env bash
#
# Tests for Benchmarks/benchmark-launch.sh and parse-launch-metrics.py against
# canned LaunchMetrics logs. Launches nothing: every shell case either parses
# saved logs or is refused before a launch could happen.
#
#   Scripts/tests/launch-benchmark/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/Scripts/tests/launch-benchmark"
SCRIPT="$ROOT/Benchmarks/benchmark-launch.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s - %s\n' "$1" "$2"; }

# expect <name> <expected exit> <expected text or ""> -- command...
expect() {
  local name="$1" want="$2" text="$3"
  shift 4
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  if [[ "$status" -ne "$want" ]]; then bad "$name" "exit $status, wanted $want: $out"; return; fi
  if [[ -n "$text" && "$out" != *"$text"* ]]; then bad "$name" "output lacks \"$text\": $out"; return; fi
  ok "$name"
}

python3 "$HERE/test_parse_launch_metrics.py" >"$WORK/py.log" 2>&1 && ok "python parser tests" || { bad "python parser tests" "$(cat "$WORK/py.log")"; }

FAKE="$WORK/Fake.app"
mkdir -p "$FAKE/Contents/MacOS"
cat > "$FAKE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string></dict></plist>
PLIST

expect "from-logs good run exits 0 with ok JSON" 0 '"status": "ok"' -- "$SCRIPT" --from-logs "$HERE/fixtures/good"
expect "from-logs incomplete run is INVALID (exit 4)" 4 '"status": "invalid"' -- "$SCRIPT" --from-logs "$HERE/fixtures/incomplete"
expect "from-logs empty directory is a usage error" 2 "No trial-*.log" -- "$SCRIPT" --from-logs "$WORK"
expect "missing --app is a usage error" 2 "Usage" -- "$SCRIPT"
expect "unknown argument is refused" 2 "Unknown argument" -- "$SCRIPT" --bogus
expect "zero trials is refused" 2 "positive integer" -- "$SCRIPT" --app "$FAKE" --trials 0
expect "missing app bundle is refused" 2 "No app bundle" -- "$SCRIPT" --app "$WORK/Nope.app"
BROWSEMIUM_BENCH_WEBKIT_COUNT=3 expect "refuses while WebKit page processes run" 3 "WebKit page process" -- "$SCRIPT" --app "$FAKE" --trials 1
BROWSEMIUM_BENCH_WEBKIT_COUNT=0 BROWSEMIUM_BENCH_RUNNING=1 expect "refuses while Browsemium is running" 3 "already running" -- "$SCRIPT" --app "$FAKE" --trials 1

out="$WORK/summary.json"
"$SCRIPT" --from-logs "$HERE/fixtures/good" --output "$out" >/dev/null 2>&1
if python3 -c "import json,sys; d=json.load(open('$out')); sys.exit(0 if d['status']=='ok' and d['milestones']['first-frame']['median_ms']==300 else 1)"; then
  ok "--output writes the JSON summary"
else
  bad "--output writes the JSON summary" "unexpected file contents"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
