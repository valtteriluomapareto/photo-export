#!/usr/bin/env python3
"""Capture a supplied app's opt-in numeric export events, or replay a capture."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import selectors
import subprocess
import sys
import tempfile
import time
import uuid

KINDS = {
    "ready": set(), "runBegin": {"automatic", "convertHEICToJPEG"},
    "completion": {"asset", "atNs"}, "jobEnd": {"wallNs", "stageNs"},
    "turn": {"durationNs"}, "runEnd": {"wallNs"},
}


def integer(value, minimum=0):
    return type(value) is int and value >= minimum


class Capture:
    def __init__(self, session, cache_state="unknown"):
        self.session = session
        self.cache_state = cache_state
        self.pid = None
        self.runs = {}
        self.errors = []

    def consume(self, raw):
        if not isinstance(raw, dict):
            self.errors.append("malformed log event")
            return None
        if raw.get("captureError") or raw.get("dropped") or raw.get("eventType") == "lossEvent":
            self.errors.append("log capture was incomplete")
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
        if not isinstance(kind, str) or kind not in KINDS:
            return None  # Old captures also contain unused job/enqueue/invalidation events.
        if event.get("schema") != 1 or not integer(pid, 1):
            self.errors.append("unsupported measurement event")
            return None
        if kind == "ready":
            self.pid = pid
            return dict(schema=1, session=self.session, type=kind, pid=pid)
        try:
            uuid.UUID(event.get("run", ""))
        except (ValueError, TypeError, AttributeError):
            self.errors.append("measurement has no valid run identity")
            return None
        clean = dict(schema=1, session=self.session, type=kind, pid=pid, run=event["run"])
        for key in KINDS[kind]:
            value = event.get(key)
            if key in {"automatic", "convertHEICToJPEG"}:
                valid = type(value) is bool
            else:
                valid = integer(value, 1 if key == "asset" else 0)
            if not valid and key not in {"stageNs", "convertHEICToJPEG"}:
                self.errors.append("malformed required measurement field")
                return None
            clean[key] = value if valid else None
        self.runs.setdefault(clean["run"], []).append(clean)
        return clean

    def summaries(self):
        return [summarize(rows, self.cache_state) for rows in self.runs.values()]

    def eligible_count(self):
        return sum(row["eligible"] for row in self.summaries())


def comparison(row, cache_state):
    row["cacheState"] = cache_state
    row["comparisonSuitable"] = (row["eligible"] and cache_state != "unknown" and row["heicConversion"] is not None
                                 and (cache_state != "warm" or row["completionWindowSeconds"] >= 30))
    return row


def summarize(rows, cache_state="unknown"):
    begin = next((row for row in rows if row["type"] == "runBegin"), {})
    end = next((row for row in reversed(rows) if row["type"] == "runEnd"), {})
    completions = [row for row in rows if row["type"] == "completion"]
    jobs = [row for row in rows if row["type"] == "jobEnd"]
    stamps = [row["atNs"] for row in completions]
    assets = {row["asset"] for row in completions}
    window = (max(stamps) - min(stamps)) / 1e9 if stamps else 0
    staging_valid = bool(jobs) and all(integer(row.get("stageNs"))
                                     and row["stageNs"] <= row["wallNs"] for row in jobs)
    wall = sum(row["wallNs"] for row in jobs)
    stage = sum(row["stageNs"] for row in jobs) if staging_valid else None
    fraction = stage / wall if staging_valid and wall else None
    turns = [row["durationNs"] for row in rows if row["type"] == "turn"]
    return comparison({
        "run": rows[0]["run"], "finished": bool(end),
        "automatic": begin.get("automatic"), "heicConversion": begin.get("convertHEICToJPEG"),
        "eligible": bool(end) and begin.get("automatic") is False and window > 0,
        "assets": len(assets), "variantCompletions": len(completions),
        "completionWindowSeconds": window, "assetsPerSecond": len(assets) / window if window else None,
        "logicalRunSeconds": end.get("wallNs", 0) / 1e9 if end else None,
        "jobWallSeconds": wall / 1e9, "stagingSeconds": stage / 1e9 if stage is not None else None,
        "stagingFraction": fraction,
        "stalls": {"over16": sum(t > 16_000_000 for t in turns),
                   "over33": sum(t > 33_000_000 for t in turns),
                   "over100": sum(t > 100_000_000 for t in turns)},
    }, cache_state)


def completion_log_summary(name, lines, cache_state):
    """Legacy log replay uses the same distinct-asset / completion-window denominator."""
    stamps, identifiers = [], set()
    completion = re.compile(r"\bExported .+ variant: \S+ -> .+")
    timestamp = re.compile(r"^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)(?=\s)")
    for line in lines:
        if not completion.search(line):
            continue
        match = timestamp.match(line)
        if not match:
            raise ValueError("invalid completion timestamp (include date and time)")
        try:
            stamp = datetime.datetime.fromisoformat(match[1].replace("Z", "+00:00"))
        except ValueError as error:
            raise ValueError("invalid completion timestamp") from error
        identity = re.search(r".* asset: (.+)$", line.rstrip())
        if not identity or not identity[1].strip():
            raise ValueError("missing asset identifier; capture a current app build")
        if identity[1] == "<private>":
            raise ValueError("private asset identifier; use the public completion log")
        stamps.append(stamp)
        identifiers.add(identity[1])
    if not stamps:
        raise ValueError("no Exported completion lines")
    if len({stamp.utcoffset() is None for stamp in stamps}) > 1:
        raise ValueError("mixed offset-free and offset-aware timestamps")
    window = (max(stamps) - min(stamps)).total_seconds()
    if window <= 0:
        raise ValueError("at least two distinct completion timestamps are required")
    return comparison({
        "run": name, "finished": True, "automatic": False, "heicConversion": None,
        "eligible": True, "assets": len(identifiers), "variantCompletions": len(stamps),
        "completionWindowSeconds": window, "assetsPerSecond": len(identifiers) / window,
        "stagingFraction": None, "stalls": None,
    }, cache_state)


def save_report(output, capture, label, requested, metadata, partial=False, rows=None):
    rows = capture.summaries() if rows is None else rows
    eligible = sum(row["eligible"] for row in rows)
    result = {"schema": 1, "label": label, "session": capture.session, "requestedRuns": requested,
              "eligibleRuns": eligible, "partial": partial or eligible < requested,
              "captureErrors": capture.errors, "metadata": metadata, "runs": rows}
    (output / "results.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    clean_label = re.sub(r"[\r\n|]", " ", label)
    lines = [f"Export measurements: {clean_label}", "",
             "Each run is independent; compare matching cold or warm conditions and HEIC settings.",
             "Throughput window: first-to-last-completion; distinct assets across variants/placements.",
             "Staging: producer-await wall / job wall; not CPU time. Choose complete uninterrupted exports.",
             "Warm completion windows below 30 seconds are unsuitable for comparison.", "",
             "| Run | Cache | HEIC→JPEG | Assets/s | Assets | Staging | >16 / >33 / >100 ms turns | Comparison |",
             "| --- | --- | --- | ---: | ---: | ---: | ---: | --- |"]
    for n, row in enumerate(rows, 1):
        rate = f'{row["assetsPerSecond"]:.6f}' if row["assetsPerSecond"] is not None else "unavailable"
        stage = f'{row["stagingFraction"]:.1%}' if row["stagingFraction"] is not None else "unavailable"
        heic = {True: "on", False: "off", None: "unknown"}[row["heicConversion"]]
        stalls = row["stalls"]
        counts = f'{stalls["over16"]} / {stalls["over33"]} / {stalls["over100"]}' if stalls is not None else "unavailable"
        suitability = "suitable" if row["comparisonSuitable"] else "unsuitable"
        lines.append(f'| {n} | {row["cacheState"]} | {heic} | {rate} | {row["assets"]} | {stage} | {counts} | {suitability} |')
        if row["automatic"]:
            lines.append("\nAutomatic/background run: excluded from requested manual samples.\n")
    if capture.errors:
        lines += ["", "Capture errors: " + "; ".join(capture.errors)]
    lines += ["", f"App: {metadata.get('appVersion', 'unavailable')} (build {metadata.get('appBuild', 'unavailable')}).",
              f"App build toolchain: {metadata.get('appBuildToolchain', 'unavailable in replay')}.",
              f"Measurement macOS: {metadata.get('macOS', 'unavailable in replay')}.",
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
    return executable, {"appVersion": info.get("CFBundleShortVersionString"),
                        "appBuild": info.get("CFBundleVersion"),
                        "appBuildToolchain": info.get("DTXcodeBuild", "unavailable"),
                        "macOS": platform.mac_ver()[0]}



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
                        raise ValueError("Log capture failed; inspect results.json and repeat the capture.")
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
    source.add_argument("--completion-log", type=Path, nargs="+",
                        help="legacy completion logs: one file per export run; - reads stdin")
    parser.add_argument("--cache-state", choices=["cold", "warm", "unknown"], required=True,
                        help="state shared by these samples; capture cold and warm runs separately")
    parser.add_argument("--session", help="capture session UUID (required with --replay)")
    parser.add_argument("--label", required=True, help="scenario, for example nas or icloud")
    parser.add_argument("--runs", type=int, default=1)
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
    capture = Capture(session, args.cache_state)
    metadata = {"source": "live" if args.app else "replay"}
    if args.app:
        metadata["macOS"] = platform.mac_ver()[0]
    status = 0
    rows = None
    try:
        with (output / "events.ndjson").open("w") as archive:
            if args.completion_log:
                rows = []
                for number, name in enumerate(args.completion_log, 1):
                    if str(name) == "-":
                        row = completion_log_summary(str(number), sys.stdin, args.cache_state)
                    else:
                        with name.open() as stream:
                            row = completion_log_summary(str(number), stream, args.cache_state)
                    rows.append(row)
            elif args.replay:
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
    result = save_report(output, capture, args.label, args.runs, metadata, partial=status != 0, rows=rows)
    print(f"Report: {output / 'summary.md'}", flush=True)
    return status or (0 if result["eligibleRuns"] >= args.runs and not capture.errors else 1)


if __name__ == "__main__":
    sys.exit(main())
