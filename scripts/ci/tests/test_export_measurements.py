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
        dict(type="runBegin", automatic=False), dict(type="enqueued", count=2),
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
    def run_replay(self, rows, runs=1, existing=False, cache_state="unknown"):
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
                 "--label", "nas", "--runs", str(runs), "--output", str(output)]
                + (["--cache-state", cache_state] if cache_state else []),
                text=True, capture_output=True, check=False)
            data = json.loads((output / "results.json").read_text()) if (output / "results.json").exists() else None
            report = (output / "summary.md").read_text() if (output / "summary.md").exists() else ""
            kept = ((output / "keep").read_text() if (output / "keep").exists()
                    else (output / "events.ndjson").read_text() if (output / "events.ndjson").exists() else None)
            return result, data, report, kept

    def test_each_run_is_reported_without_combined_throughput_or_staging(self):
        second = events(run="22222222-2222-4222-8222-222222222222", offset=10_000_000_000)[1:]
        for row in second:
            if row["type"] == "jobEnd":
                row["stageNs"] = 0
        result, data, report, _ = self.run_replay(events() + second, runs=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("medianAssetsPerSecond", data)
        self.assertNotIn("stagingFraction", data)
        self.assertNotIn("Median assets/s", report)
        self.assertNotIn("Combined staging", report)
        self.assertEqual([row["stagingFraction"] for row in data["runs"]], [0.75, 0.0])

    def test_heic_setting_comes_from_the_run_not_the_scenario_label(self):
        for enabled in [False, True]:
            rows = events()
            rows[1]["convertHEICToJPEG"] = enabled
            result, data, _, _ = self.run_replay(rows)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIs(data["runs"][0].get("heicConversion"), enabled)

    def test_short_warm_window_is_reported_but_unsuitable_for_comparison(self):
        rows = events()
        rows[1]["convertHEICToJPEG"] = True
        result, data, report, _ = self.run_replay(rows, cache_state="warm")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runs"][0]["cacheState"], "warm")
        self.assertFalse(data["runs"][0]["comparisonSuitable"])
        self.assertIn("30", report)
        # The same denominator with 30 seconds of completions is suitable.
        rows[-3]["atNs"] = 31_000_000_000
        result, data, _, _ = self.run_replay(rows, cache_state="warm")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(data["runs"][0]["comparisonSuitable"])

    def test_numeric_capture_deduplicates_variants_and_times_producers(self):
        result, data, report, _ = self.run_replay(events())
        self.assertEqual(result.returncode, 0, result.stderr)
        row = data["runs"][0]
        self.assertEqual(row["assetsPerSecond"], 1.0)
        self.assertEqual(row["stagingFraction"], 0.75)
        self.assertEqual(row["variantCompletions"], 3)
        self.assertEqual(row["stalls"], {"over16": 1, "over33": 1, "over100": 1})
        self.assertIn("first-to-last-completion", report)
        self.assertIn("75.0%", report)
        self.assertIsNone(row["heicConversion"])
        self.assertEqual(row["cacheState"], "unknown")
        self.assertFalse(row["comparisonSuitable"])

    def test_removed_sequence_and_unused_events_are_not_required(self):
        rows = [row for row in events() if row["type"] not in {"enqueued", "jobBegin"}]
        for row in rows:
            row.pop("seq", None)
        result, data, _, _ = self.run_replay(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runs"][0]["assetsPerSecond"], 1.0)

    def test_missing_staging_keeps_throughput_and_reports_staging_unavailable(self):
        for value in [None, -1, 9_000_000_000]:
            rows = events()
            next(row for row in rows if row["type"] == "jobEnd")["stageNs"] = value
            result, data, report, _ = self.run_replay(rows)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(data["runs"][0]["assetsPerSecond"], 1.0)
            self.assertIsNone(data["runs"][0]["stagingFraction"])
            self.assertIn("unavailable", report)

    def test_interrupted_capture_keeps_observed_metrics_without_finishing_sample_count(self):
        result, data, _, _ = self.run_replay(events()[:-1])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(data["partial"])
        self.assertFalse(data["runs"][0]["finished"])
        self.assertEqual(data["runs"][0]["assetsPerSecond"], 1.0)

    def test_unrelated_session_and_process_do_not_contaminate_capture(self):
        noise = dict(events()[4], session="ffffffff-ffff-4fff-8fff-ffffffffffff")
        other = dict(events()[4], pid=99)
        result, data, _, _ = self.run_replay([noise] + events()[:4] + [other] + events()[4:])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(data["runs"][0]["variantCompletions"], 3)

    def test_output_directory_is_never_overwritten(self):
        result, data, _, kept = self.run_replay(events(), existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(kept, "kept")
        self.assertIsNone(data)

    def test_raw_messages_and_unknown_fields_are_not_saved_in_report(self):
        rows = events()
        rows[3]["filename"] = "/private/Photos/secret.HEIC"
        result, data, report, archive = self.run_replay(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("secret.HEIC", json.dumps(data) + report + archive)
        next(row for row in rows if row["type"] == "completion")["asset"] = "private-Photos-identifier"
        result, data, report, archive = self.run_replay(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private-Photos-identifier", json.dumps(data) + report + archive)

    def test_dropped_messages_are_reported_and_survive_replay(self):
        result, data, _, archive = self.run_replay(events() + [{"dropped": 1}])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(data["captureErrors"])
        replay = [json.loads(line) for line in archive.splitlines()]
        result, data, _, _ = self.run_replay(replay)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(data["captureErrors"])

    def test_help_explains_user_actions_and_one_file_per_legacy_run(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("disposable destination", result.stdout)
        self.assertIn("--completion-log", result.stdout)
        self.assertIn("one file per export run", result.stdout)
        self.assertIn("--cache-state", result.stdout)

    def test_automatic_runs_do_not_satisfy_manual_sample_count(self):
        rows = events()
        rows[1]["automatic"] = True
        result, data, report, _ = self.run_replay(rows)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(data["eligibleRuns"], 0)
        self.assertEqual(data["runs"][0]["assetsPerSecond"], 1.0)
        self.assertIn("excluded", report)



class ExportMeasurementLiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("measurement_collector", SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_real_pipe_buffering_and_owned_child_cleanup(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        import plistlib
        import io
        actual_popen = subprocess.Popen
        children, calls = [], []
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            app = root / "Photo Export.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Photo Export").write_bytes(b"fixture")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Photo Export"}))
            source = root / "fake_log.py"
            source.write_text(
                "import os,json,sys\n"
                "print('Filtering the log data using fixture',flush=True)\n"
                "sys.stdin.readline()\n"
                "rows=json.loads(sys.argv[1])\n"
                "for r in rows: r['pid']=os.getpid()\n"
                "os.write(1,(''.join(json.dumps(r)+'\\n' for r in rows)).encode())\n"
                "sys.stdin.read()\n")
            def popen(command, **kwargs):
                calls.append(command)
                if command[0] == "/usr/bin/log":
                    child = actual_popen([sys.executable, str(source), json.dumps(events())],
                                         stdin=subprocess.PIPE, **kwargs)
                else:
                    child = actual_popen([sys.executable, "-c", "import sys;sys.stdin.read()"],
                                         stdin=subprocess.PIPE)
                children.append(child)
                return child
            def run(command, **kwargs):
                calls.append(command)
                if command[0] == "/usr/bin/pgrep":
                    return SimpleNamespace(returncode=1)
                # Emit every event in one write only after the launch command, exercising buffered-pipe handling.
                children[0].stdin.write(b"launch\n")
                children[0].stdin.flush()
                return SimpleNamespace(returncode=0)
            args = SimpleNamespace(app=app, label="nas", runs=1)
            capture = self.module.Capture(SESSION)
            with patch.object(self.module.subprocess, "Popen", side_effect=popen), \
                 patch.object(self.module.subprocess, "run", side_effect=run):
                self.module.live_capture(args, capture, io.StringIO(), {})
            self.assertEqual(capture.eligible_count(), 1)
            self.assertTrue(all(child.poll() is not None for child in children))
            self.assertEqual(calls[1][0], "/usr/bin/log")
            self.assertIn("--export-measurements", calls[-1])
            self.assertFalse(any("quit" in str(command) for command in calls))
            for child in children:
                if child.stdin:
                    child.stdin.close()

    def test_existing_app_refused_before_log_or_launch(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        import io
        args = SimpleNamespace(app=pathlib.Path("fixture.app"), label="nas", runs=1)
        with patch.object(self.module, "app_metadata", return_value=("Photo Export", {})), \
             patch.object(self.module.subprocess, "run", return_value=SimpleNamespace(returncode=0)), \
             patch.object(self.module.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(ValueError, "already running"):
                self.module.live_capture(args, self.module.Capture(SESSION), io.StringIO(), {})
            popen.assert_not_called()


    def test_interrupted_launch_reaps_only_owned_capture_children(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        import io
        children = [SimpleNamespace(stdout=io.BytesIO(b"Filtering the log data using fixture\n"),
                                    poll=Mock(return_value=None), terminate=Mock(), wait=Mock(), kill=Mock()),
                    SimpleNamespace(poll=Mock(return_value=None), terminate=Mock(), wait=Mock(), kill=Mock())]
        args = SimpleNamespace(app=pathlib.Path("fixture.app"), label="nas", runs=1)
        with patch.object(self.module, "app_metadata", return_value=("Photo Export", {})), \
             patch.object(self.module.subprocess, "run", side_effect=[SimpleNamespace(returncode=1), KeyboardInterrupt]), \
             patch.object(self.module.subprocess, "Popen", side_effect=children):
            with self.assertRaises(KeyboardInterrupt):
                self.module.live_capture(args, self.module.Capture(SESSION), io.StringIO(), {})
        for child in children:
            child.terminate.assert_called_once()
            child.wait.assert_called_once()
            child.kill.assert_not_called()

    def test_log_subscription_failure_never_launches_app(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        import io
        child = SimpleNamespace(stdout=io.BytesIO(b""), poll=Mock(return_value=1),
                                terminate=Mock(), wait=Mock())
        args = SimpleNamespace(app=pathlib.Path("fixture.app"), label="nas", runs=1)
        with patch.object(self.module, "app_metadata", return_value=("Photo Export", {})), \
             patch.object(self.module.subprocess, "run", return_value=SimpleNamespace(returncode=1)) as run, \
             patch.object(self.module.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(ValueError, "no app was launched"):
                self.module.live_capture(args, self.module.Capture(SESSION), io.StringIO(), {})
        self.assertEqual(run.call_count, 1)
        child.wait.assert_called_once()

    def test_build_metadata_does_not_hash_the_app_bundle(self):
        import plistlib
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder) / "Photo Export.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Photo Export", "CFBundleVersion": "42"}))
            executable, metadata = self.module.app_metadata(app)
            self.assertEqual(executable, "Photo Export")
            self.assertEqual(metadata["appBuild"], "42")
            self.assertNotIn("appSHA256", metadata)

    def test_paste_ready_summary_contains_build_and_os_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            capture = self.module.Capture(SESSION)
            for row in events():
                capture.consume(row)
            metadata = {"appVersion": "1.6.6", "appBuild": "42", "appBuildToolchain": "26Z123",
                        "macOS": "26.1"}
            output = pathlib.Path(folder)
            self.module.save_report(output, capture, "nas", 1, metadata)
            report = (output / "summary.md").read_text()
            for value in ["1.6.6", "42", "26Z123", "26.1"]:
                self.assertIn(value, report)


if __name__ == "__main__":
    unittest.main()
