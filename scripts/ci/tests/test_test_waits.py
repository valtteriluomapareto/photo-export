"""Run the real test-wait guard against disposable test-target skeletons."""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
GUARD = CI_DIRECTORY / "check-test-waits.py"


class TestWaitGuardTests(unittest.TestCase):
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
        (self.tests / "TestHelpers/TestWait.swift").write_text(
            "func eventually() { while clock.now < deadline {} }\n")

    def run_guard(self):
        return subprocess.run(
            [sys.executable, "-B", str(self.root / "scripts/ci" / GUARD.name), str(self.root)],
            capture_output=True, text=True)

    def write(self, name, source):
        (self.tests / name).write_text(source)

    def test_progress_based_waits_with_time_limit_pass(self):
        self.write(
            "GoodTests.swift",
            "@Suite(.timeLimit(.minutes(2))) struct GoodTests {\n"
            "  func t() async { _ = await eventually(\"x\") { true } }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_wall_clock_deadline_loop_fails(self):
        self.write(
            "DeadlineTests.swift",
            "struct DeadlineTests {\n"
            "  func t() async {\n"
            "    let deadline = Date().addingTimeInterval(3)\n"
            "    while !done && Date() < deadline { }\n  }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("DeadlineTests.swift:4: wall-clock deadline wait", result.stdout)

    def test_eventually_without_time_limit_fails(self):
        self.write(
            "UnboundedTests.swift",
            "struct UnboundedTests {\n  func t() async { _ = await eventually(\"x\") { true } }\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertIn("UnboundedTests.swift: calls eventually( but declares no", result.stdout)

    def test_commented_or_quoted_patterns_are_ignored(self):
        self.write(
            "CommentTests.swift",
            "struct CommentTests {\n"
            "  // while clock.now < deadline { }\n"
            "  let text = \"eventually( < deadline\"\n}\n")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
