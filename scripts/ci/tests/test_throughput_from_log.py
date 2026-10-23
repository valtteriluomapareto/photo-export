"""The log parser measures distinct assets within each captured completion window."""

import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/perf/throughput-from-log.sh"
FIXTURES = ROOT / "scripts/ci/fixtures/throughput"


class ThroughputFromLogTests(unittest.TestCase):
    def run_parser(self, *args, text=None):
        return subprocess.run(
            ["bash", str(SCRIPT), *map(str, args)],
            input=text, capture_output=True, text=True, check=False,
        )

    def test_committed_runs_deduplicate_variants_and_report_median(self):
        result = self.run_parser(FIXTURES / "two-assets.log", FIXTURES / "four-assets.log")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assets=2 seconds=2.000000 assets/sec=1.000000", result.stdout)
        self.assertIn("assets=4 seconds=2.000000 assets/sec=2.000000", result.stdout)
        self.assertIn("median assets/sec=1.500000 runs=2", result.stdout)

    def test_verbose_stdin_reports_window_and_variant_count(self):
        result = self.run_parser("--verbose", text=(FIXTURES / "two-assets.log").read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("window=first-to-last-completion", result.stdout)
        self.assertIn("variant-completions=3", result.stdout)
        self.assertIn("ignored-lines=1", result.stdout)

    def test_unusable_captures_fail_with_actionable_error(self):
        first = (FIXTURES / "two-assets.log").read_text().splitlines()[1]
        for text, error in [
            ("", "no Exported completion lines"),
            (first, "at least two distinct completion timestamps"),
            (first.replace("2026-10-23", "bad-date"), "invalid completion timestamp"),
            (first.rsplit(" asset:", 1)[0], "missing asset identifier"),
            (first.replace("A/L0/001", "<private>"), "private asset identifier"),
        ]:
            with self.subTest(error=error):
                result = self.run_parser(text=text)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertNotIn("median", result.stdout)

    def test_asset_suffix_ignores_markers_inside_destination_paths(self):
        lines = (FIXTURES / "two-assets.log").read_text().splitlines()
        lines[1] = lines[1].replace("/scratch/", "/scratch asset: photos/")
        lines[2] = lines[2].replace("/scratch/", "/scratch asset: originals/")
        result = self.run_parser(text="\n".join(lines))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("assets=2 seconds=2.000000 assets/sec=1.000000", result.stdout)

    def test_help_describes_one_file_per_run_and_denominator(self):
        result = self.run_parser("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("one file per export run", result.stdout)
        self.assertIn("first-to-last", result.stdout)


if __name__ == "__main__":
    unittest.main()
