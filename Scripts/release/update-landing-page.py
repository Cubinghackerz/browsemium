#!/usr/bin/env python3
"""Update the release strip on the landing page for a published version.

Keeps version, DMG link, checksum, and the install command in one place so a
release never leaves the page pointing at an older build.
"""
import argparse
import pathlib
import re

SITE = pathlib.Path(__file__).resolve().parents[2] / "Site"
INDEX = SITE / "index.html"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()

    text = INDEX.read_text()
    replacements = [
        (r'(releases/(?:latest/)?download/(?:Browsemium-[\d.]+\.dmg|v[\d.]+/Browsemium-[\d.]+\.dmg))',
         f"releases/latest/download/Browsemium-{args.version}.dmg"),
        (r'(<span data-release-version>)[^<]*(</span>)', rf"\g<1>{args.version}\g<2>"),
        (r'(<code data-release-checksum>)[^<]*(</code>)', rf"\g<1>{args.sha256}\g<2>"),
        (r'(Browsemium-)[\d.]+(\.dmg)', rf"\g<1>{args.version}\g<2>"),
    ]
    for pattern, replacement in replacements:
        text = re.sub(pattern, replacement, text)

    INDEX.write_text(text)
    print(f"landing page updated for {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
