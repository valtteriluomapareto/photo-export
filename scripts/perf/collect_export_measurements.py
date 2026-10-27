#!/usr/bin/env python3
"""Capture a supplied app's opt-in numeric export events, or replay a capture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import selectors
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

KINDS = {
    "ready": set(), "runBegin": {"automatic"}, "enqueued": {"count"},
    "jobBegin": {"job", "asset"}, "completion": {"job", "asset", "atNs"},
    "jobEnd": {"job", "asset", "wallNs", "stageNs", "stageValid"},
    "turn": {"durationNs"}, "invalidated": {"reason"},
    "runEnd": {"valid", "reason", "jobs", "enqueued", "completions", "wallNs"},
}
REASONS = {
    "complete", "paused", "pending-cleared", "cancelled", "superseded", "scan-failed",
    "variant-failed", "overlapping-jobs", "overlapping-stages", "clock-regressed",
    "invalid-stage-time", "job-still-active", "job-count-mismatch", "no-jobs",
}


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


class Capture:
    def __init__(self, session):
        self.session = session
        self.pid = None
        self.runs = {}
        self.sealed = {}
        self.errors = []

    def consume(self, raw):
        if not isinstance(raw, dict):
            self.errors.append("malformed log event")
            return None
        if raw.get("captureError") is True:
            self.errors.append("capture integrity failure")
            return None
        if raw.get("dropped") or raw.get("eventType") == "lossEvent":
            self.errors.append("log messages were dropped")
            return None
        if "eventMessage" in raw:
            message = raw["eventMessage"]
            if not isinstance(message, str) or not message.startswith("MEASURE "):
                return None
            try:
                event = json.loads(message[len("MEASURE "):])
            except ValueError:
                self.errors.append("malformed measurement JSON")
                return None
            pid = raw.get("processID")
        else:
            event, pid = raw, raw.get("pid")
        if not isinstance(event, dict) or event.get("session") != self.session:
            return None
        if self.pid is not None and pid != self.pid:
            return None
        kind = event.get("type")
        if event.get("schema") != 1 or kind not in KINDS or not integer(pid, 1):
            self.errors.append("unsupported or malformed measurement event")
            return None
        if kind == "ready":
            if self.pid is None:
                self.pid = pid
            return {"schema": 1, "session": self.session, "type": kind, "pid": pid}
        if self.pid is None:
            self.errors.append("capture missed the app readiness event")
            return None
        try:
            uuid.UUID(event.get("run", ""))
        except (ValueError, TypeError, AttributeError):
            self.errors.append("measurement has no valid run identity")
            return None
        if not integer(event.get("seq"), 1):
            self.errors.append("measurement has no valid sequence")
            return None
        clean = {key: event[key] for key in KINDS[kind] if key in event}
        if "reason" in clean and clean["reason"] not in REASONS:
            clean["reason"] = "invalid-stage-time"
            self.errors.append("unknown measurement status")
        for key in list(clean):
            if key == "reason":
                continue
            valid = type(clean[key]) is bool if key in {"valid", "stageValid", "automatic"} else integer(clean[key])
            if not valid:
                clean[key] = None
                if key not in {"stageNs", "stageValid"}:
                    self.errors.append("non-numeric measurement field")
        clean.update(schema=1, session=self.session, type=kind, pid=pid,
                     run=event["run"], seq=event["seq"])
        if clean["run"] in self.sealed:
            self.errors.append("events followed a sealed run")
        self.runs.setdefault(clean["run"], []).append(clean)
        if kind == "runEnd":
            self.sealed[clean["run"]] = summarize(self.runs[clean["run"]], bool(self.errors))
        return clean

    def summaries(self):
        return [summarize(rows, bool(self.errors)) for rows in self.runs.values()]

    def eligible_count(self):
        return 0 if self.errors else sum(row["eligible"] for row in self.sealed.values())


def summarize(rows, capture_error=False):
    issues = []
    sequence = [row["seq"] for row in rows]
    if sequence != list(range(1, len(rows) + 1)):
        issues.append("missing, duplicate or out-of-order numeric events")
    if not rows or rows[0]["type"] != "runBegin" or rows[-1]["type"] != "runEnd":
        issues.append("run is not sealed")
    if capture_error:
        issues.append("capture error")
    end = rows[-1] if rows else {}
    completions = [row for row in rows if row["type"] == "completion"]
    jobs = [row for row in rows if row["type"] == "jobEnd"]
    begins = [row for row in rows if row["type"] == "jobBegin"]
    enqueued = [row.get("count") for row in rows if row["type"] == "enqueued"]
    if not enqueued or not all(integer(count, 1) for count in enqueued):
        issues.append("invalid enqueued count")
        enqueued = []
    expected = sum(enqueued)
    ordinals = [row.get("job") for row in begins]
    finished = [row.get("job") for row in jobs]
    if (not expected or expected != len(begins)
            or ordinals != list(range(1, len(begins) + 1)) or finished != ordinals):
        issues.append("job count mismatch")
    assets_by_job = {row.get("job"): row.get("asset") for row in begins}
    if not all(integer(asset, 1) for asset in assets_by_job.values()):
        issues.append("invalid asset identity")
    if any(row.get("asset") != assets_by_job.get(row.get("job")) for row in jobs + completions):
        issues.append("asset ownership mismatch")
    if (end.get("jobs") != len(jobs) or end.get("enqueued") != expected
            or end.get("completions") != len(completions)):
        issues.append("terminal counts do not match captured evidence")
    if end.get("valid") is not True or any(row["type"] == "invalidated" for row in rows):
        issues.append("export was interrupted or failed")
    complete = not issues
    stamps = [row.get("atNs") for row in completions]
    if not stamps or not all(integer(stamp) for stamp in stamps):
        stamps = []
    assets = {row.get("asset") for row in completions}
    window = (max(stamps) - min(stamps)) / 1e9 if stamps else 0
    throughput_valid = complete and len(assets) > 0 and window > 0
    # This is the same distinct-asset / first-to-last-completion denominator as throughput-from-log.sh.
    rate = len(assets) / window if throughput_valid else None
    staging_valid = complete and all(
        row.get("stageValid") is True and integer(row.get("wallNs"))
        and integer(row.get("stageNs")) and row["stageNs"] <= row["wallNs"] for row in jobs)
    wall = sum(row["wallNs"] for row in jobs) if staging_valid else None
    stage = sum(row["stageNs"] for row in jobs) if staging_valid else None
    staging_valid = staging_valid and wall > 0
    fraction = stage / wall if staging_valid else None
    turns = [row.get("durationNs") for row in rows if row["type"] == "turn"]
    if not all(integer(turn, 16_000_001) for turn in turns):
        issues.append("invalid turn duration")
        turns = []
        throughput_valid = staging_valid = False
        rate = fraction = None
    return {
        "run": rows[0]["run"], "complete": complete, "issues": issues,
        "throughputValid": throughput_valid, "stagingValid": staging_valid,
        "automatic": rows[0].get("automatic", False),
        "eligible": throughput_valid and rows[0].get("automatic", False) is False,
        "assets": len(assets), "variantCompletions": len(completions),
        "completionWindowSeconds": window, "assetsPerSecond": rate,
        "logicalRunSeconds": end.get("wallNs", 0) / 1e9 if integer(end.get("wallNs")) else None,
        "jobWallSeconds": wall / 1e9 if wall is not None else None,
        "stagingSeconds": stage / 1e9 if stage is not None else None,
        "stagingFraction": fraction,
        "stagingMeets50Percent": fraction >= 0.5 if fraction is not None else None,
        "stalls": {"over16": len(turns), "over33": sum(t > 33_000_000 for t in turns),
                   "over100": sum(t > 100_000_000 for t in turns)},
        "longTurnsMilliseconds": [t / 1e6 for t in turns if t > 100_000_000],
    }


def save_report(output, capture, label, requested, metadata, partial=False):
    rows = capture.summaries()
    rates = [row["assetsPerSecond"] for row in rows if row["eligible"]]
    staged = [row for row in rows if row["eligible"] and row["stagingValid"]]
    weighted = (sum(row["stagingSeconds"] for row in staged) / sum(row["jobWallSeconds"] for row in staged)
                if staged and len(staged) == len(rates) else None)
    result = {"schema": 1, "label": label, "session": capture.session, "requestedRuns": requested,
              "eligibleRuns": len(rates), "partial": partial or len(rates) < requested,
              "medianAssetsPerSecond": statistics.median(rates) if rates else None,
              "stagingFraction": weighted, "stagingMeets50Percent": weighted >= 0.5 if weighted is not None else None,
              "captureErrors": capture.errors, "metadata": metadata, "runs": rows}
    (output / "results.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    clean_label = re.sub(r"[\r\n|]", " ", label)
    lines = [f"Export measurements: {clean_label}", "", f"Eligible runs: {len(rates)} / {requested}",
             "Throughput window: first-to-last-completion; distinct assets across variants/placements.",
             "Staging: sum of physical producer-await wall / sum of complete-job wall; not CPU time.",
             "Logical run wall includes preparation; job wall brackets performExport.", "",
             "| Run | Assets/s | Assets | Staging | >16 / >33 / >100 ms turns |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for n, row in enumerate(rows, 1):
        rate = f'{row["assetsPerSecond"]:.6f}' if row["throughputValid"] else "unavailable"
        stage = f'{row["stagingFraction"]:.1%}' if row["stagingValid"] else "unavailable"
        stalls = row["stalls"]
        lines.append(f'| {n} | {rate} | {row["assets"]} | {stage} | '
                     f'{stalls["over16"]} / {stalls["over33"]} / {stalls["over100"]} |')
        if row["automatic"]:
            lines.append("\nAutomatic/background run: excluded from the requested manual samples.\n")
        if row["issues"]:
            lines.append(f'\nRun {n}: ' + "; ".join(row["issues"]) + ".\n")
    if rates:
        lines += ["", f"Median assets/s: {statistics.median(rates):.6f}"]
    lines += ["", "Combined staging (weighted by job wall): " + (f"{weighted:.1%}" if weighted is not None else "unavailable")]
    if capture.errors:
        lines += ["", "Capture errors: " + "; ".join(capture.errors)]
    lines += ["", "Build identity: `" + metadata.get("binarySHA256", "unavailable in replay") + "`.",
              "No filenames, Photos identifiers or destination paths are included in this report."]
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    return result


def stop_child(child):
    if child is None:
        return
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def app_metadata(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or Path(executable).name != executable:
        raise ValueError("app has no valid executable")
    digest = hashlib.sha256()
    with (app / "Contents/MacOS" / executable).open("rb") as binary:
        for chunk in iter(lambda: binary.read(1024 * 1024), b""):
            digest.update(chunk)
    return executable, {"appVersion": info.get("CFBundleShortVersionString"),
                        "appBuild": info.get("CFBundleVersion"),
                        "appBuildToolchain": info.get("DTXcodeBuild", "unavailable"),
                        "macOS": platform.mac_ver()[0], "binarySHA256": digest.hexdigest()}


def live_capture(args, capture, archive, metadata):
    executable, details = app_metadata(args.app)
    metadata.update(details)
    check = subprocess.run(["/usr/bin/pgrep", "-x", re.escape(executable)], capture_output=True)
    if check.returncode == 0:
        raise ValueError("Quit Photo Export first, then run this command again; an app is already running.")
    if check.returncode != 1:
        raise ValueError("Could not check for an existing app process.")
    predicate = 'subsystem == "com.valtteriluoma.photo-export" AND category == "Export.Measurement"'
    predicate += f' AND eventMessage CONTAINS "{capture.session}"'
    log = activity = None
    try:
        log = subprocess.Popen(
            ["/usr/bin/log", "stream", "--style", "ndjson", "--level", "info", "--predicate", predicate],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        # log prints this subscription acknowledgement even when no matching events exist.
        ready = log.stdout.readline().decode("utf-8", errors="replace")
        if not ready.startswith("Filtering the log data"):
            raise ValueError("Log capture did not start. Check log permissions; no app was launched.")
        activity = subprocess.Popen(["/usr/bin/caffeinate", "-du", "-w", str(os.getpid())])
        subprocess.run(["/usr/bin/open", "-n", str(args.app), "--args", "--export-watchdog",
                        "--export-measurements", capture.session], check=True)
        print(f"Capture started. Choose your selection and a fresh disposable destination for each export.\n"
              f"Start {args.runs} complete exports for {args.label}. Capture stops automatically.\n"
              "Ctrl-C saves partial results and leaves the app open.", flush=True)
        deadline = time.monotonic() + 90
        selector = selectors.DefaultSelector()
        selector.register(log.stdout, selectors.EVENT_READ)
        pending = b""
        try:
            while capture.eligible_count() < args.runs:
                if not selector.select(timeout=1):
                    if capture.pid is None and time.monotonic() > deadline:
                        raise ValueError("No measurement handshake: use the prepared measurement app.")
                    if capture.pid is not None:
                        try:
                            os.kill(capture.pid, 0)
                        except ProcessLookupError as error:
                            raise ValueError("The app quit before the requested captures completed.") from error
                    continue
                data = os.read(log.stdout.fileno(), 65536)
                if not data:
                    raise ValueError("Log capture exited before the requested runs completed.")
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    consume_line(line.decode("utf-8", errors="replace"), capture, archive)
                    if capture.errors:
                        raise ValueError("Capture integrity failed; inspect results.json and repeat the capture.")
                    if capture.eligible_count() >= args.runs:
                        return
        finally:
            selector.close()
    finally:
        stop_child(log)
        stop_child(activity)
        if log is not None and log.stdout is not None:
            log.stdout.close()


def consume_line(line, capture, archive):
    before = len(capture.errors)
    if not line.strip():
        return
    try:
        raw = json.loads(line)
    except ValueError:
        capture.errors.append("malformed or dropped log output")
        archive.write('{"captureError": true}\n')
        archive.flush()
        return
    if not isinstance(raw, dict):
        capture.errors.append("malformed log event")
        archive.write('{"captureError": true}\n')
        archive.flush()
        return
    if raw.get("finished") == 1 and "count" in raw:
        return
    clean = capture.consume(raw)
    if clean is not None:
        archive.write(json.dumps(clean) + "\n")
        archive.flush()
    if len(capture.errors) > before:
        archive.write('{"captureError": true}\n')
        archive.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Automatically collect real export runs and write a numeric/Markdown report.",
        epilog="You choose the Photos selection and a fresh disposable destination, then start each export. "
               "This command never starts exports or changes settings. The app stays open afterward.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=Path, help="prepared measurement-enabled .app to launch")
    source.add_argument("--replay", type=Path, help="recompute a report from numeric events, without launching")
    parser.add_argument("--session", help="capture session UUID (required with --replay)")
    parser.add_argument("--label", required=True, help="scenario, for example nas or icloud")
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--output", type=Path, help="new output directory; existing paths are refused")
    args = parser.parse_args(argv)
    if args.runs < 1 or (args.replay and not args.session):
        parser.error("--runs must be positive; --replay requires --session")
    try:
        session = str(uuid.UUID(args.session)) if args.session else str(uuid.uuid4())
        output = args.output
        if output is None:
            output = Path(tempfile.mkdtemp(prefix="photo-export-measurements-"))
        else:
            output.mkdir(parents=True, exist_ok=False)
    except (ValueError, OSError) as error:
        parser.exit(2, f"measurement collector: {error}\n")
    capture = Capture(session)
    metadata = {"source": "replay" if args.replay else "live", "macOS": platform.mac_ver()[0]}
    status = 0
    try:
        with (output / "events.ndjson").open("w") as archive:
            if args.replay:
                with args.replay.open() as stream:
                    for line in stream:
                        consume_line(line, capture, archive)
            else:
                live_capture(args, capture, archive, metadata)
    except KeyboardInterrupt:
        status = 130
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        status = 1
        print(f"measurement collector: {error}", file=sys.stderr)
        capture.errors.append("capture failed")
    result = save_report(output, capture, args.label, args.runs, metadata, partial=status != 0)
    print(f"Report: {output / 'summary.md'}", flush=True)
    return status or (0 if result["eligibleRuns"] >= args.runs and not capture.errors else 1)


if __name__ == "__main__":
    sys.exit(main())
