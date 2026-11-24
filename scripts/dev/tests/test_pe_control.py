"""Exercise the driver's wire handling without launching the app."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "pe_control.py"
SPEC = importlib.util.spec_from_file_location("pe_control", SCRIPT)
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)


class DriverTests(unittest.TestCase):
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
        import os

        result = driver.identity(os.getpid())
        self.assertEqual(result["pid"], os.getpid())
        self.assertTrue(Path(result["executable"]).name.lower().startswith("python"))
        self.assertGreater(result["start"][0], 0)


if __name__ == "__main__":
    unittest.main()
