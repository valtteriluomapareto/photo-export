"""Version preflight fixtures execute the same validator used by both releases."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


VALIDATOR = pathlib.Path(__file__).resolve().parents[1] / "check-version.py"


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = pathlib.Path(self.temporary.name) / "project.pbxproj"

    def run_validator(self, assignments, expected=None):
        self.project.write_text("\n".join(assignments) + "\n")
        command = [sys.executable, str(VALIDATOR), str(self.project)]
        if expected is not None:
            command += ["--expected", expected]
        return subprocess.run(command, capture_output=True, text=True)

    def test_stable_and_existing_prerelease_syntax_pass(self):
        for version in ("1.6.5", "1.7.0-beta.1", "1.7.0-RC.1", "1.7.0-preview..1"):
            with self.subTest(version=version):
                result = self.run_validator([f"MARKETING_VERSION = {version};"] * 6)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Version guard passed: {version} (6 assignments)", result.stdout)

    def test_nonfirst_version_drift_fails(self):
        result = self.run_validator(["MARKETING_VERSION = 1.6.5;", "MARKETING_VERSION = 1.6.4;"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("MARKETING_VERSION differs across configurations", result.stderr)

    def test_nonfirst_empty_malformed_or_invalid_assignments_fail(self):
        for assignment in (
            "MARKETING_VERSION = ;", "MARKETING_VERSION = 1.6.5",
            "MARKETING_VERSION: 1.6.5;", "MARKETING_VERSION = 1.6;",
            "MARKETING_VERSION = 1.6.5_beta;",
        ):
            with self.subTest(assignment=assignment):
                result = self.run_validator(["MARKETING_VERSION = 1.6.5;", assignment])
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Version guard input error:", result.stderr)
                self.assertIn("project.pbxproj:2:", result.stderr)

    def test_missing_assignments_fail(self):
        result = self.run_validator(["CURRENT_PROJECT_VERSION = 1;"])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no MARKETING_VERSION assignments", result.stderr)

    def test_missing_project_fails(self):
        result = subprocess.run([sys.executable, str(VALIDATOR), str(self.project)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("Version guard input error:", result.stderr)
        self.assertIn("project.pbxproj", result.stderr)

    def test_tag_match_is_optional_and_compares_the_full_version(self):
        assignments = ["MARKETING_VERSION = 1.7.0-beta.1;"] * 6
        matched = self.run_validator(assignments, expected="1.7.0-beta.1")
        self.assertEqual(matched.returncode, 0, matched.stderr)
        mismatched = self.run_validator(assignments, expected="1.7.0")
        self.assertEqual(mismatched.returncode, 1, mismatched.stderr)
        self.assertIn("expected 1.7.0 but project is 1.7.0-beta.1", mismatched.stderr)
        without_tag = self.run_validator(assignments)
        self.assertEqual(without_tag.returncode, 0, without_tag.stderr)


if __name__ == "__main__":
    unittest.main()
