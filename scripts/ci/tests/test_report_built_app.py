"""Run the canary's built-app report against a stub build and real plutil (macOS only)."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "report-built-app.sh"


@unittest.skipUnless(shutil.which("plutil"), "plutil is macOS-only")
class ReportBuiltAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.products = self.root / "Build/Products/Release"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "xcodebuild"
        stub.write_text("#!/bin/bash\n"
                        f"echo '    TARGET_BUILD_DIR = {self.products}'\n"
                        "echo '    FULL_PRODUCT_NAME = Photo Export.app'\n")
        stub.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")

    def build(self, **values):
        contents = self.products / "Photo Export.app/Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump(values, output)

    def report(self, version):
        return subprocess.run(["bash", str(SCRIPT), version], cwd=self.root, env=self.environment,
                              capture_output=True, text=True, timeout=10)

    def test_matching_toolchain_reports_the_compliance_key_and_sdk(self):
        self.build(DTXcode="2660", DTXcodeBuild="17F113", DTSDKName="macosx26.5",
                   ITSAppUsesNonExemptEncryption=False)
        result = self.report("26.6")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ITSAppUsesNonExemptEncryption: false", result.stdout)
        self.assertIn("DTXcodeBuild: 17F113", result.stdout)

    def test_missing_compliance_key_is_reported_not_failed(self):
        self.build(DTXcode="1620")
        result = self.report("16.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ITSAppUsesNonExemptEncryption: absent", result.stdout)

    def test_app_built_by_another_xcode_fails(self):
        self.build(DTXcode="1620")
        result = self.report("26.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 2660", result.stderr)

    def test_missing_app_fails_instead_of_passing_without_evidence(self):
        result = self.report("26.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Info.plist not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
