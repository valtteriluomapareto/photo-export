#!/usr/bin/env python3
"""Reject representative PhotoKit mutation identifiers in production sources."""

import argparse
import pathlib
import re
import sys

sys.dont_write_bytecode = True
from swift_source import code_only


FORBIDDEN = re.compile(
    r"\b(?:PHAssetChangeRequest|PHAssetCreationRequest|PHAssetCollectionChangeRequest|"
    r"PHCollectionListChangeRequest|performChanges|performChangesAndWait)\b"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source_root", nargs="?", type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2] / "photo-export",
    )
    args = parser.parse_args()
    try:
        if not args.source_root.is_dir():
            raise ValueError(f"missing production source directory: {args.source_root}")
        sources = sorted(args.source_root.rglob("*.swift"))
        if not sources:
            raise ValueError(f"no Swift sources under {args.source_root}")
        violations = []
        for path in sources:
            code = code_only(path.read_text())
            for match in FORBIDDEN.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                violations.append(f"{path}:{line}: forbidden PhotoKit mutation identifier: {match[0]}")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Photos guard input error: {error}", file=sys.stderr)
        return 2
    if violations:
        print("\n".join(violations), file=sys.stderr)
        return 1
    print(f"Read-only Photos guard passed ({len(sources)} Swift files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
