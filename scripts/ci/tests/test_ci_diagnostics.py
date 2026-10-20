"""Retain only current-run app crash evidence without hiding the original test failure."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_ci_logs import block, ROOT, run_line, WORKFLOW

SCRIPT = Path(__file__).resolve().parents[1] / "collect_test_diagnostics.py"
spec = importlib.util.spec_from_file_location("test_diagnostics", SCRIPT)
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.marker = self.root / "test-start.marker"
        self.marker.touch()
        os.utime(self.marker, (1000, 1000))
        self.bundle = self.root / "TestResults.xcresult"
        self.bundle.mkdir()
        self.reports = self.root / "reports"
        self.reports.mkdir()
        self.output = self.root / "TestDiagnostics"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        xcrun = self.bin / "xcrun"
        xcrun.write_text(f"#!{sys.executable}\n" + '''import os, pathlib, sys
args = sys.argv[1:]
assert args[:3] == ["xcresulttool", "export", "diagnostics"], args
if args[3:] == ["--help"]: sys.exit(0)
assert args[3] == "--path" and args[5] == "--output-path", args
output = pathlib.Path(args[6]); output.mkdir(parents=True, exist_ok=True)
(output / "exported.txt").write_text("xcresult diagnostic fixture")
print("export fixture output")
sys.exit(int(os.environ.get("DIAGNOSTIC_EXPORT_EXIT", "0")))
''')
        xcrun.chmod(0o755)
        self.environment = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')

    def report(self, name="Photo Export-2026-10-19-000001.ips", timestamp=1000):
        path = self.reports / name
        path.write_text("complete crash evidence")
        os.utime(path, (timestamp, timestamp))
        return path

    def collect(self):
        with patch.dict(os.environ, self.environment, clear=True):
            result = diagnostics.collect(self.marker, self.bundle, self.reports, self.output)
        self.assertEqual(json.loads((self.output / "manifest.json").read_text()), result)
        return result

    def test_current_boundary_and_actual_report_name_exclude_stale_unrelated_and_links(self):
        current = self.report()
        crash = self.report("Photo Export-2026-10-19-000002.crash", 1001)
        self.report("Photo Export-2026-10-19-000003.ips", 999.999)
        self.report("Photo Export Helper-2026-10-19-000004.ips")
        self.report("Photo Export-unrelated.ips")
        self.report("Other App-2026-10-19-000005.ips")
        (self.reports / "Photo Export-2026-10-19-000006.ips").symlink_to(current)
        (self.reports / "Photo Export-2026-10-19-000007.ips").mkdir()
        result = self.collect()
        self.assertEqual(set(result["copied"]), {current.name, crash.name})
        self.assertEqual(result["selected"], 2)
        self.assertEqual(result["errors"], [])
        for source in [current, crash]:
            self.assertEqual((self.output / "crashes" / source.name).read_bytes(), source.read_bytes())
        self.assertTrue((self.output / "xcresult" / "exported.txt").is_file())

    def test_missing_directory_and_bundle_leave_explicit_empty_manifest(self):
        self.bundle.rmdir()
        self.reports.rmdir()
        result = self.collect()
        self.assertEqual(result["copied"], [])
        self.assertEqual(result["selected"], 0)
        self.assertTrue(any("result bundle" in error for error in result["errors"]))
        self.assertTrue(any("report directory" in error for error in result["errors"]))

    def test_missing_directory_or_symlink_marker_never_collects_reports(self):
        self.report()
        self.marker.unlink()
        for kind in ["missing", "directory", "symlink"]:
            with self.subTest(marker=kind):
                self.output = self.root / kind
                if kind == "directory":
                    self.marker.mkdir()
                elif kind == "symlink":
                    self.marker.rmdir()
                    self.marker.symlink_to(self.reports / "Photo Export-2026-10-19-000001.ips")
                with patch.object(diagnostics.subprocess, "run") as export:
                    result = self.collect()
                self.assertEqual(result["copied"], [])
                self.assertTrue(any("marker" in error for error in result["errors"]))
                export.assert_not_called()

    def test_export_timeout_still_copies_a_readable_report(self):
        source = self.report()
        with patch.object(diagnostics.subprocess, "run", side_effect=subprocess.TimeoutExpired("xcrun", 45)):
            result = self.collect()
        self.assertEqual(result["copied"], [source.name])
        self.assertTrue(any("timed out" in error for error in result["errors"]))

    def test_partial_copy_is_removed_and_other_reports_are_retained(self):
        failed = self.report()
        successful = self.report("Photo Export-2026-10-19-000002.ips")
        copy = shutil.copy2

        def copy_fixture(source, target):
            if source.name == failed.name:
                target.write_text("partial")
                raise OSError("fixture copy error")
            return copy(source, target)

        with patch.object(diagnostics.shutil, "copy2", side_effect=copy_fixture):
            result = self.collect()
        self.assertEqual(result["selected"], 2)
        self.assertEqual(result["copied"], [successful.name])
        self.assertTrue(any("fixture copy error" in error for error in result["errors"]))
        self.assertEqual([path.name for path in (self.output / "crashes").iterdir()], [successful.name])

    def test_actual_cli_keeps_crash_when_xcresult_export_fails(self):
        source = self.report()
        result = subprocess.run([
            sys.executable, "-B", str(SCRIPT), "--since", str(self.marker),
            "--result-bundle", str(self.bundle), "--crash-reports", str(self.reports),
            "--output", str(self.output)
        ], env=dict(self.environment, DIAGNOSTIC_EXPORT_EXIT="23"), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["export_exit"], 23)
        self.assertEqual(manifest["copied"], [source.name])
        self.assertIn("export fixture output", (self.output / "export.log").read_text())

    def test_actual_workflow_failure_keeps_status_and_workspace_artifact_layout(self):
        source = WORKFLOW.read_text()
        self.assertIn("failure() && steps.unit-tests.outcome == 'failure'", source)
        probe = source.split("      - name: Check xcresult diagnostics export support", 1)[1]
        self.assertIn("continue-on-error: true", probe.split("      - name:", 1)[0])
        start = source.index("      - name: Collect test process diagnostics")
        end = source.index("      - name:", start + 10)
        step = source[start:end]
        self.assertIn("continue-on-error: true", step)
        self.assertIn("timeout-minutes: 2", step)
        upload = source[source.index("      - name: Upload test results"):]
        for path in ["TestResults.xcresult", "debug-build.log", "test.log", "release-build.log", "TestDiagnostics/"]:
            self.assertIn(path, upload)
        unit_step = source[source.index("      - name: Run Unit Tests (Debug, with coverage)"):]
        unit_step = unit_step[:unit_step.index("      - name:", 10)]
        self.assertIn("id: unit-tests", unit_step)
        self.assertEqual(run_line(WORKFLOW, "Run Unit Tests (Debug, with coverage)"),
                         "bash scripts/ci/run-unit-tests.sh")
        unit_script = (ROOT / "scripts/ci/run-unit-tests.sh").read_text()
        self.assertLess(unit_script.index("touch test-start.marker"), unit_script.index("xcodebuild"))
        stub = self.bin / "xcodebuild"
        stub.write_text('#!/bin/sh\nmkdir -p TestResults.xcresult\necho "fixture test failure"\nexit 65\n')
        stub.chmod(0o755)
        unit = subprocess.run(["bash", str(ROOT / "scripts/ci/run-unit-tests.sh")],
                              cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=10)
        self.assertEqual(unit.returncode, 65)
        self.assertTrue((self.root / "test-start.marker").is_file())
        self.assertIn("fixture test failure", (self.root / "test.log").read_text())
        current = self.report(timestamp=(self.root / "test-start.marker").stat().st_mtime)
        target = self.root / "scripts/ci/collect_test_diagnostics.py"
        target.parent.mkdir(parents=True)
        shutil.copy2(SCRIPT, target)
        # Execute the actual step with only its optional source overridden to this fixture.
        import shlex
        script = block("Collect test process diagnostics").rstrip() + " --crash-reports " + shlex.quote(str(self.reports))
        diagnostic = subprocess.run(["bash", "-e", "-c", script], cwd=self.root,
                                    env=dict(self.environment, DIAGNOSTIC_EXPORT_EXIT="23"),
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
        manifest = json.loads((self.root / "TestDiagnostics/manifest.json").read_text())
        self.assertEqual(manifest["export_exit"], 23)
        self.assertEqual(manifest["copied"], [current.name])
        self.assertEqual(unit.returncode, 65)


if __name__ == "__main__":
    unittest.main()
