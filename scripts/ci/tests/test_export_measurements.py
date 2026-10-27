"""Replay tests use only numeric events; live-process tests inject command fakes."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/perf/collect_export_measurements.py"
SESSION = "01234567-0123-4567-8901-012345678901"
RUN = "11111111-1111-4111-8111-111111111111"


def events(run=RUN, offset=0, invalid=False):
    rows = [dict(type="ready", session=SESSION, schema=1, pid=42)]
    body = [
        dict(type="runBegin"), dict(type="enqueued", count=2),
        dict(type="jobBegin", job=1, asset=1),
        dict(type="completion", job=1, asset=1, atNs=offset + 1_000_000_000),
        dict(type="completion", job=1, asset=1, atNs=offset + 2_000_000_000),
        dict(type="jobEnd", job=1, asset=1, wallNs=2_000_000_000, stageNs=1_000_000_000, stageValid=True),
        dict(type="turn", durationNs=101_000_000),
        dict(type="jobBegin", job=2, asset=2),
        dict(type="completion", job=2, asset=2, atNs=offset + 3_000_000_000),
        dict(type="jobEnd", job=2, asset=2, wallNs=2_000_000_000, stageNs=2_000_000_000, stageValid=True),
    ]
    if invalid:
        body.append(dict(type="invalidated", reason="pending-cleared"))
    body.append(dict(type="runEnd", valid=not invalid, reason="pending-cleared" if invalid else "complete",
                     enqueued=2, jobs=2, completions=3, wallNs=5_000_000_000))
    rows += [dict(row, schema=1, session=SESSION, run=run, seq=n, pid=42)
             for n, row in enumerate(body, 1)]
    return rows


class ExportMeasurementReplayTests(unittest.TestCase):
    def run_replay(self, rows, runs=1, existing=False):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            capture = root / "capture.ndjson"
            capture.write_text("".join(json.dumps(row) + "\n" for row in rows))
            output = root / "report"
            if existing:
                output.mkdir()
                (output / "keep").write_text("kept")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--replay", str(capture), "--session", SESSION,
                 "--label", "nas", "--runs", str(runs), "--output", str(output)],
                text=True, capture_output=True, check=False)
            data = json.loads((output / "results.json").read_text()) if (output / "results.json").exists() else None
            report = (output / "summary.md").read_text() if (output / "summary.md").exists() else ""
            kept = (output / "keep").read_text() if (output / "keep").exists() else None
            return result, data, report, kept

    def test_two_runs_deduplicate_variants_and_sum_job_wall_for_staging(self):
        rows = events() + events(run="22222222-2222-4222-8222-222222222222", offset=10_000_000_000)[1:]
        result, data, report, _ = self.run_replay(rows, runs=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["eligibleRuns"], 2)
        self.assertEqual(data["medianAssetsPerSecond"], 1.0)
        self.assertEqual(data["runs"][0]["stagingFraction"], 0.75)
        self.assertEqual(data["runs"][0]["variantCompletions"], 3)
        self.assertEqual(data["runs"][0]["stalls"], {"over16": 1, "over33": 1, "over100": 1})
        self.assertIn("first-to-last-completion", report)
        self.assertIn("75.0%", report)

    def test_missing_stall_sequence_is_incomplete_not_a_clean_capture(self):
        rows = [row for row in events() if row["type"] != "turn"]
        result, data, _, _ = self.run_replay(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data["eligibleRuns"], 0)
        self.assertFalse(data["runs"][0]["throughputValid"])

    def test_cancelled_or_unsealed_runs_are_not_baselines(self):
        for rows in [events(invalid=True), events()[:-1]]:
            with self.subTest(rows=rows[-1]["type"]):
                result, data, _, _ = self.run_replay(rows)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(data["eligibleRuns"], 0)

    def test_missing_staging_does_not_erase_valid_throughput(self):
        rows = events()
        del next(row for row in rows if row["type"] == "jobEnd")["stageNs"]
        result, data, report, _ = self.run_replay(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(data["runs"][0]["throughputValid"])
        self.assertFalse(data["runs"][0]["stagingValid"])
        self.assertIsNone(data["runs"][0]["stagingFraction"])
        self.assertIn("unavailable", report)

    def test_unrelated_session_and_process_do_not_contaminate_capture(self):
        noise = dict(events()[4], session="ffffffff-ffff-4fff-8fff-ffffffffffff")
        other = dict(events()[4], pid=99, seq=999)
        result, data, _, _ = self.run_replay([noise] + events()[:4] + [other] + events()[4:])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runs"][0]["variantCompletions"], 3)

    def test_duplicate_events_and_impossible_wall_are_visible(self):
        for mutation in ["duplicate", "stage-over-wall", "negative"]:
            rows = events()
            if mutation == "duplicate":
                rows.insert(5, rows[4])
            else:
                row = next(row for row in rows if row["type"] == "jobEnd")
                row["stageNs"] = 9_000_000_000 if mutation == "stage-over-wall" else -1
            result, data, _, _ = self.run_replay(rows)
            self.assertIsNotNone(data)
            if mutation == "duplicate":
                self.assertNotEqual(result.returncode, 0)
            else:
                self.assertFalse(data["runs"][0]["stagingValid"])

    def test_output_directory_is_never_overwritten(self):
        result, data, _, kept = self.run_replay(events(), existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(kept, "kept")
        self.assertIsNone(data)

    def test_raw_messages_and_unknown_fields_are_not_saved_in_report(self):
        rows = events()
        rows[3]["filename"] = "/private/Photos/secret.HEIC"
        result, data, report, _ = self.run_replay(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("secret.HEIC", json.dumps(data) + report)

    def test_dropped_messages_or_malformed_events_fail_visibly(self):
        for extra in [{"dropped": 1}, {"schema": 1, "session": SESSION, "type": "completion", "pid": 42}]:
            result, data, _, _ = self.run_replay(events()[:3] + [extra] + events()[3:])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(data["eligibleRuns"], 0)

    def test_help_explains_user_actions_and_never_starts_exports(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("disposable destination", result.stdout)
        self.assertIn("--app", result.stdout)
        self.assertIn("--replay", result.stdout)


if __name__ == "__main__":
    unittest.main()
