"""Run the real test-scratch guard against disposable test-target skeletons."""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
GUARD = CI_DIRECTORY / "check-test-scratch.py"


class TestScratchGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        ci = self.root / "scripts/ci"
        ci.mkdir(parents=True)
        shutil.copy(GUARD, ci / GUARD.name)
        shutil.copy(CI_DIRECTORY / "swift_source.py", ci / "swift_source.py")
        self.tests = self.root / "photo-exportTests"
        (self.tests / "TestHelpers").mkdir(parents=True)

    def run_guard(self):
        return subprocess.run(
            [sys.executable, "-B", str(self.root / "scripts/ci" / GUARD.name), str(self.root)],
            capture_output=True, text=True)

    def write(self, name, source):
        (self.tests / name).write_text(source)

    def test_scratch_helpers_pass(self):
        self.write(
            "GoodTests.swift",
            "struct GoodTests {\n"
            "  func t() {\n"
            "    let name = TestScratch.suiteName(\"Good\")\n"
            "    let defaults = TestScratch.defaults(suiteName: name)\n"
            "    let root = TestScratch.directory(\"Good\")\n"
            "    let store = ExportRecordStore(baseDirectoryURL: root)\n  }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("stay under TestScratch", result.stdout)

    def test_each_banned_construct_fails(self):
        self.write(
            "LeakyTests.swift",
            "struct LeakyTests {\n"
            "  func t() {\n"
            "    let defaults = UserDefaults(suiteName: name)!\n"
            "    let dir = FileManager.default.temporaryDirectory\n"
            "    let other = NSTemporaryDirectory()\n"
            "    let store = ExportRecordStore()\n"
            "    let collection = CollectionExportRecordStore()\n  }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("LeakyTests.swift:3: named preferences suite", result.stdout)
        self.assertIn("LeakyTests.swift:4: real system folder", result.stdout)
        self.assertIn("LeakyTests.swift:5: real system folder", result.stdout)
        self.assertIn("LeakyTests.swift:6: record store on the real", result.stdout)
        self.assertIn("LeakyTests.swift:7: record store on the real", result.stdout)
        self.assertIn("5 test-scratch problem(s) found.", result.stdout)

    def test_shipping_compositions_fail_unless_allowed(self):
        self.write(
            "CoreTests.swift",
            "struct CoreTests {\n"
            "  func t() {\n"
            "    let core = AppCore(composition: .production())\n"
            "    let shot = AppCore(\n"
            "      composition: .screenshot(windowSize: nil))\n"
            "    let launch = AppComposition\n"
            "      .forLaunch(arguments: [])\n"
            "    let fixture = AppCore(composition: makeTestComposition())\n"
            "    // test-scratch: allow inspects the shipping paths only\n"
            "    let paths = AppComposition.production()\n  }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("CoreTests.swift:3: shipping composition", result.stdout)
        self.assertIn("CoreTests.swift:4: shipping composition", result.stdout)
        self.assertIn("CoreTests.swift:6: shipping composition", result.stdout)
        self.assertIn("3 test-scratch problem(s) found.", result.stdout)

    def test_multi_line_uses_fail_at_their_first_line(self):
        self.write(
            "WrappedTests.swift",
            "struct WrappedTests {\n"
            "  let defaults = UserDefaults(\n"
            "    suiteName: name)!\n"
            "  let other = UserDefaults\n"
            "    .init(suiteName: name)!\n"
            "  let dir = FileManager.default\n"
            "    .temporaryDirectory\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("WrappedTests.swift:2: named preferences suite", result.stdout)
        self.assertIn("WrappedTests.swift:4: named preferences suite", result.stdout)
        self.assertIn("WrappedTests.swift:6: real system folder", result.stdout)
        self.assertIn("3 test-scratch problem(s) found.", result.stdout)

    def test_app_domain_and_system_folders_fail(self):
        self.write(
            "SystemTests.swift",
            "struct SystemTests {\n"
            "  let a = UserDefaults.init(suiteName: name)!\n"
            "  let b = UserDefaults.standard\n"
            "  let c = UserDefaults()\n"
            "  let d = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,\n"
            "    appropriateFor: url, create: true)\n"
            "  let e = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)\n"
            "  let f = fm.urls(for: .cachesDirectory, in: .userDomainMask)\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("SystemTests.swift:2: named preferences suite", result.stdout)
        self.assertIn("SystemTests.swift:3: the app's own preferences domain", result.stdout)
        self.assertIn("SystemTests.swift:4: the app's own preferences domain", result.stdout)
        self.assertIn("SystemTests.swift:5: real system folder", result.stdout)
        self.assertIn("SystemTests.swift:7: real system folder", result.stdout)
        self.assertIn("SystemTests.swift:8: real system folder", result.stdout)
        self.assertIn("6 test-scratch problem(s) found.", result.stdout)

    def test_allow_marker_inside_a_string_does_not_count(self):
        self.write(
            "QuotedMarkerTests.swift",
            "let note = \"// test-scratch: allow - not a comment\"\n"
            "let defaults = UserDefaults.standard\n"
            "let other = UserDefaults()  ; let text = \"test-scratch: allow - quoted\"\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("QuotedMarkerTests.swift:2: the app's own preferences domain", result.stdout)
        self.assertIn("QuotedMarkerTests.swift:3: the app's own preferences domain", result.stdout)

    def test_allow_marker_covers_a_multi_line_use_from_its_first_line(self):
        self.write(
            "RealPathTests.swift",
            "// test-scratch: allow - opens the suite directly\n"
            "let defaults = UserDefaults(\n"
            "  suiteName: name)!\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_helper_folder_is_checked(self):
        (self.tests / "TestHelpers/FakeThing.swift").write_text(
            "let root = FileManager.default.temporaryDirectory\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("TestHelpers/FakeThing.swift:1: real system folder", result.stdout)

    def test_allow_marker_on_the_same_line_passes(self):
        self.write(
            "RealPathTests.swift",
            "let dir = FileManager.default.temporaryDirectory"
            "  // test-scratch: allow - checks the real temporary folder\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_allow_marker_on_the_line_above_passes(self):
        self.write(
            "RealPathTests.swift",
            "// test-scratch: allow - opens the suite directly\n"
            "let defaults = UserDefaults(suiteName: name)!\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_allow_marker_reaches_only_the_next_line(self):
        self.write(
            "RealPathTests.swift",
            "// test-scratch: allow - opens the suite directly\n"
            "\n"
            "let defaults = UserDefaults(suiteName: name)!\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("RealPathTests.swift:3: named preferences suite", result.stdout)

    def test_allow_marker_without_a_reason_fails(self):
        self.write(
            "RealPathTests.swift",
            "let dir = FileManager.default.temporaryDirectory  // test-scratch: allow\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("RealPathTests.swift:1: real system folder", result.stdout)

    def test_commented_or_quoted_patterns_are_ignored(self):
        self.write(
            "CommentTests.swift",
            "struct CommentTests {\n"
            "  // FileManager.default.temporaryDirectory and ExportRecordStore()\n"
            "  /* UserDefaults(suiteName: \"x\") */\n"
            "  let text = \"NSTemporaryDirectory() .temporaryDirectory\"\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_test_scratch_itself_is_exempt(self):
        (self.tests / "TestHelpers/TestScratch.swift").write_text(
            "enum TestScratch {\n"
            "  static let parent = FileManager.default.temporaryDirectory\n"
            "  static func defaults(suiteName name: String) -> UserDefaults {\n"
            "    UserDefaults(suiteName: name)!\n  }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
