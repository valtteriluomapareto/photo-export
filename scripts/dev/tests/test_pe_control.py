"""Exercise the driver's wire handling without launching the app."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "pe_control.py"
SPEC = importlib.util.spec_from_file_location("pe_control", SCRIPT)
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)


class DriverTests(unittest.TestCase):
    def test_discovers_a_valid_run_directory(self):
        with tempfile.TemporaryDirectory(prefix=driver.PREFIX) as root:
            read_fd, write_fd = os.pipe()
            with os.fdopen(write_fd, "wb") as writer:
                writer.write(os.fsencode(root) + b"\n")
            with os.fdopen(read_fd, "rb") as pipe:
                self.assertEqual(driver.read_directory(pipe, 1), Path(root).resolve())

    def test_partial_discovery_line_respects_deadline(self):
        read_fd, write_fd = os.pipe()
        with os.fdopen(read_fd, "rb") as pipe, os.fdopen(write_fd, "wb") as writer:
            writer.write(b"/partial/path")
            writer.flush()
            with self.assertRaisesRegex(driver.DriverError, "Timed out"):
                driver.read_directory(pipe, 0.02)

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin process exit events")
    def test_stop_waits_for_the_verified_process(self):
        script = (
            "import signal, sys\n"
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(42))\n"
            "print('ready', flush=True)\n"
            "signal.pause()\n"
        )
        with subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE) as child:
            try:
                self.assertEqual(child.stdout.readline(), b"ready\n")
                run = SimpleNamespace(pid=child.pid, read=lambda: {}, record={
                    "process": driver.identity(child.pid),
                })
                run.verify = lambda: driver.Run.verify(run)
                driver.stop(run, timeout=1)
                self.assertEqual(child.poll(), 42)
            finally:
                if child.poll() is None:
                    child.kill()

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin process exit events")
    def test_stop_times_out_if_same_process_remains_alive(self):
        script = (
            "import signal\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('ready', flush=True)\n"
            "signal.pause()\n"
        )
        with subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE) as child:
            try:
                self.assertEqual(child.stdout.readline(), b"ready\n")
                run = SimpleNamespace(pid=child.pid, read=lambda: {}, record={
                    "process": driver.identity(child.pid),
                })
                run.verify = lambda: driver.Run.verify(run)
                with self.assertRaisesRegex(driver.DriverError, "Timed out"):
                    driver.stop(run, timeout=0.02)
                self.assertIsNone(child.poll())
            finally:
                if child.poll() is None:
                    child.kill()

    def test_contract_paths_null_and_boolean_are_strict(self):
        state = {"export": {"running": False}, "import": {"result": None}}
        self.assertEqual(driver.unmet(state, driver.predicates(
            ["export.running=false", "import.result.matched=null"])), [])
        self.assertEqual(driver.unmet(state, [("export.running", 0)]),
                         ["export.running: expected 0, observed false"])
        with self.assertRaisesRegex(driver.DriverError, "Unknown state path"):
            driver.field(state, "export.missing")
        with self.assertRaisesRegex(driver.DriverError, "Expected PATH=JSON"):
            driver.predicates(["x=NaN"])

    def test_request_fields_reject_duplicates_and_reserved_keys(self):
        for raw in [
            '{"action":"one","a\\u0063tion":"two"}',
            '{"action":"one","seq":1}',
            '{"action":"one","extra":Infinity}',
            '["export.month"]',
        ]:
            with self.subTest(raw=raw), self.assertRaises((ValueError, driver.DriverError)):
                driver.action_fields(raw)
        self.assertEqual(driver.action_fields('{"action":"export.pause"}'),
                         {"action": "export.pause"})

    def test_published_action_recovery_does_not_replay(self):
        class FakeRun:
            def __init__(self, root):
                self.root = root

            def read(self):
                return {"run": "fixture", "settledSeq": 0, "seq": 0}

            def verify(self):
                pass

        def publish(path, value, *, exclusive):
            self.assertTrue(exclusive)
            path.write_text(json.dumps(value))

        with tempfile.TemporaryDirectory() as directory:
            run = FakeRun(Path(directory))
            fields = {"action": "export.pause"}
            with patch.object(driver, "atomic_json", side_effect=publish) as writer:
                with patch.object(driver, "await_result", side_effect=TimeoutError):
                    with self.assertRaisesRegex(driver.DriverError, "--seq 1"):
                        driver.action(run, fields, 1)
                with self.assertRaisesRegex(driver.DriverError, "recorded request"):
                    driver.action(run, fields, 1)
                with patch.object(driver, "await_result", return_value={"status": "accepted"}):
                    self.assertEqual(driver.action(run, fields, 1, sequence=1),
                                     {"status": "accepted"})
                writer.assert_called_once()

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin's exclusive rename")
    def test_atomic_exclusive_publication_does_not_overwrite_or_leave_hard_links(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "req-1.json"
            driver.atomic_json(path, {"seq": 1}, exclusive=True)
            with self.assertRaises(FileExistsError):
                driver.atomic_json(path, {"seq": 2}, exclusive=True)
            self.assertEqual(driver.read_json(path), {"seq": 1})
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_read_rejects_linked_or_nonregular_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            linked = root / "linked"
            linked.symlink_to(root / "absent")
            with self.assertRaises(OSError):
                driver.read_json(linked)
            with self.assertRaisesRegex(driver.DriverError, "regular JSON file"):
                driver.read_json(root)

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin process identity")
    def test_process_identity_reads_own_start_and_executable(self):
        result = driver.identity(os.getpid())
        self.assertEqual(result["pid"], os.getpid())
        self.assertTrue(Path(result["executable"]).name.lower().startswith("python"))
        self.assertGreater(result["start"][0], 0)


if __name__ == "__main__":
    unittest.main()
