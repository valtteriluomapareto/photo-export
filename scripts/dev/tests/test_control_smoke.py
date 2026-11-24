"""Verify the hosted smoke rejects false positives and keeps failure evidence."""
from io import StringIO
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import control_smoke


class ControlSmokeTests(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.root = Path(root.name)
        self.run = self.root / "run"
        self.evidence = self.root / "evidence"
        self.month = self.run / "Destination" / "2025" / "06"
        self.month.mkdir(parents=True)
        self.evidence.mkdir()
        (self.run / "state.json").write_text("{}")
        (self.run / "req-1.json").write_text("{}")
        self.calls = []
        self.seq = 0
        self.repeat = lambda: None
        self.response = "accepted"

    def driver(self, *args):
        self.calls.append(args)
        if args[0] == "launch":
            return str(self.run)
        if args[0] == "action":
            self.seq += 1
            response = json.dumps({"status": self.response, "seq": self.seq})
            (self.run / f"res-{self.seq}.json").write_text(response)
            if self.seq == 1:
                for name in ("Harbor.png", "Pines.png"):
                    (self.month / name).write_bytes(b"\x89PNG\r\n\x1a\n" + name.encode())
            else:
                self.repeat()
            return response
        return "{}"

    def test_launch_timeout_terminates_the_fixture_process_group(self):
        transcript = StringIO()
        with patch.object(control_smoke.subprocess, "Popen") as popen, \
             patch.object(control_smoke.os, "killpg") as killpg:
            process = popen.return_value.__enter__.return_value
            process.communicate.side_effect = [
                subprocess.TimeoutExpired("launch", 40), ("", "startup diagnostic"),
            ]
            with self.assertRaises(subprocess.TimeoutExpired):
                control_smoke.run_driver(transcript, "launch", "--app", "Debug.app")
            self.assertIn("--share-process-group", popen.call_args.args[0])
            self.assertTrue(popen.call_args.kwargs["start_new_session"])
            killpg.assert_called_once_with(process.pid, signal.SIGKILL)
            self.assertIn("startup diagnostic", transcript.getvalue())

    def test_smoke_waits_for_each_settled_request_and_stops(self):
        control_smoke.verify(self.driver, Path("Debug.app"), self.evidence)
        self.assertEqual([args[0] for args in self.calls],
                         ["launch", "action", "wait", "action", "wait", "stop"])
        for seq, index in enumerate((2, 4), start=1):
            self.assertIn(f"settledSeq={seq}", self.calls[index])
            self.assertIn("idle=true", self.calls[index])
            self.assertIn("records.exportedByMonth.2025-06=2", self.calls[index])
        self.assertIn("export.enqueued=0", self.calls[4])

    def test_repeat_with_same_bytes_replacing_a_file_fails_and_keeps_evidence(self):
        def replace():
            target = self.month / "Harbor.png"
            replacement = self.month / "replacement"
            replacement.write_bytes(target.read_bytes())
            os.replace(replacement, target)

        self.repeat = replace
        with self.assertRaisesRegex(control_smoke.SmokeError, "changed"):
            control_smoke.verify(self.driver, Path("Debug.app"), self.evidence)
        self.assertEqual(self.calls[-1], ("stop", str(self.run)))
        self.assertEqual(sorted(path.name for path in self.evidence.iterdir()),
                         ["res-1.json", "res-2.json", "state.json"])

    def test_noop_is_not_an_accepted_export(self):
        self.response = "noop"
        with self.assertRaisesRegex(control_smoke.SmokeError, "accepted"):
            control_smoke.verify(self.driver, Path("Debug.app"), self.evidence)
        self.assertEqual([args[0] for args in self.calls], ["launch", "action", "stop"])


if __name__ == "__main__":
    unittest.main()
