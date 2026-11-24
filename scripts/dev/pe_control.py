#!/usr/bin/env python3
"""Drive the macOS Debug app against a private synthetic fixture."""
import argparse
from contextlib import closing, contextmanager
import ctypes
import fcntl
import json
import math
import os
from pathlib import Path
import plistlib
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time

PREFIX = "photo-export-control-"
BUNDLE_ID = "com.valtteriluoma.photo-export"
STATE = {
    "snapshotVersion": None, "run": None, "revision": None, "fixture": None,
    "appearance": None, "surface": None, "idle": None, "pid": None,
    "windowNumber": None, "seq": None, "settledSeq": None,
    "destination": {"status": None, "available": None, "hasIdentity": None, "folder": None},
    "export": {"running": None, "paused": None, "queueCount": None, "runSource": None,
               "enqueued": None, "completed": None},
    "import": {"running": None, "stage": None, "previousBackupMissing": None,
               "result": dict.fromkeys(("matched", "ambiguous", "unmatched", "scanned",
                                        "prunedVariants", "prunedRecords", "collectionScanned",
                                        "collectionMatched"))},
    "autoSync": {"enabled": None, "state": None, "waitingReason": None},
    "records": {"timeline": None, "collections": None, "exportedByMonth": {}},
    "prompts": dict.fromkeys(("migrationConflict", "destinationSafetyConfirmation",
                             "previousBackupMissing", "supersedeAutoSync",
                             "timelineHistoryRecovery", "collectionHistoryRecovery")),
}
READY = [("idle", True), ("destination.status", "ready"), ("destination.hasIdentity", True),
         ("records.timeline", "ready"), ("records.collections", "ready")]
SURFACES = ("library", "favorites", "autoExport", "exportIssues", "advanced")

class DriverError(Exception):
    pass


def atomic_json(path, value, *, exclusive=False):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            if exclusive:
                # Darwin's RENAME_EXCL publishes one name atomically. The app rejects
                # requests with multiple hard links.
                rename = ctypes.CDLL(None, use_errno=True).renamex_np
                if rename(os.fsencode(temporary), os.fsencode(path), 0x4) != 0:
                    code = ctypes.get_errno()
                    raise OSError(code, os.strerror(code), path)
            else:
                temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def read_json(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise DriverError(f"Expected a regular JSON file: {path.name}")
        with open(descriptor, "rb", closefd=False) as stream:
            data = stream.read(256 * 1024 + 1)
    finally:
        os.close(descriptor)
    if len(data) > 256 * 1024:
        raise DriverError(f"JSON file is too large: {path.name}")
    return json.loads(data)


def field(state, path):
    schema = STATE
    value = state
    for key in path.removeprefix(".").split("."):
        if not isinstance(schema, dict):
            raise DriverError(f"Unknown state path: {path}")
        if key not in schema and (not isinstance(value, dict) or key not in value):
            raise DriverError(f"Unknown state path: {path}")
        schema = schema.get(key)
        value = value.get(key) if isinstance(value, dict) else None
    return value


def invalid_constant(value):
    raise ValueError(value)


def predicates(expressions):
    result = []
    for expression in expressions:
        path, separator, literal = expression.partition("=")
        try:
            if not separator or not path:
                raise ValueError(expression)
            expected = json.loads(literal, parse_constant=invalid_constant)
        except ValueError as error:
            raise DriverError(f"Expected PATH=JSON: {expression}") from error
        result.append((path, expected))
    return result


def json_text(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def unmet(state, conditions):
    failures = []
    for path, expected in conditions:
        value = field(state, path)
        if json_text(value) != json_text(expected):
            failures.append(f"{path}: expected {json_text(expected)}, observed {json_text(value)}")
    return failures


def wait_for(directory, pid, read, conditions, timeout, ready=lambda _: True):
    deadline = time.monotonic() + timeout
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with closing(select.kqueue()) as queue:
            try:
                queue.control([
                    select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                  flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                  fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME
                                  | select.KQ_NOTE_DELETE),
                    select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD,
                                  fflags=select.KQ_NOTE_EXIT),
                ], 0)
            except ProcessLookupError as error:
                raise DriverError("Fixture process exited before the wait could start.") from error
            while True:
                state = read()
                misses = unmet(state, conditions) if state is not None else ["No state published"]
                if state is not None and not misses and ready(state):
                    return state
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    detail = "\n".join(misses) or "Requested window or action is not ready"
                    raise DriverError(f"Timed out waiting for fixture:\n{detail}")
                for event in queue.control(None, 2, remaining):
                    if event.filter == select.KQ_FILTER_PROC:
                        raise DriverError("Fixture process exited. Check its app.log.")
                    if event.fflags & (select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE):
                        raise DriverError("Fixture run directory was moved or removed.")
    finally:
        os.close(fd)


class ProcessInfo(ctypes.Structure):
    """Darwin's proc_bsdinfo from sys/proc_info.h."""
    _fields_ = [
        ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
        ("exit_status", ctypes.c_uint32), ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
        ("remaining_ids", ctypes.c_uint32 * 6),
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("remaining_counters", ctypes.c_uint32 * 6),
        ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64),
    ]


def identity(pid):
    if type(pid) is not int or not 1 <= pid <= 2**31 - 1:
        raise DriverError("Invalid fixture process ID.")
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    info = ProcessInfo()
    size = ctypes.sizeof(info)
    # PROC_PIDTBSDINFO returns the effective UID and subsecond process start time.
    if libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(info), size) != size:
        return None
    if info.uid != os.geteuid():
        return None
    executable = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, executable, ctypes.sizeof(executable)) <= 0:
        return None
    return {"pid": pid, "executable": str(Path(os.fsdecode(executable.value)).resolve()),
            "start": [info.start_seconds, info.start_microseconds]}


def container_temp():
    return (Path.home() / "Library/Containers" / BUNDLE_ID / "Data/tmp").resolve()


def validate_run(path):
    path = Path(path).absolute()
    info = path.lstat()
    roots = (Path(tempfile.gettempdir()).resolve(), container_temp())
    if (path.parent.resolve() not in roots or path.resolve() != path.parent.resolve() / path.name
            or not path.name.startswith(PREFIX) or not stat.S_ISDIR(info.st_mode)
            or stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid()):
        raise DriverError("Use the private directory printed by pe_control.py launch.")
    return path.resolve()


class Run:
    def __init__(self, root, record=None):
        self.root = validate_run(root)
        self.record = read_json(self.root / "driver.json") if record is None else record
        if record is None and (not isinstance(self.record, dict)
                               or not isinstance(self.record.get("run"), str)
                               or not self.record["run"]):
            raise DriverError("The fixture driver record has no run identity.")
        self.pid = self.record["process"]["pid"]
        self.verify()

    def verify(self):
        saved = self.record["process"]
        if identity(self.pid) != saved:
            raise DriverError("Fixture process exited or changed identity. Launch a fresh run.")

    def read(self):
        self.verify()
        try:
            state = read_json(self.root / "state.json")
        except FileNotFoundError:
            return None
        if (not isinstance(state, dict) or state.get("snapshotVersion") != 1
                or not isinstance(state.get("run"), str) or state.get("pid") != self.pid
                or state.get("fixture") != "v1"
                or self.record.get("run", state["run"]) != state["run"]):
            raise DriverError("State does not belong to the recorded fixture process.")
        return state

    def wait(self, conditions, timeout, ready=lambda _: True):
        return wait_for(self.root, self.pid, self.read, conditions, timeout, ready)


def fixture_command(args):
    app = Path(args.app).resolve(strict=True)
    if app.suffix != ".app":
        raise DriverError("Pass a built Debug .app bundle with --app.")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise DriverError("The app bundle is not Photo Export.")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    flags = ["-PEFixture", "v1", "-PESurface", args.surface, "-PESize", args.size]
    if args.dark:
        flags.append("-PEDark")
    if args.command == "snapshot":
        flags.extend(("-PESnapshot", "snapshot.png"))
    return executable, flags


def fixture_environment():
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("XCTest", "XCInject"))}
    environment["TZ"] = "UTC"
    return environment


def start_fixture(args):
    # Let the app create its root so a first signed launch can initialize its container.
    executable, flags = fixture_command(args)
    log_file = args.app_log.open("x+b") if args.app_log else tempfile.TemporaryFile()
    with log_file as startup_log:
        child = subprocess.Popen(
            [executable, *flags], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=startup_log, env=fixture_environment(), start_new_session=True)
        handed_off = False
        try:
            if not select.select([child.stdout], [], [], args.timeout)[0]:
                raise DriverError("Timed out waiting for the fixture directory.")
            root_line = child.stdout.readline(4096)
            if not root_line.endswith(b"\n"):
                raise DriverError("Fixture exited before publishing its directory.")
            root = validate_run(os.fsdecode(root_line.rstrip(b"\n")))
            # Copy startup diagnostics without moving the shared descriptor's offset.
            with (root / "app.log").open("xb") as log:
                log.write(os.pread(startup_log.fileno(), 256 * 1024, 0))
            if args.command == "snapshot":
                if child.wait(timeout=args.timeout) != 0:
                    raise DriverError("Offscreen capture failed.")
            else:
                process = identity(child.pid)
                if process is None or process["executable"] != str(executable.resolve()):
                    raise DriverError("Fixture exited or changed identity during startup.")
                run = Run(root, {"process": process})
                state = run.wait(READY, args.timeout)
                run.record["run"] = state["run"]
                atomic_json(root / "driver.json", run.record, exclusive=True)
                handed_off = True
            print(root, flush=True)
        except (DriverError, OSError, ValueError, subprocess.SubprocessError,
                KeyboardInterrupt) as error:
            diagnostics = os.pread(startup_log.fileno(), 256 * 1024, 0).decode(errors="replace").strip()
            message = str(error) or "Fixture startup interrupted."
            raise DriverError(f"{message}\n{diagnostics}" if diagnostics else message) from error
        finally:
            child.stdout.close()
            if not handed_off and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)


def same_capture_state(before, after):
    return ({k: v for k, v in before.items() if k != "revision"}
            == {k: v for k, v in after.items() if k != "revision"})


def confirm_window(run, number):
    run.verify()
    graphics = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    foundation = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    graphics.CGWindowListCopyWindowInfo.argtypes = (ctypes.c_uint32, ctypes.c_uint32)
    graphics.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    foundation.CFPropertyListCreateData.argtypes = (
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_ulong, ctypes.c_void_p)
    foundation.CFPropertyListCreateData.restype = ctypes.c_void_p
    foundation.CFDataGetLength.argtypes = (ctypes.c_void_p,)
    foundation.CFDataGetLength.restype = ctypes.c_long
    foundation.CFDataGetBytePtr.argtypes = (ctypes.c_void_p,)
    foundation.CFDataGetBytePtr.restype = ctypes.c_void_p
    foundation.CFRelease.argtypes = (ctypes.c_void_p,)
    windows = graphics.CGWindowListCopyWindowInfo(1 << 3, number)  # including the named window
    if windows:
        try:
            data = foundation.CFPropertyListCreateData(None, windows, 100, 0, None)
            if data:
                try:
                    entries = plistlib.loads(ctypes.string_at(
                        foundation.CFDataGetBytePtr(data), foundation.CFDataGetLength(data)))
                    if any(entry.get("kCGWindowNumber") == number
                           and entry.get("kCGWindowOwnerPID") == run.pid for entry in entries):
                        return
                finally:
                    foundation.CFRelease(data)
        finally:
            foundation.CFRelease(windows)
    raise DriverError("Owned window is not capturable. Use snapshot for offscreen evidence.")


def shot(run, destination, timeout):
    output = Path(destination).absolute()
    if output.suffix.lower() != ".png":
        raise DriverError("Choose a .png output for shot.")
    sidecar = output.with_suffix(output.suffix + ".json")
    if os.path.lexists(output) or os.path.lexists(sidecar):
        raise DriverError("Choose an unused PNG path and sidecar path.")
    before = run.wait(READY, timeout, lambda s: type(s.get("windowNumber")) is int
                      and s["windowNumber"] > 0 and s.get("seq") == s.get("settledSeq"))
    number = before["windowNumber"]
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        temporary = Path(directory) / "capture.png"
        confirm_window(run, number)
        result = subprocess.run(["/usr/sbin/screencapture", f"-l{number}", "-o", temporary],
                                capture_output=True, timeout=timeout)
        if result.returncode or not temporary.is_file():
            raise DriverError("screencapture could not capture the owned window. Try the command in "
                              "an authorized Terminal or use snapshot for offscreen evidence.")
        with temporary.open("rb") as stream:
            if stream.read(8) != b"\x89PNG\r\n\x1a\n" or temporary.stat().st_size <= 8:
                raise DriverError("screencapture did not produce a PNG.")
        confirm_window(run, number)
        after = run.read()
        if after is None or not same_capture_state(before, after):
            raise DriverError("Fixture state changed during capture. Wait for it to settle and retry.")
        receipt = temporary.with_suffix(".json")
        atomic_json(receipt, after)
        os.link(receipt, sidecar)
        try:
            os.link(temporary, output)
        except OSError:
            sidecar.unlink()
            raise
    print(output)


@contextmanager
def client_lock(run):
    with os.fdopen(os.open(run.root / "client.lock",
                          os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "rb+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            raise DriverError("Fixture client lock is not a regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DriverError("Another client is driving this run. Retry after it finishes.") from error
        yield


def unique_fields(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON object key")
    return result


def action_fields(literal):
    value = json.loads(literal, object_pairs_hook=unique_fields, parse_constant=invalid_constant)
    if (not isinstance(value, dict) or not isinstance(value.get("action"), str)
            or {"version", "run", "seq"} & value.keys()
            or len(literal.encode()) > 15_000):
        raise DriverError("Use an action JSON object without version, run, or seq.")
    return value


def mailbox_state(run):
    state = run.read()
    if (not state or type(state.get("settledSeq")) is not int or type(state.get("seq")) is not int
            or not 0 <= state["settledSeq"] <= state["seq"] <= state["settledSeq"] + 1):
        raise DriverError("Run does not have a live action mailbox.")
    return state


def recovery_error(error, sequence):
    detail = str(error) or "Interrupted while reading the action result."
    return DriverError(f"{detail}\nAction {sequence} may have run. Repeat with --seq {sequence} "
                       "to read its result without replaying it. If it stays pending, "
                       "stop and relaunch the fixture.")


def action(run, fields, timeout, sequence=None):
    state = mailbox_state(run)
    recover = sequence is not None
    if sequence is None:
        sequence = state["settledSeq"] + 1
    request = run.root / f"req-{sequence}.json"
    envelope = {**fields, "version": 1, "run": state["run"], "seq": sequence}
    try:
        existing = read_json(request)
    except FileNotFoundError:
        existing = None
    except (OSError, ValueError, KeyboardInterrupt) as error:
        raise recovery_error(error, sequence) from error
    if existing is None:
        if recover or sequence <= state["seq"]:
            raise DriverError(f"No recorded action at sequence {sequence}.")
        run.verify()
    elif not recover or json_text(existing) != json_text(envelope):
        raise DriverError(f"Sequence {sequence} already has a recorded request. "
                          f"Use its original action with --seq {sequence} to recover the result.")
    try:
        if existing is None:
            atomic_json(request, envelope, exclusive=True)
        return await_result(run, sequence, state["run"], timeout)
    except (DriverError, OSError, ValueError, TypeError, AttributeError, KeyError,
            subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise recovery_error(error, sequence) from error


def await_result(run, sequence, run_id, timeout):
    response = run.root / f"res-{sequence}.json"
    run.wait([], timeout, lambda current: current["settledSeq"] >= sequence and response.exists())
    result = read_json(response)
    if (result.get("version") != 1 or result.get("run") != run_id
            or result.get("seq") != sequence or result.get("status") not in ("accepted", "noop", "refused")):
        raise DriverError(f"Invalid result for action {sequence}.")
    return result


def seconds(value):
    amount = float(value)
    if not math.isfinite(amount) or not 0 < amount <= 300:
        raise argparse.ArgumentTypeError("seconds must be greater than 0 and at most 300")
    return amount


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("launch", "snapshot"):
        command = commands.add_parser(name)
        command.add_argument("--app", type=Path, required=True)
        command.add_argument("--surface", choices=SURFACES if name == "snapshot" else SURFACES[:2],
                             default="library")
        command.add_argument("--size", default="1280x800")
        command.add_argument("--dark", action="store_true")
        command.add_argument("--app-log", type=Path, help="write the live app stderr to a new file")
        command.add_argument("--timeout", type=seconds, default=30)
    for name in ("state", "wait", "action", "shot", "stop"):
        command = commands.add_parser(name)
        command.add_argument("run", type=Path)
        if name in ("wait", "action", "shot"):
            command.add_argument("--timeout", type=seconds, default=30)
        if name == "state":
            command.add_argument("path", nargs="?")
        elif name == "wait":
            command.add_argument("predicates", nargs="+")
        elif name == "action":
            command.add_argument("json")
            command.add_argument("--seq", type=int)
        elif name == "shot":
            command.add_argument("destination", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command in ("launch", "snapshot"):
            start_fixture(args)
            return 0
        if args.command == "state":
            state = read_json(validate_run(args.run) / "state.json")
            if not isinstance(state, dict) or state.get("snapshotVersion") != 1:
                raise DriverError("Expected a version 1 fixture state.")
            print(json_text(field(state, args.path) if args.path else state))
            return 0
        run = Run(args.run)
        if args.command == "wait":
            print(json_text(run.wait(predicates(args.predicates), args.timeout)))
        elif args.command == "action":
            if args.seq is not None and not 1 <= args.seq <= sys.maxsize:
                raise DriverError("A sequence must be a positive integer.")
            fields = action_fields(args.json)
            with client_lock(run):
                result = action(run, fields, args.timeout, args.seq)
            print(json_text(result))
            return 1 if result["status"] == "refused" else 0
        elif args.command == "shot":
            shot(run, args.destination, args.timeout)
        elif args.command == "stop":
            with client_lock(run):
                if run.read() is None:
                    raise DriverError("Fixture process has no matching published state.")
                os.kill(run.pid, signal.SIGTERM)
        return 0
    except (DriverError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Photo Export control: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
