"""The log parser measures distinct assets within each captured completion window."""

import pathlib
import json
import sys
import tempfile
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/perf/collect_export_measurements.py"
FIXTURES = ROOT / "scripts/ci/fixtures/throughput"


class ThroughputFromLogTests(unittest.TestCase):
    def run_parser(self, *args, text=None):
        with tempfile.TemporaryDirectory() as folder:
            output = pathlib.Path(folder) / "report"
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--completion-log", *map(str, args or ["-"]),
                 "--cache-state", "cold", "--label", "fixture", "--output", str(output)],
                input=text, capture_output=True, text=True, check=False,
            )
            result.data = json.loads((output / "results.json").read_text())
            result.report = (output / "summary.md").read_text()
            result.archive = (output / "events.ndjson").read_text()
            return result

    def test_committed_runs_deduplicate_variants_without_aggregation(self):
        result = self.run_parser(FIXTURES / "two-assets.log", FIXTURES / "four-assets.log")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["assetsPerSecond"] for r in result.data["runs"]], [1.0, 2.0])
        self.assertEqual([r["assets"] for r in result.data["runs"]], [2, 4])
        self.assertNotIn("medianAssetsPerSecond", result.data)
        self.assertNotIn("stagingFraction", result.data)
        self.assertTrue(all(r["stagingFraction"] is None for r in result.data["runs"]))
        self.assertNotIn("/scratch", json.dumps(result.data) + result.report + result.archive)

    def test_stdin_reports_window_and_variant_count(self):
        result = self.run_parser(text=(FIXTURES / "two-assets.log").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("first-to-last-completion", result.report)
        self.assertEqual(result.data["runs"][0]["variantCompletions"], 3)
        self.assertEqual(result.data["runs"][0]["completionWindowSeconds"], 2.0)

    def test_unusable_captures_fail_with_actionable_error(self):
        first = (FIXTURES / "two-assets.log").read_text().splitlines()[1]
        for text, error in [
            ("", "no Exported completion lines"),
            (first, "at least two distinct completion timestamps"),
            (first.replace("2026-10-23", "bad-date"), "invalid completion timestamp"),
            (first.rsplit(" asset:", 1)[0], "missing asset identifier"),
            (first.replace("A/L0/001", "<private>"), "private asset identifier"),
            (first + "\n" + first.replace("12:00:00.000000+0300", "12:00:01.000000"),
             "mixed offset-free and offset-aware timestamps"),
        ]:
            with self.subTest(error=error):
                result = self.run_parser(text=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertNotIn("median", result.stdout)

    def test_offsets_are_normalized_across_completion_lines(self):
        capture = (FIXTURES / "two-assets.log").read_text()
        capture = capture.replace("12:00:01.000000+0300", "09:00:01.000000Z")
        capture = capture.replace("12:00:02.000000+0300", "10:00:02.000000+01:00")
        result = self.run_parser(text=capture)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.data["runs"][0]["assetsPerSecond"], 1.0)

    def test_asset_suffix_ignores_markers_inside_destination_paths(self):
        lines = (FIXTURES / "two-assets.log").read_text().splitlines()
        lines[1] = lines[1].replace("/scratch/", "/scratch asset: photos/")
        lines[2] = lines[2].replace("/scratch/", "/scratch asset: originals/")
        result = self.run_parser(text="\n".join(lines))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.data["runs"][0]["assetsPerSecond"], 1.0)



if __name__ == "__main__":
    unittest.main()
