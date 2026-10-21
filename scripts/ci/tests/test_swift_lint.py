"""Run the real SwiftLint config against disposable app and test source trees."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SWIFTLINT = shutil.which("swiftlint")
CLEAN = "struct LintFixture {\n  let value = 1\n}\n"
VIOLATION = "struct LintFixture {\n  let value:Int = 1\n}\n"


@unittest.skipUnless(SWIFTLINT, "SwiftLint is optional locally; CI installs and verifies it before guard tests")
class SwiftLintScopeTests(unittest.TestCase):
    def run_lint(self, app_source=CLEAN, test_source=CLEAN):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copyfile(ROOT / ".swiftlint.yml", root / ".swiftlint.yml")
            for directory, source in [("photo-export", app_source), ("photo-exportTests", test_source),
                                      ("photo-exportUITests", VIOLATION)]:
                (root / directory).mkdir()
                (root / directory / "Fixture.swift").write_text(source)
            return subprocess.run(
                [SWIFTLINT, "lint", "--strict", "--quiet", "--config", ".swiftlint.yml",
                 "--cache-path", str(root / "cache")], cwd=root,
                env={**os.environ, "HOME": str(root)}, capture_output=True, text=True)

    def test_clean_app_and_tests_pass_without_including_ui_test_templates(self):
        result = self.run_lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_app_violation_fails(self):
        result = self.run_lint(app_source=VIOLATION)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("photo-export/Fixture.swift", result.stdout)
        self.assertIn("(colon)", result.stdout)

    def test_test_source_violation_fails(self):
        result = self.run_lint(test_source=VIOLATION)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("photo-exportTests/Fixture.swift", result.stdout)
        self.assertIn("(colon)", result.stdout)


if __name__ == "__main__":
    unittest.main()
