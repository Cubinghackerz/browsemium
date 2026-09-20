#!/usr/bin/env python3
"""Update Site/appcast.xml and Site/checksum.txt for a published release.

Usage:
    update-appcast.py --version 2.0.0 --signature <edSignature> \
        --size <bytes> --sha256 <hex>

The newest item is prepended to the channel; older items are kept so users on
older builds can still update.
"""
import argparse
import email.utils
import pathlib
import re
import sys

SITE = pathlib.Path(__file__).resolve().parents[2] / "Site"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--size", required=True)
    parser.add_argument("--sha256", required=True)
    args = parser.parse_args()

    build = re.sub(r"\D", "", args.version)
    appcast_path = SITE / "appcast.xml"
    text = appcast_path.read_text()

    item = f"""    <item>
      <title>Browsemium {args.version}</title>
      <sparkle:releaseNotesLink>https://github.com/Cubinghackerz/browsemium/releases/tag/v{args.version}</sparkle:releaseNotesLink>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/Cubinghackerz/browsemium/releases/download/v{args.version}/Browsemium-{args.version}.dmg"
        sparkle:version="{build}"
        sparkle:shortVersionString="{args.version}"
        sparkle:edSignature="{args.signature}"
        length="{args.size}"
        type="application/octet-stream" />
    </item>
"""

    # Replace an existing item for this version, otherwise prepend.
    existing = re.compile(
        r"    <item>(?:(?!</item>).)*?shortVersionString=\"" + re.escape(args.version) + r"\"(?:(?!</item>).)*?</item>\n",
        re.DOTALL,
    )
    if existing.search(text):
        text = existing.sub(item, text, count=1)
    else:
        marker = "    <item>"
        index = text.find(marker)
        if index == -1:
            print("appcast.xml has no <item> to anchor on", file=sys.stderr)
            return 1
        text = text[:index] + item + text[index:]
    appcast_path.write_text(text)

    (SITE / "checksum.txt").write_text(
        f"{args.sha256}  Browsemium-{args.version}.dmg\n"
    )
    print(f"appcast and checksum updated for {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
