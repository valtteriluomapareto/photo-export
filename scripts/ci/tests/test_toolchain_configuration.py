"""Retained script/project contracts independent of workflow source structure."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOL = re.compile(r"\b(xcodebuild|xcrun|swift|plutil)\b")
SWITCH = re.compile(r"xcode-select\s+(-s|--?switch)\b")
XCODE_SCRIPTS = sorted(
    path.relative_to(ROOT).as_posix() for path in (ROOT / "scripts/ci").glob("*.sh")
    if path.name != "select-xcode.sh" and TOOL.search(path.read_text()))


class ToolchainConfigurationTests(unittest.TestCase):
    def test_ci_scripts_never_override_the_selected_toolchain(self):
        self.assertIn("scripts/ci/build-app.sh", XCODE_SCRIPTS)
        self.assertIn("scripts/ci/upload-appstore-connect.sh", XCODE_SCRIPTS)
        for path in (ROOT / "scripts/ci").glob("*.sh"):
            if path.name == "select-xcode.sh":
                continue
            text = path.read_text()
            for token in ["DEVELOPER_DIR", "TOOLCHAINS"]:
                with self.subTest(script=path.name, token=token):
                    self.assertNotIn(token, text)
            with self.subTest(script=path.name, token="xcode-select switch"):
                self.assertIsNone(SWITCH.search(text))

    def test_no_project_or_xcconfig_build_setting_treats_warnings_as_errors(self):
        """Only build-app.sh's switch sets it, so the release builds never fail on a warning."""
        files = [ROOT / "photo-export.xcodeproj/project.pbxproj",
                 *(path for path in ROOT.rglob("*.xcconfig")
                   if not {".git", "build", "node_modules"} & set(path.parts))]
        for path in files:
            with self.subTest(file=path.relative_to(ROOT).as_posix()):
                self.assertNotIn("SWIFT_TREAT_WARNINGS_AS_ERRORS", path.read_text())
        self.assertTrue(files[0].exists())
