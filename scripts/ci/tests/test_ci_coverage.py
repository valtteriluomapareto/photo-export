"""Coverage summaries use real xccov file counters and advisory CLI behavior."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "coverage_summary.py"
FIXTURE = Path(__file__).with_name("fixtures") / "xccov-app-report.json"
SOURCE = Path("/fixture/workspace/photo-export/photo-export")
spec = importlib.util.spec_from_file_location("coverage_summary", SCRIPT)
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


def entry(path, covered=1, executable=1):
    return {"path": str(SOURCE / path), "coveredLines": covered, "executableLines": executable}


def report(*files):
    return {"targets": [{"name": "Photo Export.app", "files": list(files)}]}


class SummaryTests(unittest.TestCase):
    def render(self, data, outcome="success"):
        return coverage.render_report(data, SOURCE, test_outcome=outcome)

    def test_real_report_totals_are_independent_app_counts(self):
        data = json.loads(FIXTURE.read_text())
        result = self.render(data)
        self.assertIn("111 measured Swift source files", result)
        for area, covered, executable in [
            ("App", 1018, 1270), ("AutoSync", 1670, 1761), ("Destination", 871, 1018),
            ("Export", 4589, 5347), ("Helpers", 85, 87), ("Models", 914, 1030),
            ("Other", 261, 321), ("PhotoLibrary", 1699, 2766), ("Protocols", 102, 105),
            ("Records", 1827, 1933), ("ViewModels", 245, 249), ("Views", 2548, 8521),
            ("Total", 15829, 24408),
        ]:
            self.assertIn(f"| {area} | {covered} | {executable} |", result)
        self.assertIn("| Total | 15829 | 24408 | 64.9% |", result)
        self.assertNotIn("45487", result)
        self.assertNotIn("29658", result)

    def test_weighting_uses_lines_not_average_file_percentages(self):
        data = report(entry("Export/a.swift", 1, 1), entry("Export/b.swift", 0, 9))
        self.assertIn("| Export | 1 | 10 | 10.0% |", self.render(data))

    def test_exact_target_and_source_boundary_exclude_tests_and_generated_files(self):
        data = report(entry("Export/real.swift", 2, 4),
                      entry("../photo-exportTests/not-app.swift", 900, 900),
                      entry("../../build/DerivedSources/GeneratedAssetSymbols.swift", 800, 800))
        data['targets'].append({"name": "photo-exportTests.xctest", "files": [entry("Export/test-copy.swift", 700, 700)]})
        self.assertIn("| Total | 2 | 4 | 50.0% |", self.render(data))
        self.assertIn("1 measured Swift source files", self.render(data))
        self.assertNotIn("GeneratedAssetSymbols", self.render(data))

    def test_zero_lines_and_unlisted_areas_are_not_zero_percent(self):
        result = self.render(report(entry("Records/types.swift", 0, 0)))
        self.assertIn("| Records | 0 | 0 | n/a |", result)
        self.assertIn("| Total | 0 | 0 | n/a |", result)
        self.assertNotIn("Records/types.swift</code>", result)

    def test_low_file_order_and_markdown_escaping_are_deterministic(self):
        data = report(entry("Export/z.swift", 0, 10), entry("Export/a|<tag>.swift", 0, 20),
                      entry("Records/c.swift", 1, 2), entry("Export/zero.swift", 0, 0))
        first = self.render(data)
        data['targets'][0]['files'].reverse()
        self.assertEqual(self.render(data), first)
        self.assertLess(first.index("a&#124;&lt;tag&gt;.swift"), first.index("z.swift"))
        self.assertNotIn("<tag>", first)
        self.assertNotIn("zero.swift", first)

    def test_invalid_counts_and_duplicate_normalized_sources_fail(self):
        for covered, executable in [(-1, 2), (True, 2), (1.5, 2), (3, 2), (0, -1), (0, False)]:
            with self.subTest(covered=covered, executable=executable), self.assertRaises(ValueError):
                self.render(report(entry("Export/a.swift", covered, executable)))
        missing = entry("Export/a.swift")
        del missing['coveredLines']
        with self.assertRaises(ValueError): self.render(report(missing))
        with self.assertRaises(ValueError):
            self.render(report(entry("Export/a.swift"), entry("Export/../Export/a.swift")))

    def test_missing_ambiguous_or_malformed_target_data_fails(self):
        good = report(entry("Export/a.swift"))
        for data in [{}, {"targets": []}, {"targets": "wrong"},
                     {"targets": [good['targets'][0], copy.deepcopy(good['targets'][0])]},
                     report(entry("../../not-app.swift"))]:
            with self.subTest(data=data), self.assertRaises(ValueError): self.render(data)

    def test_failed_cancelled_skipped_runs_are_explicit_partial_results(self):
        for outcome in ["failure", "cancelled", "skipped", "unknown"]:
            with self.subTest(outcome=outcome):
                result = self.render(report(entry("Export/a.swift")), outcome)
                self.assertIn(f"Partial results: test outcome = {outcome}", result)
                self.assertIn("| Total | 1 | 1 | 100.0% |", result)
        self.assertNotIn("Partial results", self.render(report(entry("Export/a.swift"))))


class AdvisoryCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_cli(self, *args, env=None):
        child_environment = dict(os.environ if env is None else env)
        child_environment.pop("GITHUB_STEP_SUMMARY", None)
        return subprocess.run([sys.executable, "-B", str(SCRIPT), "--source-root", str(SOURCE), *args],
                              capture_output=True, text=True, env=child_environment)

    def test_ci_summary_environment_is_isolated_and_default_is_supported(self):
        parent_summary = self.root / "parent-summary.md"
        parent_summary.write_text("real CI summary must stay unchanged")
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(parent_summary)}):
            result = self.run_cli("--report-json", str(FIXTURE))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(parent_summary.read_text(), "real CI summary must stay unchanged")
        fixture_summary = self.root / "fixture-summary.md"
        environment = dict(os.environ, GITHUB_STEP_SUMMARY=str(fixture_summary))
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--source-root", str(SOURCE),
                                 "--report-json", str(FIXTURE)], capture_output=True, text=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture_summary.read_text(), result.stdout)

    def test_log_and_summary_match_and_append(self):
        summary = self.root / "summary.md"
        summary.write_text("Existing summary\n")
        result = self.run_cli("--report-json", str(FIXTURE), "--summary-file", str(summary), "--test-outcome", "failure")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Partial results: test outcome = failure", result.stdout)
        self.assertEqual(summary.read_text(), "Existing summary\n" + result.stdout)

    def test_unavailable_or_malformed_results_stay_advisory_and_explain_why(self):
        malformed = self.root / "malformed.json"
        malformed.write_text("not json")
        for args in [("--report-json", str(malformed)), ("--result-bundle", str(self.root / "missing.xcresult"))]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Coverage unavailable:", result.stdout)
                self.assertNotIn("| Total |", result.stdout)
        bundle = self.root / "exists.xcresult"
        bundle.mkdir()
        binary = self.root / "xcrun"
        binary.write_text("#!/bin/sh\necho 'fixture xccov failure' >&2\nexit 3\n")
        binary.chmod(0o755)
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""))
        result = self.run_cli("--result-bundle", str(bundle), env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Coverage unavailable:", result.stdout)
        self.assertIn("xccov", result.stdout)

    def test_append_error_keeps_log_evidence_and_does_not_fail(self):
        result = self.run_cli("--report-json", str(FIXTURE), "--summary-file", str(self.root / "absent" / "summary.md"))
        self.assertEqual(result.returncode, 0)
        self.assertIn("| Total | 15829 | 24408 |", result.stdout)
        self.assertIn("Could not append coverage summary", result.stderr)


if __name__ == "__main__":
    unittest.main()
