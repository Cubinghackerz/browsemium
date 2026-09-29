#!/usr/bin/env python3
"""Generate brand bitmaps from Brand/logo.svg using only the standard library.

Run at the repository root. sips downsizes the 1024 px icon master; iconutil
packs the same icon grid into the DMG volume icon when available.
"""

from __future__ import annotations

import math
import shutil
import struct
import subprocess
import xml.etree.ElementTree as ET
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "Brand"
SITE = ROOT / "Site"
ICONS = ROOT / "BrowsemiumApp/Assets.xcassets/AppIcon.appiconset"
LOGO_ASSET = ROOT / "Packages/BrowsemiumKit/Sources/BrowsemiumUI/Resources/Assets.xcassets/Logo.imageset"
POLYGONS = [
    [(float(x), float(y)) for x, y in (pair.split(",") for pair in item.attrib["points"].split())]
    for item in ET.parse(BRAND / "logo.svg").getroot()
    if item.tag.endswith("polygon")
]
if len(POLYGONS) != 2:
    raise SystemExit("Brand/logo.svg must contain the two mark polygons")


def inside_triangle(x: float, y: float, points: list[tuple[float, float]]) -> bool:
    (ax, ay), (bx, by), (cx, cy) = points
    d1 = (x - bx) * (ay - by) - (ax - bx) * (y - by)
    d2 = (x - cx) * (by - cy) - (bx - cx) * (y - cy)
    d3 = (x - ax) * (cy - ay) - (cx - ax) * (y - ay)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


def mark_coverage(x: float, y: float, scale: float, ox: float, oy: float) -> float:
    total = 0
    for sx, sy in ((.25, .25), (.75, .25), (.25, .75), (.75, .75)):
        px, py = (x + sx - ox) / scale, (y + sy - oy) / scale
        total += any(inside_triangle(px, py, polygon) for polygon in POLYGONS)
    return total / 4


def rounded_distance(x: float, y: float, left: float, top: float, width: float, radius: float) -> float:
    cx, cy = left + width / 2, top + width / 2
    qx = abs(x - cx) - (width / 2 - radius)
    qy = abs(y - cy) - (width / 2 - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius


def png(width: int, height: int, pixels: bytes) -> bytes:
    def chunk(name: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name + payload))

    rows = b"".join(b"\0" + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def render_icon() -> bytes:
    width = 1024
    pixels = bytearray(width * width * 4)
    for y in range(width):
        for x in range(width):
            offset = (y * width + x) * 4
            shadow_distance = rounded_distance(x + .5, y + .5, 100, 115, 824, 188)
            shadow_alpha = int(32 * math.exp(-max(shadow_distance, 0) ** 2 / (2 * 22 ** 2))) if shadow_distance > 0 else 32
            plate = max(0, min(1, .5 - rounded_distance(x + .5, y + .5, 100, 100, 824, 188)))
            if plate:
                white = mark_coverage(x, y, .7, 154, 154) if 200 <= x <= 824 and 200 <= y <= 800 else 0
                shade = round(17 + 238 * white)
                pixels[offset:offset + 4] = bytes((shade, shade, shade, round(255 * plate)))
            elif shadow_alpha:
                pixels[offset:offset + 4] = bytes((0, 0, 0, shadow_alpha))
    return png(width, width, pixels)


def render_mark(size: int, *, white: bool = False) -> bytes:
    pixels = bytearray(size * size * 4)
    colour = 255 if white else 17
    for y in range(size):
        for x in range(size):
            alpha = round(255 * mark_coverage(x, y, size / 1024, 0, 0))
            pixels[(y * size + x) * 4:(y * size + x) * 4 + 4] = bytes((colour, colour, colour, alpha))
    return png(size, size, pixels)


def render_poster(width: int, height: int, *, light: bool = False) -> bytes:
    pixels = bytearray(width * height * 4)
    bg = (247, 247, 247) if light else (17, 17, 17)
    fg = 17 if light else 255
    scale = min(width, height) * .7 / 1024
    ox, oy = (width - scale * 1024) / 2, (height - scale * 1024) / 2
    for y in range(height):
        for x in range(width):
            alpha = mark_coverage(x, y, scale, ox, oy) if ox <= x <= ox + scale * 1024 and oy <= y <= oy + scale * 1024 else 0
            rgb = tuple(round(base + (fg - base) * alpha) for base in bg)
            pixels[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes((*rgb, 255))
    return png(width, height, pixels)


def write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    print(path.relative_to(ROOT))


def main() -> None:
    master = BRAND / "icon-master.png"
    write(master, render_icon())
    for name, size in (
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ):
        target = ICONS / name
        if size == 1024:
            shutil.copyfile(master, target)
        else:
            subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size), str(master), "--out", str(target)], check=True, stdout=subprocess.DEVNULL)
        print(target.relative_to(ROOT))

    shutil.copyfile(BRAND / "logo.svg", LOGO_ASSET / "logo.svg")
    polygons = "".join(f'<polygon points="{item.attrib["points"]}"/>' for item in ET.parse(BRAND / "logo.svg").getroot())
    light_icon = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><rect x="100" y="100" width="824" height="824" rx="188" fill="#f7f7f7"/><g fill="#111111" transform="translate(154 154) scale(.7)">{polygons}</g></svg>'''
    write(BRAND / "icon-light.svg", light_icon.encode())
    banner = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 320" role="img" aria-label="Browsemium"><rect width="1200" height="320" rx="26" fill="#111111"/><g fill="#fff" transform="translate(73 57) scale(.2)">{polygons}</g><text x="300" y="198" fill="#fff" font-family="Geist, Helvetica Neue, Arial, sans-serif" font-size="106" font-weight="600" letter-spacing="-3">Browsemium</text></svg>'''
    write(BRAND / "banner.svg", banner.encode())
    favicon = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><style>:root {{ color: #111 }} @media (prefers-color-scheme: dark) {{ :root {{ color: #fff }} }}</style><g fill="currentColor">{polygons}</g></svg>'''
    write(SITE / "favicon.svg", favicon.encode())
    images = [(16, render_mark(16)), (32, render_mark(32)), (48, render_mark(48))]
    payload_offset = 6 + len(images) * 16
    directory = bytearray(struct.pack("<HHH", 0, 1, len(images)))
    for size, data in images:
        directory += struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(data), payload_offset)
        payload_offset += len(data)
    write(SITE / "favicon.ico", bytes(directory) + b"".join(data for _, data in images))
    # Home-screen icons need an opaque plate; a transparent dark mark can
    # disappear against a dark wallpaper.
    write(SITE / "apple-touch-icon.png", render_poster(180, 180))
    write(SITE / "og.png", render_poster(1200, 630))
    write(BRAND / "dmg-background.png", render_poster(720, 480, light=True))
    iconset = BRAND / "Browsemium.iconset"
    iconset.mkdir(exist_ok=True)
    for icon in ICONS.glob("*.png"):
        shutil.copyfile(icon, iconset / icon.name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(BRAND / "Browsemium.icns")], check=True)
    print((BRAND / "Browsemium.icns").relative_to(ROOT))
    master.unlink()
    shutil.rmtree(iconset)


if __name__ == "__main__":
    main()
