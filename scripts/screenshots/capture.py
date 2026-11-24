#!/usr/bin/env python3
"""Capture the Mac App Store screenshot set from screenshot mode.

Builds Release under its own bundle id, then for each surface clears that bundle id's
preferences and app data, launches the app with `--screenshot-mode` on the curated
synthetic library, waits until the window's pixels stop changing, captures the window
and pads it to 2880x1800 with no alpha. The installed app's settings and data are never
read or written, even while it is running.

Usage:
  scripts/screenshots/capture.py                      # the five store surfaces
  scripts/screenshots/capture.py timeline collections-favorites

Output: screenshots/app-store/NN-<surface>.png (gitignored).

Needs a 2x (Retina) display with room for a 1360x850-point window, Pillow
(`python3 -m pip install Pillow`) and Screen Recording permission for the terminal
(System Settings > Privacy & Security > Screen Recording).
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUNDLE_ID = "com.valtteriluoma.photo-export.screenshots"
DERIVED = REPO / "build/screenshots"
APP = DERIVED / "Build/Products/Release/Photo Export.app"
EXECUTABLE = APP / "Contents/MacOS/Photo Export"
OUTPUT = REPO / "screenshots/app-store"
PAD_SCRIPT = REPO / "scripts/prepare-app-store-screenshot.py"

STORE_SURFACES = [
    "timeline",
    "timeline-multi-select",
    "collections-album-family",
    "collections-folder-trips",
    "collections-favorites",
]
OTHER_SURFACES = [
    "collections-album-porvoo",
    "collections-album-london",
    "collections-multi-select",
    "collections-shared-album-family-stream",
]
WINDOW_POINTS = (1360, 850)
RAW_PIXELS = (WINDOW_POINTS[0] * 2, WINDOW_POINTS[1] * 2)
STORE_SIZE = "2880x1800"
BACKGROUND = "E5E5EA"
SURFACE_TIMEOUT = 30.0
POLL_INTERVAL = 0.5


class Failure(Exception):
    pass


def run(arguments: list[str], **options) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, check=True, text=True, **options)


def require_pillow() -> None:
    if importlib.util.find_spec("PIL") is None:
        raise Failure("Pillow is not installed. Run: python3 -m pip install Pillow")


def build() -> None:
    DERIVED.mkdir(parents=True, exist_ok=True)
    log = DERIVED / "build.log"
    print(f"==> Building Release as {BUNDLE_ID} (log: {log})")
    with log.open("w") as handle:
        try:
            run(["xcodebuild", "-project", str(REPO / "photo-export.xcodeproj"),
                 "-scheme", "photo-export", "-configuration", "Release",
                 "-destination", "platform=macOS", "-derivedDataPath", str(DERIVED),
                 f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_ID}", "CODE_SIGNING_ALLOWED=NO", "build"],
                stdout=handle, stderr=subprocess.STDOUT)
        except subprocess.CalledProcessError as error:
            raise Failure(f"Release build failed; see {log}") from error


def quit_app() -> None:
    subprocess.run(["pkill", "-f", str(EXECUTABLE)], check=False)
    for _ in range(20):
        if subprocess.run(["pgrep", "-f", str(EXECUTABLE)], check=False,
                          stdout=subprocess.DEVNULL).returncode != 0:
            return
        time.sleep(0.25)
    raise Failure("An earlier capture instance did not quit")


def reset_domain() -> None:
    """Start every launch from empty preferences, app data and saved window state."""
    subprocess.run(["defaults", "delete", BUNDLE_ID], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    library = Path.home() / "Library"
    for path in (library / "Application Support" / BUNDLE_ID,
                 library / "Saved Application State" / f"{BUNDLE_ID}.savedState"):
        shutil.rmtree(path, ignore_errors=True)


def image_size(path: Path) -> tuple[int, int]:
    output = run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                 capture_output=True).stdout
    values = dict(line.split(":", 1) for line in output.splitlines()[1:] if ":" in line)
    return int(values["pixelWidth"]), int(values["pixelHeight"])


def has_alpha(path: Path) -> bool:
    output = run(["sips", "-g", "hasAlpha", str(path)], capture_output=True).stdout
    return "hasAlpha: yes" in output


def same_pixels(first: Path, second: Path) -> bool:
    from PIL import Image, ImageChops

    with Image.open(first) as a, Image.open(second) as b:
        return ImageChops.difference(a.convert("RGBA"), b.convert("RGBA")).getbbox() is None


def wait_for_window(window_file: Path, key: str, deadline: float, sleep, monotonic) -> int:
    while monotonic() < deadline:
        if window_file.exists():
            record = json.loads(window_file.read_text())
            if record.get("surface") != key:
                raise Failure(f"[{key}] the app opened surface {record.get('surface')!r} instead")
            return int(record["window"])
        sleep(POLL_INTERVAL)
    raise Failure(f"[{key}] the app did not report its window within {SURFACE_TIMEOUT:.0f} s")


def capture_surface(key: str, destination: Path, *, sleep=time.sleep,
                    monotonic=time.monotonic) -> None:
    """Launch on `key` and save the first capture whose pixels match the one before it."""
    quit_app()
    reset_domain()
    with tempfile.TemporaryDirectory(prefix="photo-export-capture-") as temporary:
        folder = Path(temporary)
        window_file = folder / "window.json"
        deadline = monotonic() + SURFACE_TIMEOUT
        print(f"==> [{key}] launching")
        run(["open", "-n", str(APP), "--args", "--screenshot-mode",
             f"--screenshot-width={WINDOW_POINTS[0]}", f"--screenshot-height={WINDOW_POINTS[1]}",
             f"--screenshot-surface={key}", f"--screenshot-window-file={window_file}"])
        window = wait_for_window(window_file, key, deadline, sleep, monotonic)
        previous = None
        attempt = 0
        while monotonic() < deadline:
            attempt += 1
            shot = folder / f"shot-{attempt}.png"
            run(["screencapture", "-x", "-o", "-t", "png", f"-l{window}", str(shot)])
            size = image_size(shot)
            if size != RAW_PIXELS:
                raise Failure(
                    f"[{key}] captured {size[0]}x{size[1]} pixels, expected "
                    f"{RAW_PIXELS[0]}x{RAW_PIXELS[1]}. This needs a 2x display with room for a "
                    f"{WINDOW_POINTS[0]}x{WINDOW_POINTS[1]}-point window, and Screen Recording "
                    "permission for this terminal.")
            if previous is not None and same_pixels(previous, shot):
                shutil.move(shot, destination)
                print(f"==> [{key}] stable after {attempt} captures")
                return
            previous = shot
            sleep(POLL_INTERVAL)
    raise Failure(f"[{key}] the window was still changing after {SURFACE_TIMEOUT:.0f} s")


def pad(raw: Path, output: Path) -> None:
    run([sys.executable, str(PAD_SCRIPT), str(raw), "-o", str(output),
         "--size", STORE_SIZE, "--background", BACKGROUND], stdout=subprocess.DEVNULL)
    width, height = (int(value) for value in STORE_SIZE.split("x"))
    if image_size(output) != (width, height) or has_alpha(output):
        raise Failure(f"{output.name} is not a {STORE_SIZE} image without alpha")


def surfaces_from(arguments: list[str]) -> list[str]:
    known = STORE_SURFACES + OTHER_SURFACES
    unknown = [key for key in arguments if key not in known]
    if unknown:
        raise SystemExit(f"Unknown surface: {', '.join(unknown)}\nKnown surfaces:\n  "
                         + "\n  ".join(known))
    return arguments or STORE_SURFACES


def main(arguments: list[str]) -> int:
    keys = surfaces_from(arguments)
    try:
        require_pillow()
        build()
        shutil.rmtree(OUTPUT, ignore_errors=True)
        OUTPUT.mkdir(parents=True)
        try:
            for number, key in enumerate(keys, start=1):
                raw = OUTPUT / f".raw-{key}.png"
                capture_surface(key, raw)
                pad(raw, OUTPUT / f"{number:02d}-{key}.png")
                raw.unlink()
        finally:
            quit_app()
    except Failure as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"\nDone. {len(keys)} screenshot(s) in {OUTPUT.relative_to(REPO)}:")
    for path in sorted(OUTPUT.glob("*.png")):
        print(f"  {path.name}")
    return 0


if __name__ == "__main__":
    os.chdir(REPO)
    raise SystemExit(main(sys.argv[1:]))
