#!/usr/bin/env python3
"""Parse and summarise Browsemium launch milestones.

Input is the text of `log show --style compact --predicate 'subsystem ==
"com.browsemium.launch"'`, one file per trial. Each milestone line looks like

    ... Browsemium[1234:5a6b] [com.browsemium.launch:Point] launch first-frame t+312ms

The `t+` figure is milliseconds since the app's first LaunchMetrics mark, so it
excludes time before the app's own code runs (the kernel and dyld). Say so
wherever a number is quoted.

The summary refuses to describe a run that did not finish: a trial without
every required milestone is invalid, and any invalid trial makes the whole run
invalid. Nothing here compares against another browser.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys

MILESTONES = ("process-start", "environment-ready", "model-ready", "first-frame", "first-navigation", "idle")
REQUIRED = ("first-frame", "idle")
LINE = re.compile(r"\[(?P<pid>\d+):[0-9a-fA-F]+\].*?launch (?P<name>[a-z-]+) t\+(?P<ms>\d+)ms")


def parse(text: str, pid: int | None = None) -> dict[str, int]:
    """First occurrence of each known milestone, optionally for one process."""
    found: dict[str, int] = {}
    for line in text.splitlines():
        match = LINE.search(line)
        if not match or match["name"] not in MILESTONES:
            continue
        if pid is not None and int(match["pid"]) != pid:
            continue
        found.setdefault(match["name"], int(match["ms"]))
    return found


def median(values: list[int]) -> float:
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return float(ordered[middle])
    return (ordered[middle - 1] + ordered[middle]) / 2


def percentile(values: list[int], fraction: float) -> int:
    """Nearest-rank percentile: the smallest value with at least `fraction` of
    the sample at or below it. With ten trials, p90 is the ninth value."""
    ordered = sorted(values)
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[rank - 1]


def summarize(trials: list[dict[str, int]], expected: int | None = None) -> dict:
    total = expected if expected is not None else len(trials)
    valid = [trial for trial in trials if all(name in trial for name in REQUIRED)]
    result: dict = {
        "method": "launch milestone, ms since the app's first mark (excludes kernel and dyld time)",
        "trials_requested": total,
        "trials_valid": len(valid),
        "status": "ok" if total > 0 and len(valid) == total else "invalid",
        "milestones": {},
    }
    if result["status"] == "ok":
        for name in MILESTONES:
            values = [trial[name] for trial in valid if name in trial]
            if values and len(values) == len(valid):
                result["milestones"][name] = {
                    "median_ms": median(values),
                    "p90_ms": percentile(values, 0.9),
                    "min_ms": min(values),
                    "max_ms": max(values),
                }
    return result


def summary_line(result: dict) -> str:
    if result["status"] != "ok":
        return (f"launch: INVALID ({result['trials_valid']}/{result['trials_requested']} trials reached "
                f"{' and '.join(REQUIRED)}); do not publish")
    frame = result["milestones"]["first-frame"]
    idle = result["milestones"]["idle"]
    return (f"launch: first-frame median {frame['median_ms']:g} ms, p90 {frame['p90_ms']} ms; "
            f"idle median {idle['median_ms']:g} ms, p90 {idle['p90_ms']} ms "
            f"({result['trials_valid']} trials)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", nargs="+", help="one log file per trial")
    parser.add_argument("--pid", action="append", type=int, default=[],
                        help="process id for the matching log, given once per trial in order")
    parser.add_argument("--expected", type=int, help="trials that were requested (default: number of files)")
    parser.add_argument("--has", metavar="MILESTONE",
                        help="print nothing; exit 0 if the first log reached MILESTONE, 1 if not")
    args = parser.parse_args(argv)
    if args.has:
        with open(args.logs[0], encoding="utf-8", errors="replace") as handle:
            return 0 if args.has in parse(handle.read(), args.pid[0] if args.pid else None) else 1
    if args.pid and len(args.pid) != len(args.logs):
        parser.error("give --pid once per log file, or not at all")

    trials = []
    for index, path in enumerate(args.logs):
        with open(path, encoding="utf-8", errors="replace") as handle:
            trials.append(parse(handle.read(), args.pid[index] if args.pid else None))
    result = summarize(trials, args.expected)
    print(json.dumps(result, indent=2, sort_keys=True))
    print(summary_line(result), file=sys.stderr)
    return 0 if result["status"] == "ok" else 4


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
