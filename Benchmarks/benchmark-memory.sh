#!/usr/bin/env bash
#
# Fair idle-memory comparison between Browsemium and Chrome.
#
# Method:
#   1. Require the machine to be free of other WebKit activity, so the
#      measurement cannot be polluted by another app's page processes.
#   2. Start the fixture server and open the same ten pages in a clean profile.
#   3. Wait for load plus a settle period.
#   4. Sum resident memory for the launched process and every descendant, plus
#      (for Browsemium) the WebKit page processes that appeared during the run.
#      Chrome parents its own helpers, so its tree is complete on its own.
#   5. Repeat N times and compare medians.
#
# The 20% target is a release gate, not a marketing claim. If it fails, either
# keep optimizing or drop the comparative claim. Do not loosen the method to
# make it pass.
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

# `defaults read` needs an absolute path, and the trial runner should not
# depend on the caller's working directory.
absolute_app_path() {
  local path="$1"
  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi
  echo "$path"
}
BROWSEMIUM_APP="$(absolute_app_path "$BROWSEMIUM_APP")"
CHROME_APP="$(absolute_app_path "$CHROME_APP")"

for app in "$BROWSEMIUM_APP" "$CHROME_APP"; do
  if [[ ! -d "$app" ]]; then
    echo "No app bundle at $app" >&2
    exit 2
  fi
done

WORKDIR="$(mktemp -d)"
SERVER_PID=""
# Browsemium is sandboxed, so its profile directory has to live inside its own
# container. A system temp path is denied by the sandbox and the app silently
# falls back to an in-memory database, which would measure something other than
# the shipped browser.
BROWSEMIUM_TMP="${HOME}/Library/Containers/com.browsemium.browser/Data/tmp"
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
  if [[ -d "$BROWSEMIUM_TMP" ]]; then
    find "$BROWSEMIUM_TMP" -maxdepth 1 -name "browsemium-bench-*" -exec rm -rf {} + 2>/dev/null || true
  fi
}
trap cleanup EXIT

# process_tree_rss <root pid>
# Sums RSS (KB) for the process and every descendant. Matching by name is not
# enough: a second copy of the browser would be counted too, and WebKit's page
# processes do not carry the app's name at all.
process_tree_rss() {
  local root="$1"
  local pids="$root"
  local frontier="$root"
  while [[ -n "$frontier" ]]; do
    local next=""
    for pid in $frontier; do
      # `pgrep` exits non-zero when a process has no children, which `set -e`
      # would otherwise treat as a failed measurement.
      next+=" $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ' || true)"
    done
    next="$(echo "$next" | xargs)"
    [[ -z "$next" ]] && break
    pids+=" $next"
    frontier="$next"
  done
  # shellcheck disable=SC2086
  ps -o rss= -p $(echo "$pids" | tr ' ' ',') 2>/dev/null | awk '{ sum += $1 } END { printf "%d", sum }' || true
}

# webkit_page_processes_rss
# Every WebKit page process on the machine. WebKit spawns these through
# launchd, so they are not children of the app that asked for them and cannot
# be attributed directly. The caller takes a baseline before launching and
# attributes the difference to the run, which is why the pre-flight check
# below refuses to measure while another WebKit app is active.
webkit_page_processes_rss() {
  ps -axo rss=,command= | grep -F -- "/com.apple.WebKit." | grep -v grep | awk '{ sum += $1 } END { printf "%d", sum }' || true
}

webkit_page_process_count() {
  # A quiet machine means `grep` matches nothing and exits 1; with `pipefail`
  # that would abort the run instead of reporting zero.
  ps -axo command= | grep -F -- "/com.apple.WebKit." | grep -v grep | wc -l | tr -d ' ' || true
}

preflight_webkit_quiet() {
  local count
  count="$(webkit_page_process_count)"
  if [[ "$count" -gt 0 ]]; then
    echo "Refusing to measure: $count WebKit page process(es) are already running." >&2
    echo "Quit Safari, Mail, and any other WebKit app, then run this again." >&2
    echo "Without a quiet machine, another app's page processes would be counted" >&2
    echo "as Browsemium's memory." >&2
    exit 3
  fi
  # The `if` above leaves a non-zero status when the machine is quiet, which
  # `set -e` would treat as a failure of the caller.
  return 0
}

# run_trial <app-path> <profile-flag> <label> <url...>
# Echoes "<total kb> <app kb> <page kb>".
run_trial() {
  local app="$1"
  local profile="$2"
  local label="$3"
  shift 3

  local binary
  binary="$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
  if [[ -z "$binary" ]]; then
    echo "Could not read CFBundleExecutable from $app" >&2
    return 1
  fi

  # Chrome's first-run and default-browser UI would add a tab of its own to a
  # fresh profile. Browsemium has no equivalent, so suppressing them keeps the
  # two sides comparable.
  local extra=()
  if [[ "$label" == "Chrome" ]]; then
    extra=(--no-first-run --no-default-browser-check)
  fi

  local baseline
  baseline="$(webkit_page_processes_rss)"
  baseline="${baseline:-0}"

  # bash 3.2 (the system bash) treats an empty array expansion as unbound under
  # `set -u`, so the empty case is spelled out explicitly.
  "$app/Contents/MacOS/$binary" "$profile" ${extra[@]+"${extra[@]}"} "${@}" >/dev/null 2>&1 &
  local pid=$!
  sleep "$SETTLE"

  local app_rss page_rss
  app_rss="$(process_tree_rss "$pid")"
  app_rss="${app_rss:-0}"
  page_rss="$(webkit_page_processes_rss)"
  page_rss="${page_rss:-0}"
  page_rss=$(( page_rss - baseline ))
  [[ "$page_rss" -lt 0 ]] && page_rss=0

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # Page processes outlive a killed browser briefly; let them exit so the next
  # trial starts from a quiet machine.
  sleep 3

  echo "$(( app_rss + page_rss )) $app_rss $page_rss"
}
median() {
  sort -n | awk '{ values[NR] = $1 } END { if (NR == 0) { print 0 } else if (NR % 2) { print values[(NR + 1) / 2] } else { print int((values[NR / 2] + values[NR / 2 + 1]) / 2) } }'
}

echo "Reference run configuration:"
echo "  trials:      $TRIALS"
echo "  settle:      ${SETTLE}s"
echo "  pages:       ${#PAGES[@]}"
echo "  fixtures:    http://127.0.0.1:${PORT}/"
echo "  method:      process tree RSS + WebKit page processes that appeared"
echo

preflight_webkit_quiet

python3 "$(dirname "$0")/serve-fixtures.py" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

urls=()
for page in "${PAGES[@]}"; do
  urls+=("http://127.0.0.1:${PORT}/${page}")
done

mkdir -p "$BROWSEMIUM_TMP"

browsemium_results=()
chrome_results=()
invalid_trials=0

for trial in $(seq 1 "$TRIALS"); do
  echo "Trial ${trial}/${TRIALS}"
  b_profile="$BROWSEMIUM_TMP/browsemium-bench-${trial}"
  c_profile="$WORKDIR/chrome-${trial}"
  mkdir -p "$b_profile" "$c_profile"

  b_line="$(run_trial "$BROWSEMIUM_APP" "--profile-dir=$b_profile" "Browsemium" "${urls[@]}")"
  c_line="$(run_trial "$CHROME_APP" "--user-data-dir=$c_profile" "Chrome" "${urls[@]}")"

  b_total="${b_line%% *}"
  c_total="${c_line%% *}"
  b_pages="$(echo "$b_line" | awk '{ print $3 }')"
  browsemium_results+=("$b_total")
  chrome_results+=("$c_total")
  echo "  Browsemium: ${b_total} KB   (app ${b_line#* } KB)"
  echo "  Chrome:     ${c_total} KB   (app ${c_line#* } KB)"

  # A browser holding ten pages must have page processes. Zero means the pages
  # never loaded — usually a settle period shorter than the cold start — and
  # the run measured an empty browser.
  if [[ "${b_pages:-0}" -eq 0 ]]; then
    echo "  WARNING: no WebKit page processes appeared. The pages did not load," >&2
    echo "  so this trial measured an empty browser. Raise --settle and rerun." >&2
    invalid_trials=$(( invalid_trials + 1 ))
  fi
done

b_median="$(printf '%s\n' "${browsemium_results[@]}" | median)"
c_median="$(printf '%s\n' "${chrome_results[@]}" | median)"

echo
echo "Median resident memory across the process group:"
echo "  Browsemium: ${b_median} KB"
echo "  Chrome:     ${c_median} KB"

if [[ "$invalid_trials" -gt 0 ]]; then
  echo
  echo "Gate:       INVALID ($invalid_trials trial(s) loaded no pages)"
  echo "            Raise --settle until every trial reports page processes, then rerun."
  echo "            Do not publish a comparison from this run."
  exit 4
fi

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
