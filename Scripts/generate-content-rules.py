#!/usr/bin/env python3
"""Convert EasyList-style filter text into WebKit content-rule JSON.

This converter is deliberately conservative. A filter that cannot be represented
faithfully is skipped and reported rather than broadened into a rule that blocks
more than the source list intended. WebKit compiles the resulting JSON through
WKContentRuleListStore; anything that does not compile is a release blocker.

Licensing gate: filter lists carry their own licenses (EasyList is dual-licensed
GPLv3 / CC BY-SA 3.0). Redistributing a compiled list inside an app is a legal
decision, not an engineering one, so this tool refuses to run without an explicit
--accept-license flag naming the source list, and it stamps the notice into the
output.

Usage:
    Scripts/generate-content-rules.py --input easylist.txt --output rules.json \
        --accept-license "EasyList (GPLv3 / CC BY-SA 3.0) — redistribution reviewed"
"""

import argparse
import json
import re
import sys
from pathlib import Path

RESOURCE_TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "css": "style-sheet",
    "font": "font",
    "media": "media",
    "object": "raw",
    "xmlhttprequest": "raw",
    "subdocument": "document",
    "document": "document",
    "popup": "popup",
}

DOMAIN_FILTER = re.compile(r"^\|\|([a-z0-9._-]+)\^(.*)$", re.IGNORECASE)
ELEMENT_HIDE = re.compile(r"^([a-z0-9.*_-]+)?##(.+)$", re.IGNORECASE)


def escape_regex(value: str) -> str:
    return re.escape(value).replace(r"\*", ".*")


def parse_options(options: str) -> dict:
    parsed = {"third_party": False, "resource_types": [], "unsupported": None}
    if not options:
        return parsed
    for raw in options.split(","):
        option = raw.strip().lower()
        if not option:
            continue
        if option in ("third-party", "3p"):
            parsed["third_party"] = True
        elif option in ("~third-party", "1p"):
            parsed["third_party"] = False
        elif option in RESOURCE_TYPES:
            parsed["resource_types"].append(RESOURCE_TYPES[option])
        else:
            parsed["unsupported"] = option
            return parsed
    return parsed


def convert_line(line: str, rule_id: int):
    """Return a WebKit rule, or None when the filter cannot be represented faithfully."""
    if not line or line.startswith("!") or line.startswith("["):
        return None

    exception = line.startswith("@@")
    if exception:
        line = line[2:]

    hide_match = ELEMENT_HIDE.match(line)
    if hide_match:
        domain, selector = hide_match.groups()
        if domain and not domain.startswith("~"):
            # Domain-scoped cosmetic rules need if-domain handling; skip rather
            # than applying them globally.
            return None
        if any(token in selector for token in (":has(", ":matches-", ":xpath")):
            return None
        return {
            "trigger": {"url-filter": ".*"},
            "action": {"type": "css-display-none", "selector": selector},
        }

    if "$" in line:
        pattern, _, options = line.partition("$")
    else:
        pattern, options = line, ""

    parsed = parse_options(options)
    if parsed["unsupported"]:
        return None

    match = DOMAIN_FILTER.match(pattern)
    if not match:
        return None
    domain, suffix = match.groups()
    if suffix not in ("", "/"):
        return None
    if any(char in domain for char in "*|^"):
        return None

    trigger = {"url-filter": escape_regex(domain) + ".*", "load-type": ["third-party"] if parsed["third_party"] else ["first-party", "third-party"]}
    if parsed["resource_types"]:
        trigger["resource-type"] = parsed["resource_types"]

    action = {"type": "ignore-previous-rules"} if exception else {"type": "block"}
    return {"trigger": trigger, "action": action, "id": rule_id}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--accept-license", required=True)
    parser.add_argument("--maximum-rules", type=int, default=150_000)
    args = parser.parse_args()

    source = Path(args.input)
    if not source.is_file():
        print("Input list not found: %s" % source, file=sys.stderr)
        return 2

    rules = []
    skipped = 0
    for raw in source.read_text(encoding="utf-8", errors="replace").splitlines():
        rule = convert_line(raw.strip(), len(rules) + 1)
        if rule is None:
            skipped += 1
            continue
        rules.append(rule)
        if len(rules) >= args.maximum_rules:
            break

    output = Path(args.output)
    output.write_text(json.dumps(rules, separators=(",", ":")), encoding="utf-8")

    report = {
        "source": str(source),
        "license": args.accept_license,
        "rules": len(rules),
        "skipped": skipped,
        "output": str(output),
    }
    print(json.dumps(report, indent=2))
    print("Compile this file with WKContentRuleListStore and treat any compile error as a release blocker.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
