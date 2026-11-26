#!/usr/bin/env python3
"""Frame a window capture for the Mac App Store: gradient background, headline, shadow.

Usage:
  scripts/screenshots/frame.py raw.png out.png "Every photo, backed up by month"

The input is a `screencapture -o -l<window>` capture with transparent corners. The output
is a 2880x1800 PNG without alpha: the app icon's blue-to-lavender gradient, the headline
in SF Pro Semibold (built into macOS) and the window scaled below it with a soft shadow.

Requires Pillow (`python3 -m pip install Pillow`).
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

CANVAS = (2880, 1800)
GRADIENT = ((0xB9, 0xD4, 0xF8), (0xE2, 0xD3, 0xF6))
HEADLINE_COLOR = (0x1D, 0x2B, 0x4F)
FONT = Path("/System/Library/Fonts/SFNS.ttf")
FONT_SIZE = 92
HEADLINE_CENTER_Y = 170
WINDOW_TOP = 330
BOTTOM_MARGIN = 70
SHADOW_BLUR = 36
SHADOW_OFFSET = 18
SHADOW_OPACITY = 0.30


def gradient() -> Image.Image:
    top, bottom = GRADIENT
    column = Image.new("RGB", (1, CANVAS[1]))
    for y in range(CANVAS[1]):
        t = y / (CANVAS[1] - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize(CANVAS)


def headline_font() -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(str(FONT), FONT_SIZE)
    font.set_variation_by_name("Semibold")
    return font


def frame(raw: Path, output: Path, headline: str) -> None:
    canvas = gradient()
    draw = ImageDraw.Draw(canvas)
    draw.text((CANVAS[0] // 2, HEADLINE_CENTER_Y), headline, font=headline_font(),
              fill=HEADLINE_COLOR, anchor="mm")

    window = Image.open(raw).convert("RGBA")
    height = CANVAS[1] - WINDOW_TOP - BOTTOM_MARGIN
    width = round(window.width * height / window.height)
    window = window.resize((width, height), Image.LANCZOS)
    left = (CANVAS[0] - width) // 2

    alpha = window.getchannel("A").point(lambda value: round(value * SHADOW_OPACITY))
    shadow = Image.new("L", CANVAS, 0)
    shadow.paste(alpha, (left, WINDOW_TOP + SHADOW_OFFSET))
    shadow = shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    canvas.paste((0, 0, 0), mask=shadow)
    canvas.paste(window, (left, WINDOW_TOP), mask=window)

    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG", optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    frame(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
