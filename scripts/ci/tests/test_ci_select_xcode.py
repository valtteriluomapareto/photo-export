"""Run the actual Xcode selection script against a disposable /Applications and stub tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "select-xcode.sh"

XCODE_SELECT = """#!/bin/bash
state="$FIXTURE_ROOT/selected"
case "$1" in
  -s) printf '%s\\n' "$2" > "$state" ;;
  -p) if [[ -n "${FAKE_ACTIVE:-}" ]]; then echo "$FAKE_ACTIVE"; else echo "$(cat "$state")/Contents/Developer"; fi ;;
  *) exit 64 ;;
esac
"""
XCODEBUILD = """#!/bin/bash
case "$1" in
  -version) printf 'Xcode %s\\nBuild version FIXTURE\\n' "$FAKE_XCODE_VERSION" ;;
  -showsdks) echo "	macOS 15.2	-sdk macosx15.2" ;;
  *) exit 64 ;;
esac
"""
SWIFT = "#!/bin/bash\necho 'swift-driver version: fixture'\n"


class SelectXcodeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "scripts/ci").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts/ci/select-xcode.sh")
        self.apps = self.root / "Applications"
        (self.apps / "Xcode_16.2.app/Contents/Developer").mkdir(parents=True)
        candidate = self.apps / "Xcode_27.1_Release_Candidate.app"
        (candidate / "Contents/Developer").mkdir(parents=True)
        (self.apps / "Xcode_27.1.app").symlink_to(candidate)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, body in [("xcode-select", XCODE_SELECT), ("xcodebuild", XCODEBUILD), ("swift", SWIFT)]:
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.environment = {
            key: value for key, value in os.environ.items() if key not in ("DEVELOPER_DIR", "TOOLCHAINS")}
        self.environment.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}", FIXTURE_ROOT=str(self.root),
            XCODE_APPS_DIR=str(self.apps), XCODE_SELECT_CMD="xcode-select")

    def run_select(self, *args, pinned="16.2\n", **environment):
        if pinned is not None:
            (self.root / ".xcode-version").write_text(pinned)
        return subprocess.run(
            ["bash", str(self.root / "scripts/ci/select-xcode.sh"), *args],
            cwd=self.root, env=dict(self.environment, **environment),
            capture_output=True, text=True, timeout=10)

    def selected(self):
        state = self.root / "selected"
        return state.read_text().strip() if state.exists() else None

    def test_pinned_version_is_selected_and_reported(self):
        result = self.run_select(FAKE_XCODE_VERSION="16.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.selected(), str(self.apps / "Xcode_16.2.app"))
        self.assertIn("Xcode_27.1_Release_Candidate.app", result.stdout)
        self.assertIn("Build version FIXTURE", result.stdout)

    def test_argument_overrides_the_pin_and_resolves_a_symlinked_app(self):
        result = self.run_select("27.1", FAKE_XCODE_VERSION="27.1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.selected(), str(self.apps / "Xcode_27.1_Release_Candidate.app"))

    def test_missing_version_fails_listing_what_is_installed_without_selecting(self):
        result = self.run_select("26.6", FAKE_XCODE_VERSION="26.6")
        self.assertNotEqual(result.returncode, 0)
        output = result.stdout + result.stderr
        self.assertIn("26.6", output)
        self.assertIn("Xcode_16.2.app", output)
        self.assertIsNone(self.selected())

    def test_empty_missing_or_malformed_pin_fails_without_selecting(self):
        for pinned in ["", "\n", "sixteen\n", "16.2 beta\n", None]:
            with self.subTest(pinned=pinned):
                (self.root / ".xcode-version").unlink(missing_ok=True)
                result = self.run_select(pinned=pinned, FAKE_XCODE_VERSION="16.2")
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(self.selected())

    def test_toolchain_overrides_fail_because_they_would_bypass_the_selection(self):
        for name, value in [("DEVELOPER_DIR", str(self.apps / "Xcode_27.1.app/Contents/Developer")),
                            ("TOOLCHAINS", "swift")]:
            with self.subTest(variable=name):
                result = self.run_select(FAKE_XCODE_VERSION="16.2", **{name: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stdout + result.stderr)
                self.assertIsNone(self.selected())

    def test_active_toolchain_that_reports_another_version_fails(self):
        result = self.run_select(FAKE_XCODE_VERSION="16.4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Xcode 16.4", result.stdout + result.stderr)

    def test_active_developer_directory_elsewhere_fails(self):
        result = self.run_select(
            FAKE_XCODE_VERSION="16.2", FAKE_ACTIVE="/Library/Developer/CommandLineTools")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CommandLineTools", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
