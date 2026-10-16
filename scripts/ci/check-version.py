#!/usr/bin/env python3
"""Validate every project MARKETING_VERSION, optionally against a release tag."""

import argparse
import pathlib
import re
import sys


# Keep this syntax aligned with scripts/bump-version.sh, including its existing
# prerelease suffix rules; do not silently impose stricter SemVer semantics.
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?")
ASSIGNMENT = re.compile(r"\s*MARKETING_VERSION\s*=\s*([^;]*);\s*(?://[^\n]*)?")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "project", nargs="?", type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2] / "photo-export.xcodeproj/project.pbxproj",
    )
    parser.add_argument("--expected", help="Expected full version, only supplied for actual tag events")
    args = parser.parse_args()
    try:
        versions = []
        for number, line in enumerate(args.project.read_text().splitlines(), 1):
            if not re.match(r"\s*MARKETING_VERSION\b", line):
                continue
            assignment = ASSIGNMENT.fullmatch(line)
            if assignment is None:
                raise ValueError(f"{args.project}:{number}: malformed MARKETING_VERSION assignment")
            version = assignment[1].strip()
            if VERSION.fullmatch(version) is None:
                raise ValueError(f"{args.project}:{number}: invalid MARKETING_VERSION {version!r}")
            versions.append(version)
        if not versions:
            raise ValueError(f"{args.project}: no MARKETING_VERSION assignments")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Version guard input error: {error}", file=sys.stderr)
        return 2
    if len(set(versions)) != 1:
        print(f"MARKETING_VERSION differs across configurations: {', '.join(versions)}", file=sys.stderr)
        return 1
    version = versions[0]
    if args.expected is not None and args.expected != version:
        print(f"Version mismatch: expected {args.expected} but project is {version}", file=sys.stderr)
        return 1
    print(f"Version guard passed: {version} ({len(versions)} assignments)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
