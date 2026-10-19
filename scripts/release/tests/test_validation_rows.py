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
    return vr.assess(data["paths"], data["pbxproj_diff"], hub_subjects=data["hub_subjects"],
                     deleted=data["deleted"])


def required(result, row):
    """A row the release owner cannot exclude."""
    return row in result.rows and not result.hub_only(row)


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
        for name in [key for key in RANGES if key.startswith("v")]:
            with self.subTest(range=name):
                self.assertEqual(assess_range(name).full_matrix_reasons, [])

    def test_network_remount_fix_triggers_destination_reconnect(self):
        self.assertTrue(required(assess_range("v1.6.4..v1.6.5"), "destination"))

    def test_first_run_window_fix_triggers_authorization(self):
        self.assertTrue(required(assess_range("v1.6.2..v1.6.3"), "authorization"))

    def test_auto_export_cache_rewrite_triggers_auto_export(self):
        self.assertTrue(required(assess_range("v1.6.0..v1.6.1"), "autoexport"))

    def test_backup_matcher_fix_triggers_import(self):
        self.assertTrue(required(assess_range("v1.6.3..v1.6.4"), "import"))

    def test_hub_only_fix_whose_commit_names_the_area_is_required(self):
        # #298 touched only ExportManager.swift; its subject names pause and resume.
        result = assess_range("c352da8^..c352da8")
        self.assertTrue(required(result, "cancel"))
        self.assertTrue(result.hub_only("collections"))

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
            "+\t\t\t\tENABLE_HARDENED_RUNTIME = NO;",
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

    def test_release_workflow_toolchain_change_requires_the_full_matrix(self):
        workflow = ".github/workflows/release-direct.yml"
        self.assertTrue(
            vr.assess([workflow], [], {workflow: ["+  XCODE_PATH: /Applications/Xcode_16.4.app"]})
            .full_matrix_reasons)

    def test_macos_major_change_requires_the_full_matrix(self):
        self.assertTrue(vr.assess([], [], macos_major_changed=True).full_matrix_reasons)

    def test_deleted_unmapped_path_is_listed_without_the_full_matrix(self):
        result = vr.assess(["photo-export/Old/Gone.swift"], [], deleted=["photo-export/Old/Gone.swift"])
        self.assertEqual(result.full_matrix_reasons, [])
        self.assertEqual(result.unmapped, ["photo-export/Old/Gone.swift"])

    def test_tests_docs_and_website_alone_need_only_the_core_smoke(self):
        result = vr.assess(
            ["photo-exportTests/FooTests.swift", "docs/README.md", "website/src/x.md"], [])
        self.assertEqual((result.rows, result.full_matrix_reasons), ({}, []))


class SigningOverrideTests(unittest.TestCase):
    def test_release_pipelines_still_override_the_ignored_project_signing_keys(self):
        direct = (REPO / ".github/workflows/release-direct.yml").read_text()
        store = (REPO / "scripts/ci/archive-appstore.sh").read_text()
        for key in vr.PIPELINE_OVERRIDDEN_KEYS:
            if key == "PROVISIONING_PROFILE_SPECIFIER":
                self.assertIn(f"{key}=", store)
                continue
            with self.subTest(key=key):
                self.assertIn(f"{key}=", direct)
                self.assertIn(f"{key}=", store)

    def test_project_lines_for_pipeline_overridden_signing_keys_are_ignored(self):
        diff = [
            '+\t\t\t\t"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Development";',
            "+\t\t\t\tDEVELOPMENT_TEAM = N4FKQHR5AC;",
        ]
        self.assertEqual(
            vr.assess(["photo-export.xcodeproj/project.pbxproj"], diff).full_matrix_reasons, [])

    def test_release_scripts_and_shared_scheme_require_the_full_matrix(self):
        for path in [
            "scripts/ci/archive-appstore.sh",
            "scripts/ci/export-appstore.sh",
            "photo-export.xcodeproj/xcshareddata/xcschemes/photo-export.xcscheme",
        ]:
            with self.subTest(path=path):
                self.assertTrue(vr.assess([path], []).full_matrix_reasons)

    def test_any_release_workflow_build_change_requires_the_full_matrix(self):
        workflow = ".github/workflows/release-direct.yml"
        for line in ["+            SWIFT_OPTIMIZATION_LEVEL=-Onone \\",
                     "+          <string>developer-id</string>",
                     "-            -configuration Release \\"]:
            with self.subTest(line=line):
                self.assertTrue(vr.assess([workflow], [], {workflow: [line]}).full_matrix_reasons)
        for line in ["+  # weekly signed dry run", '+          echo "Archiving"',
                     "+  schedule:", "+    - cron: '0 6 * * 1'"]:
            with self.subTest(line=line):
                self.assertEqual(
                    vr.assess([workflow], [], {workflow: [line]}).full_matrix_reasons, [])


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

    def test_renamed_file_triggers_the_rows_of_its_old_path(self):
        self.git("mv", "photo-export/Destination/A.swift", "photo-export/AutoSync/A.swift")
        self.git("commit", "-qm", "move")
        lines = self.run_cli("--base", "HEAD~1").stdout.splitlines()
        self.assertIn("Destination reconnect (since HEAD~1): TRIGGERED - "
                      "photo-export/Destination/A.swift", lines)
        self.assertIn("Auto Export / relaunch (since HEAD~1): TRIGGERED - "
                      "photo-export/AutoSync/A.swift", lines)

    def test_full_matrix_applies_only_to_rows_on_the_affected_baseline(self):
        (self.repo / "photo-export/photo_export.entitlements").write_text("<plist/>\n")
        self.git("add", ".")
        self.git("commit", "-qm", "entitlements")
        self.git("tag", "after-entitlements")
        result = self.run_cli("--base", "after-entitlements", "--row-base", "autoexport=base")
        lines = result.stdout.splitlines()
        self.assertIn("Auto Export / relaunch (since base): TRIGGERED - full matrix", lines)
        self.assertIn("Destination reconnect (since after-entitlements): not triggered", lines)
        self.assertIn("Full matrix: REQUIRED for rows since base", lines)

    def test_row_without_a_recorded_pass_is_owed(self):
        result = self.run_cli("--base", "HEAD", "--row-base", "import=never")
        self.assertIn("Import existing backup / record recovery (never passed): TRIGGERED - "
                      "no recorded pass", result.stdout.splitlines())

    def test_unknown_ref_fails_without_a_traceback(self):
        result = self.run_cli("--base", "no-such-ref")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("no-such-ref", result.stderr)

    def test_rejects_unknown_row(self):
        result = self.run_cli("--base", "base", "--row-base", "nope=middle")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown row", result.stderr)


if __name__ == "__main__":
    unittest.main()
