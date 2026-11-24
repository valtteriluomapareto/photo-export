#!/usr/bin/env python3
"""Run the Debug fixture's month export and no-op re-export through its CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys

DRIVER = Path(__file__).with_name("pe_control.py")
MONTH_ACTION = '{"action":"export.month","year":2025,"month":6}'
EXPECTED_FILES = {"Harbor.png", "Pines.png"}
PNG_HEADER = b"\x89PNG\r\n\x1a\n"


class SmokeError(Exception):
    pass


def inventory(month):
    paths = list(month.iterdir())
    if {path.name for path in paths} != EXPECTED_FILES:
        raise SmokeError(f"Unexpected export files: {sorted(path.name for path in paths)}")
    result = {}
    for path in paths:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise SmokeError(f"Expected a regular file: {path.name}")
        content = path.read_bytes()
        if not content.startswith(PNG_HEADER):
            raise SmokeError(f"Invalid export PNG: {path.name}")
        result[path.name] = (
            metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_ctime_ns,
            hashlib.sha256(content).hexdigest(),
        )
    return result


def preserve_state(run, evidence):
    for name in ("state.json", "res-1.json", "res-2.json"):
        source = run / name
        try:
            if not source.is_symlink() and source.is_file():
                shutil.copyfile(source, evidence / name)
        except OSError as error:
            print(f"Could not save {name}: {error}", file=sys.stderr)


def verify(driver, app, evidence):
    run = Path(driver("launch", "--app", str(app), "--timeout", "15",
                      "--app-log", str(evidence / "app.log")).strip())
    try:
        month = run / "Destination" / "2025" / "06"
        original = None
        for seq in (1, 2):
            reply = json.loads(driver("action", str(run), MONTH_ACTION, "--timeout", "15"))
            if reply.get("seq") != seq or reply.get("status") != "accepted":
                raise SmokeError(f"Export {seq} was not accepted: {reply}")
            jobs = "export.completed=2" if seq == 1 else "export.enqueued=0"
            driver("wait", str(run), f"settledSeq={seq}", "idle=true",
                   "records.exportedByMonth.2025-06=2", jobs, "--timeout", "15")
            files = inventory(month)
            if seq == 1:
                original = files
            elif files != original:
                raise SmokeError("The repeat export changed the existing files.")
    finally:
        failing = sys.exc_info()[0] is not None
        try:
            driver("stop", str(run))
        except (OSError, SmokeError, subprocess.SubprocessError) as error:
            preserve_state(run, evidence)
            if not failing:
                raise
            print(f"Could not stop the fixture: {error}", file=sys.stderr)
        else:
            if failing:
                preserve_state(run, evidence)


def run_driver(transcript, *args):
    command = [sys.executable, "-B", str(DRIVER), *args]
    print(shlex.join(command), file=transcript, flush=True)
    # Launch may spend 15 seconds in each of its two waits, then clean up its child.
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=40 if args[0] == "launch" else 20)
    except subprocess.TimeoutExpired as error:
        for output in (error.stdout, error.stderr):
            if output:
                transcript.write(output.decode(errors="replace"))
        raise
    transcript.write(result.stdout)
    transcript.write(result.stderr)
    transcript.flush()
    if result.returncode:
        raise SmokeError(result.stderr.strip() or f"{args[0]} exited {result.returncode}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    try:
        args.evidence.mkdir(parents=True, exist_ok=True)
        with (args.evidence / "transcript.log").open("x") as transcript:
            try:
                verify(lambda *arguments: run_driver(transcript, *arguments),
                       args.app, args.evidence)
            except (OSError, ValueError, SmokeError, subprocess.SubprocessError) as error:
                print(str(error), file=transcript)
                raise
    except (OSError, ValueError, SmokeError, subprocess.SubprocessError) as error:
        print(f"Control smoke failed: {error}", file=sys.stderr)
        return 1
    print("Control smoke passed: two committed exports, zero jobs on repeat.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
