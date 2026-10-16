#!/usr/bin/env python3
"""Publish advisory measured Swift app-source coverage from an xccov JSON report."""

import argparse
from fractions import Fraction
import html
import json
import os
from pathlib import Path
import subprocess
import sys

APP_TARGET = "Photo Export.app"
AREAS = ("App", "AutoSync", "Destination", "Export", "Helpers", "Models", "Other",
         "PhotoLibrary", "Protocols", "Records", "ViewModels", "Views")
TITLE = "## Measured app-source coverage (advisory)\n\n"


def escaped(value):
    return html.escape(str(value)).replace("|", "&#124;").replace("\n", " ").replace("\r", " ")


def percentage(covered, executable):
    return f"{100 * covered / executable:.1f}%" if executable else "n/a"


def outcome_note(test_outcome):
    if test_outcome == "success":
        return "Test outcome: success.\n\n"
    return f"Partial results: test outcome = {escaped(test_outcome)}. Counts may be incomplete.\n\n"


def render_report(report, source_root, target=APP_TARGET, test_outcome="success"):
    if not isinstance(report, dict) or not isinstance(report.get("targets"), list):
        raise ValueError("report has no target list")
    matches = [item for item in report["targets"] if isinstance(item, dict) and item.get("name") == target]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {target} target, found {len(matches)}")
    files = matches[0].get("files")
    if not isinstance(files, list):
        raise ValueError("app target has no file list")
    root = Path(source_root).resolve()
    totals = {area: [0, 0] for area in AREAS}
    seen = set()
    measured = []
    for file in files:
        if not isinstance(file, dict) or not isinstance(file.get("path"), str):
            raise ValueError("app coverage file has no path")
        path = Path(file["path"])
        if not path.is_absolute():
            raise ValueError("coverage file paths must be absolute")
        path = path.resolve()
        if not path.is_relative_to(root) or path.suffix != ".swift":
            continue
        relative = path.relative_to(root)
        if path in seen:
            raise ValueError(f"duplicate normalized source: {relative}")
        seen.add(path)
        covered, executable = file.get("coveredLines"), file.get("executableLines")
        if type(covered) is not int or type(executable) is not int or not 0 <= covered <= executable:
            raise ValueError(f"invalid covered/executable line counts: {relative}")
        area = relative.parts[0] if relative.parts[0] in totals else "Other"
        totals[area][0] += covered
        totals[area][1] += executable
        measured.append((relative.as_posix(), covered, executable))
    if not measured:
        raise ValueError("no eligible Swift application source files")
    lines = [TITLE + outcome_note(test_outcome),
             f"Target: <code>{escaped(target)}</code>; {len(measured)} measured Swift source files.\n",
             "Only files reported by xccov inside the app source root are counted; unlisted files are not inferred as 0%.\n",
             "| Area | Covered | Executable | Coverage |", "| --- | ---: | ---: | ---: |"]
    for area, (covered, executable) in totals.items():
        lines.append(f"| {area} | {covered} | {executable} | {percentage(covered, executable)} |")
    covered = sum(value[0] for value in totals.values())
    executable = sum(value[1] for value in totals.values())
    lines.append(f"| Total | {covered} | {executable} | {percentage(covered, executable)} |")
    lowest = sorted((file for file in measured if file[2]), key=lambda file: (Fraction(file[1], file[2]), file[0]))[:10]
    if lowest:
        lines.extend(["", "Lowest measured file coverage (up to 10):", "",
                      "| File | Covered / executable | Coverage |", "| --- | ---: | ---: |"])
        for path, covered, executable in lowest:
            lines.append(f"| <code>{escaped(path)}</code> | {covered} / {executable} | {percentage(covered, executable)} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--result-bundle", type=Path)
    inputs.add_argument("--report-json", type=Path)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--target", default=APP_TARGET)
    parser.add_argument("--test-outcome", default="unknown")
    parser.add_argument("--summary-file", type=Path, default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args()
    try:
        if args.report_json:
            report = json.loads(args.report_json.read_text())
        else:
            if not args.result_bundle.is_dir():
                raise ValueError("result bundle missing; coverage was not collected")
            result = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", str(args.result_bundle)],
                                    check=True, capture_output=True, text=True, timeout=60)
            report = json.loads(result.stdout)
        markdown = render_report(report, args.source_root, args.target, args.test_outcome)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        markdown = TITLE + outcome_note(args.test_outcome) + f"Coverage unavailable: {escaped(error)}\n"
    # The log remains useful even if the step-summary destination cannot be written.
    print(markdown, end="")
    if args.summary_file:
        try:
            with args.summary_file.open("a") as summary:
                summary.write(markdown)
        except OSError as error:
            print(f"Could not append coverage summary: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
