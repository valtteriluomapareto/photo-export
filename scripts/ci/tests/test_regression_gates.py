"""Run the real regression-symbol scanner in disposable repository skeletons."""

import pathlib
import shutil
import subprocess
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
GUARD = CI_DIRECTORY / "check-regression-gates.sh"
SOURCES = {
    "AutoSyncSeamCharacterizationTests.swift": "struct AutoSyncSeamCharacterizationTests {}\n",
    "ExportQueueStateSnapshotTests.swift": (
        "struct ExportQueueStateSnapshotTests {\n"
        "  func teardownQueue_synchronouslyClearsManagerMirrors() {}\n"
        "  func pauseResumeCancelStateSnapshot_canonicalTransitions() {}\n}\n"
    ),
    "ScreenshotPhotoLibraryServiceOverridesTests.swift": "struct ScreenshotPhotoLibraryServiceOverridesTests {}\n",
    "ImportIdempotencyTests.swift": "struct ImportIdempotencyTests {}\n",
    "ExportManagerRunExportTests.swift": (
        "struct ExportManagerRunExportTests {\n"
        "  func autoSyncRunFilterAlreadyExportedBeforeRetryCheck() {}\n}\n"
    ),
}


class RegressionGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        ci = self.root / "scripts/ci"
        ci.mkdir(parents=True)
        shutil.copy(GUARD, ci / GUARD.name)
        shutil.copy(CI_DIRECTORY / "swift_source.py", ci / "swift_source.py")
        self.tests = self.root / "photo-exportTests"
        self.tests.mkdir()
        for name, source in SOURCES.items():
            (self.tests / name).write_text(source)
        self.guard = ci / GUARD.name

    def run_guard(self):
        return subprocess.run(["bash", str(self.guard)], capture_output=True, text=True)

    def assert_violation(self, diagnostic):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(diagnostic, result.stdout)

    def test_clean_tree_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("All regression-gate symbols present", result.stdout)

    def test_missing_file_fails(self):
        (self.tests / "ImportIdempotencyTests.swift").unlink()
        self.assert_violation("MISSING FILE: photo-exportTests/ImportIdempotencyTests.swift")

    def test_renamed_suite_does_not_match_required_prefix(self):
        path = self.tests / "ImportIdempotencyTests.swift"
        path.write_text("struct ImportIdempotencyTestsExtra {}\n")
        self.assert_violation("MISSING SYMBOL: 'struct ImportIdempotencyTests'")

    def test_renamed_method_does_not_match_required_prefix(self):
        path = self.tests / "ExportManagerRunExportTests.swift"
        path.write_text(path.read_text().replace("BeforeRetryCheck()", "BeforeRetryCheckExtra()"))
        self.assert_violation("MISSING SYMBOL: 'func autoSyncRunFilterAlreadyExportedBeforeRetryCheck'")

    def test_commented_and_quoted_declarations_do_not_count(self):
        path = self.tests / "ImportIdempotencyTests.swift"
        for source in (
            "// struct ImportIdempotencyTests {}\n",
            "/*\nstruct ImportIdempotencyTests {}\n*/\n",
            'let documentation = "struct ImportIdempotencyTests {}"\n',
        ):
            with self.subTest(source=source):
                path.write_text(source)
                self.assert_violation("MISSING SYMBOL: 'struct ImportIdempotencyTests'")

    def test_missing_method_fails_even_when_suite_remains(self):
        path = self.tests / "ExportManagerRunExportTests.swift"
        path.write_text("struct ExportManagerRunExportTests {}\n")
        self.assert_violation("MISSING SYMBOL: 'func autoSyncRunFilterAlreadyExportedBeforeRetryCheck'")


if __name__ == "__main__":
    unittest.main()
