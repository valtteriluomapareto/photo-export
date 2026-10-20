"""Run the built-app check against stub builds and real plutil (macOS only)."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-built-app.sh"


@unittest.skipUnless(shutil.which("plutil"), "plutil is macOS-only")
class CheckBuiltAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts/ci").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts/ci/check-built-app.sh")
        (self.root / ".xcode-version").write_text("26.6\n")
        self.products = self.root / "Build/Products/Release"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.stub = bin_dir / "xcodebuild"
        self.stub.write_text("#!/bin/bash\n"
                             f"echo '    TARGET_BUILD_DIR = {self.products}'\n"
                             "echo '    FULL_PRODUCT_NAME = Photo Export.app'\n")
        self.stub.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")

    def build(self, at=None, **values):
        app = at or self.products / "Photo Export.app"
        (app / "Contents").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as output:
            plistlib.dump(values, output)
        return app

    def check(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/ci/check-built-app.sh"), *args],
                              cwd=self.root, env=self.environment,
                              capture_output=True, text=True, timeout=10)

    def test_pinned_toolchain_and_compliance_key_pass_and_are_reported(self):
        self.build(DTXcode="2660", DTXcodeBuild="17F113", DTSDKName="macosx26.5",
                   LSMinimumSystemVersion="15.0", ITSAppUsesNonExemptEncryption=False)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ITSAppUsesNonExemptEncryption: false", result.stdout)
        self.assertIn("LSMinimumSystemVersion: 15.0", result.stdout)

    def test_missing_or_true_compliance_key_fails(self):
        for values in [{"DTXcode": "2660"},
                       {"DTXcode": "2660", "ITSAppUsesNonExemptEncryption": True}]:
            with self.subTest(values=values):
                shutil.rmtree(self.products, ignore_errors=True)
                self.build(**values)
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ITSAppUsesNonExemptEncryption is", result.stderr)

    def test_app_built_by_another_xcode_fails(self):
        self.build(DTXcode="1620", ITSAppUsesNonExemptEncryption=False)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 2660", result.stderr)

    def test_canary_version_argument_overrides_the_pin(self):
        self.build(DTXcode="2710", ITSAppUsesNonExemptEncryption=False)
        self.assertEqual(self.check("27.1").returncode, 0)
        self.assertNotEqual(self.check().returncode, 0)

    def test_explicit_app_path_is_checked_without_build_settings(self):
        self.stub.write_text("#!/bin/bash\necho 'unexpected xcodebuild call' >&2\nexit 1\n")
        archived = self.build(at=self.root / "archive/Products/Applications/Photo Export.app",
                              DTXcode="2660", ITSAppUsesNonExemptEncryption=False)
        result = self.check("--app", str(archived))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_stray_or_misordered_arguments_are_rejected(self):
        self.build(DTXcode="2710", ITSAppUsesNonExemptEncryption=False)
        for args in [("27.1", "--app", "X"), ("--verbose",), ("27.1", "26.6")]:
            with self.subTest(args=args):
                result = self.check(*args)
                self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                self.assertIn("usage", result.stderr)

    def test_missing_app_fails_instead_of_passing_without_evidence(self):
        for args in [(), ("--app", str(self.root / "missing/Photo Export.app"))]:
            with self.subTest(args=args):
                result = self.check(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Info.plist not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
