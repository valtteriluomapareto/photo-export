"""Check the release validation-row mapping against the app tree and shipped history."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

RELEASE_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
REPO = RELEASE_DIRECTORY.parents[1]
sys.path.insert(0, str(RELEASE_DIRECTORY))

import validation_rows as vr  # noqa: E402

RANGES = json.loads((pathlib.Path(__file__).with_name("fixtures") / "release_ranges.json").read_text())


def assess_range(name):
    data = RANGES[name]
    return vr.assess(data["paths"], data["pbxproj_diff"])


class MappingCompletenessTests(unittest.TestCase):
    def test_every_app_file_maps_to_rows_or_is_core_only(self):
        app = REPO / "photo-export"
        files = sorted(
            str(path.relative_to(REPO))
            for path in app.rglob("*")
            if path.is_file() and path.name != ".DS_Store"
        )
        self.assertGreater(len(files), 100)
        unmapped = [path for path in files if vr.classify(path).unmapped]
        self.assertEqual(
            unmapped, [],
            "Map each new app file in scripts/release/validation_rows.py to the validation "
            "rows its behavior affects, or to CORE_ONLY when the core smoke covers it.")

    def test_rows_named_in_rules_exist(self):
        for _, rows in vr.RULES:
            self.assertTrue(set(rows) <= set(vr.ROWS), rows)


class ShippedHistoryTests(unittest.TestCase):
    def test_version_only_project_changes_never_require_the_full_matrix(self):
        for name in [key for key in RANGES if not key.startswith("_")]:
            with self.subTest(range=name):
                self.assertEqual(assess_range(name).full_matrix_reasons, [])

    def test_network_remount_fix_triggers_destination_reconnect(self):
        self.assertIn("destination", assess_range("v1.6.4..v1.6.5").rows)

    def test_first_run_window_fix_triggers_authorization(self):
        self.assertIn("authorization", assess_range("v1.6.2..v1.6.3").rows)

    def test_auto_export_cache_rewrite_triggers_auto_export(self):
        self.assertIn("autoexport", assess_range("v1.6.0..v1.6.1").rows)

    def test_backup_matcher_fix_triggers_import(self):
        self.assertIn("import", assess_range("v1.6.3..v1.6.4").rows)

    def test_rows_reached_only_through_hubs_are_reported_as_excludable(self):
        result = vr.assess(["photo-export/Export/ExportManager.swift",
                            "photo-export/Destination/A.swift"], [])
        self.assertTrue(result.hub_only("local"))
        self.assertFalse(result.hub_only("destination"))

    def test_hubs_are_mapped_files(self):
        for hub in vr.HUBS:
            with self.subTest(hub=hub):
                self.assertTrue(vr.classify(hub).rows)
                self.assertTrue((REPO / hub).is_file())

    def test_thumbnail_window_fix_needs_only_the_core_smoke(self):
        result = assess_range("v1.6.1..v1.6.2")
        self.assertEqual((result.rows, result.full_matrix_reasons), ({}, []))


class FullMatrixTests(unittest.TestCase):
    def test_unmapped_app_path_requires_the_full_matrix(self):
        result = vr.assess(["photo-export/NewArea/Thing.swift"], [])
        self.assertEqual(result.unmapped, ["photo-export/NewArea/Thing.swift"])
        self.assertTrue(result.full_matrix_reasons)

    def test_project_build_setting_change_requires_the_full_matrix(self):
        diff = [
            "-\t\t\t\tMARKETING_VERSION = 1.6.5;",
            "+\t\t\t\tMARKETING_VERSION = 1.6.6;",
            '+\t\t\t\t"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Development";',
        ]
        result = vr.assess(["photo-export.xcodeproj/project.pbxproj"], diff)
        self.assertTrue(any("project.pbxproj" in reason for reason in result.full_matrix_reasons))

    def test_entitlements_privacy_and_build_configuration_require_the_full_matrix(self):
        for path in [
            "photo-export/photo_export.entitlements",
            "photo-export/PrivacyInfo.xcprivacy",
            "photo-export/Project.xcconfig",
            ".xcode-version",
        ]:
            with self.subTest(path=path):
                self.assertTrue(vr.assess([path], []).full_matrix_reasons)

    def test_release_workflow_requires_the_full_matrix_only_for_toolchain_or_signing(self):
        workflow = ".github/workflows/release-direct.yml"
        self.assertEqual(
            vr.assess([workflow], [], {workflow: ["+    - cron: '0 6 * * 1'"]}).full_matrix_reasons,
            [])
        self.assertTrue(
            vr.assess([workflow], [], {workflow: ["+  XCODE_PATH: /Applications/Xcode_16.4.app"]})
            .full_matrix_reasons)

    def test_macos_major_change_requires_the_full_matrix(self):
        self.assertTrue(vr.assess([], [], macos_major_changed=True).full_matrix_reasons)

    def test_tests_docs_and_website_alone_need_only_the_core_smoke(self):
        result = vr.assess(
            ["photo-exportTests/FooTests.swift", "docs/README.md", "website/src/x.md"], [])
        self.assertEqual((result.rows, result.full_matrix_reasons), ({}, []))


class CommandLineTests(unittest.TestCase):
    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True, text=True)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = pathlib.Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        for relative in ["photo-export/Destination/A.swift", "photo-export/AutoSync/B.swift"]:
            (self.repo / relative).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / relative).write_text("// 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.git("tag", "base")
        (self.repo / "photo-export/AutoSync/B.swift").write_text("// 2\n")
        self.git("commit", "-qam", "auto export change")
        self.git("tag", "middle")
        (self.repo / "photo-export/Destination/A.swift").write_text("// 2\n")
        self.git("commit", "-qam", "destination change")

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(RELEASE_DIRECTORY / "validation_rows.py"), *args],
            cwd=self.repo, capture_output=True, text=True)

    def test_reports_each_row_against_its_own_baseline(self):
        result = self.run_cli("--base", "base", "--row-base", "autoexport=middle")
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn("Core smoke: required", lines)
        self.assertIn(
            "Destination reconnect (since base): TRIGGERED - photo-export/Destination/A.swift",
            lines)
        self.assertIn("Auto Export / relaunch (since middle): not triggered", lines)
        self.assertIn("Full matrix: not required", lines)

    def test_rejects_unknown_row(self):
        result = self.run_cli("--base", "base", "--row-base", "nope=middle")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown row", result.stderr)


if __name__ == "__main__":
    unittest.main()
