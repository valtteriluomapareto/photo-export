#!/usr/bin/env python3
"""Best-effort current-run evidence collection; never replace the unit-test result."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


def collect(marker, bundle, reports, output):
    output.mkdir(parents=True, exist_ok=True)
    result = {"selected": 0, "copied": [], "errors": [], "export_exit": None}

    def finish():
        (output / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
        return result

    try:
        if marker.is_symlink() or not marker.is_file():
            raise OSError("missing or non-regular unit-start marker")
        started = marker.stat().st_mtime
    except OSError as error:
        result["errors"].append(f"Invalid unit-start marker: {error}; no diagnostics collected")
        return finish()

    if bundle.is_dir() and not bundle.is_symlink():
        try:
            export = subprocess.run([
                "xcrun", "xcresulttool", "export", "diagnostics", "--path", str(bundle),
                "--output-path", str(output / "xcresult")
            ], capture_output=True, text=True, errors="replace", timeout=45)
            (output / "export.log").write_text(export.stdout + export.stderr)
            result["export_exit"] = export.returncode
            if export.returncode:
                result["errors"].append(f"xcresult export exited {export.returncode}; see export.log")
        except (OSError, subprocess.TimeoutExpired) as error:
            result["errors"].append(f"xcresult export failed: {error}")
            (output / "export.log").write_text(str(error) + "\n")
    else:
        result["errors"].append("Missing or non-regular result bundle; export not attempted")

    # Independent from xcresult export: Xcode's bundle may omit the OS crash report.
    try:
        candidates = sorted(reports.iterdir())
    except OSError as error:
        result["errors"].append(f"Cannot read report directory: {error}")
        candidates = []
    for source in candidates:
        if not re.fullmatch(r"Photo Export-\d{4}-\d{2}-\d{2}-.+\.(ips|crash)", source.name):
            continue
        stage = None
        try:
            if source.is_symlink() or not source.is_file() or source.stat().st_mtime < started:
                continue
            result["selected"] += 1
            destination = output / "crashes" / source.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            stage = destination.with_name(destination.name + ".partial")
            shutil.copy2(source, stage)
            stage.replace(destination)
            result["copied"].append(source.name)
        except OSError as error:
            result["errors"].append(f"Cannot copy {source.name}: {error}")
        finally:
            if stage is not None:
                try:
                    stage.unlink(missing_ok=True)
                except OSError as error:
                    result["errors"].append(f"Cannot remove partial copy {stage.name}: {error}")
    return finish()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--since", type=Path, required=True)
    parser.add_argument("--result-bundle", type=Path, required=True)
    parser.add_argument("--crash-reports", type=Path, default=Path.home() / "Library/Logs/DiagnosticReports")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = collect(args.since, args.result_bundle, args.crash_reports, args.output)
    print(json.dumps(result))
    if not result["copied"]:
        print("No current-run Photo Export crash reports were retained; see manifest.json.")


if __name__ == "__main__":
    main()
