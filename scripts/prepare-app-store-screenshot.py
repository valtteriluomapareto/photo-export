#!/usr/bin/env python3
"""Pad a screenshot to a Mac App Store spec size and flatten transparency.

The Mac App Store requires screenshots in exact sizes:
  1280×800, 1440×900, 2560×1600, 2880×1800

Re-shot screenshots often come out with transparent borders (e.g. macOS
window-only captures) and at near-but-not-spec dimensions. This script:

  - picks the smallest spec the input fits into,
  - centers the image on a solid-colour canvas at that spec,
  - flattens any alpha channel against that colour,
  - writes a PNG with no transparency.

Usage:
  scripts/prepare-app-store-screenshot.py design/app-store-screenshot.png
  scripts/prepare-app-store-screenshot.py raw.png -o out.png --background FFFFFF

Requires Pillow:  python3 -m pip install Pillow
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.stderr.write(
        "error: Pillow not installed. Run: python3 -m pip install Pillow\n"
    )
    sys.exit(2)

# Mac App Store screenshot specs, ascending — we pick the smallest one that fits.
SPECS: list[tuple[int, int]] = [
    (1280, 800),
    (1440, 900),
    (2560, 1600),
    (2880, 1800),
]


def pick_spec(width: int, height: int) -> tuple[int, int]:
    for spec_w, spec_h in SPECS:
        if width <= spec_w and height <= spec_h:
            return spec_w, spec_h
    raise SystemExit(
        f"error: input {width}x{height} exceeds the largest App Store spec "
        f"{SPECS[-1]}. Re-shoot the screenshot smaller or pre-resize it."
    )


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    s = value.lstrip("#")
    if len(s) != 6 or not all(c in "0123456789abcdefABCDEF" for c in s):
        raise SystemExit(
            f"error: --background must be a 6-digit hex colour, got {value!r}"
        )
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("input", type=Path, help="Source PNG (may have alpha)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Destination PNG. Defaults to overwriting the input.",
    )
    parser.add_argument(
        "-b",
        "--background",
        default="FFFFFF",
        help=(
            "Hex RGB used to fill transparent pixels and padding "
            "(default: FFFFFF). Use 000000 for black, 1E1E1E for macOS dark "
            "window chrome."
        ),
    )
    args = parser.parse_args()

    if not args.input.is_file():
        raise SystemExit(f"error: input file not found: {args.input}")

    output = args.output or args.input
    bg = hex_to_rgb(args.background)

    img = Image.open(args.input).convert("RGBA")
    width, height = img.size
    spec_w, spec_h = pick_spec(width, height)

    canvas = Image.new("RGB", (spec_w, spec_h), bg)
    offset = ((spec_w - width) // 2, (spec_h - height) // 2)
    canvas.paste(img, offset, mask=img)

    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG", optimize=True)
    print(
        f"Wrote {spec_w}x{spec_h} (input was {width}x{height}, "
        f"background #{args.background.lstrip('#').upper()}) -> {output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
