#!/usr/bin/env bash
# Usage: throughput-from-log.sh [--verbose] [run.log ...]
# Pass one file per export run; with no files, stdin is one run. Capture only that
# run's Exported lines, for example with log show --style compact --info and a
# predicate for subsystem com.valtteriluoma.photo-export / category VariantExporter.
# Use --start/--end to isolate the run. This requires the explicit asset identifiers
# emitted by current builds; each asset counts once even if several variants commit.
# The denominator is the first-to-last completion window, not total elapsed run time:
# preparation and the first asset's download/write precede this window. Use the same
# capture method and export selection when comparing runs. Two distinct timestamps
# are required. Multiple files print each rate and the median across those runs.
set -euo pipefail
python3 /dev/fd/3 "$@" 3<<'PY'
import argparse
import datetime
import pathlib
import re
import statistics
import sys

parser = argparse.ArgumentParser(
    description="Measure distinct assets/sec in each first-to-last completion window.",
    epilog="Pass one file per export run; stdin is one run when no files are supplied.",
)
parser.add_argument("--verbose", "-v", action="store_true")
parser.add_argument("logs", nargs="*", help="one captured export run per file")
args = parser.parse_args()

completion = re.compile(r"\bExported .+ variant: \S+ -> .+")
timestamp = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))")
asset = re.compile(r" asset: (.+)$")


def measure(label, lines):
    stamps, identifiers = [], set()
    ignored = 0
    for number, line in enumerate(lines, 1):
        if not completion.search(line):
            ignored += 1
            continue
        prefix = f"{label}:{number}"
        match = timestamp.match(line)
        if not match:
            raise ValueError(f"{prefix}: invalid completion timestamp (include date and timezone)")
        try:
            stamp = datetime.datetime.fromisoformat(match[1].replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError(f"{prefix}: invalid completion timestamp") from error
        identity = asset.search(line.rstrip())
        if not identity or not identity[1].strip():
            raise ValueError(f"{prefix}: missing asset identifier; capture a current app build")
        if identity[1] == "<private>":
            raise ValueError(f"{prefix}: private asset identifier; use the app's public completion log")
        stamps.append(stamp)
        identifiers.add(identity[1])
    if not stamps:
        raise ValueError(f"{label}: no Exported completion lines")
    duration = (max(stamps) - min(stamps)).total_seconds()
    if duration <= 0:
        raise ValueError(f"{label}: at least two distinct completion timestamps are required")
    rate = len(identifiers) / duration
    result = f"run={label} assets={len(identifiers)} seconds={duration:.6f} assets/sec={rate:.6f}"
    if args.verbose:
        result += (
            f" window=first-to-last-completion variant-completions={len(stamps)}"
            f" ignored-lines={ignored} first={min(stamps).isoformat()} last={max(stamps).isoformat()}"
        )
    return result, rate


try:
    results = []
    if args.logs:
        for name in args.logs:
            with pathlib.Path(name).open() as stream:
                results.append(measure(name, stream))
    else:
        results.append(measure("stdin", sys.stdin))
except (OSError, ValueError) as error:
    parser.exit(1, f"throughput-from-log: {error}\n")

for result, _ in results:
    print(result)
print(f"median assets/sec={statistics.median(rate for _, rate in results):.6f} runs={len(results)}")
PY
