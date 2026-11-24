#!/usr/bin/env python3
"""Verify that Photo Export's development control plane is absent from Release."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

MARKERS = (
    b"-PEFixture", b"-PERunDirectory", b"-PESnapshot", b"photo-export-control-",
    b"ControlMailbox", b"ControlRuntime", b"FixturePhotoLibraryService",
)


def found_markers(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    folder = app / "Contents/MacOS"
    binary = folder / executable
    debug_dylib = folder / (executable + ".debug.dylib")
    found = set()
    for image in (binary, debug_dylib) if debug_dylib.exists() else (binary,):
        for tool in (("/usr/bin/strings", "-a"), ("/usr/bin/nm", "-a")):
            result = subprocess.run([*tool, image], check=True, capture_output=True)
            found.update(marker for marker in MARKERS if marker in result.stdout)
    return found


def built_app(configuration):
    settings = subprocess.run(
        ["xcodebuild", "-project", "photo-export.xcodeproj", "-scheme", "photo-export",
         "-configuration", configuration, "-destination", "platform=macOS", "-showBuildSettings", "-json"],
        check=True, capture_output=True, text=True).stdout
    values = next((entry["buildSettings"] for entry in json.loads(settings)
                   if entry.get("target") == "photo-export"), {})
    return Path(values["TARGET_BUILD_DIR"]) / values["FULL_PRODUCT_NAME"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--self-test", action="store_true", help="require the markers in Debug")
    args = parser.parse_args()
    try:
        found = found_markers(args.app or built_app(args.configuration))
    except (OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"Could not inspect app executable: {error}", file=sys.stderr)
        return 1
    unexpected = set(MARKERS) - found if args.self_test else found
    if unexpected:
        message = "Missing Debug markers" if args.self_test else "Unexpected Release markers"
        print(f"{message}: {', '.join(marker.decode() for marker in sorted(unexpected))}",
              file=sys.stderr)
        return 1
    print("Control exclusion Debug self-test passed." if args.self_test
          else "Release control exclusion passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
