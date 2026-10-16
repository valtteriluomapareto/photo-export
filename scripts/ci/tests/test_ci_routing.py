"""Area routing and merge-result gates exercised with real disposable Git histories."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ci_routing.py"
spec = importlib.util.spec_from_file_location("ci_routing", SCRIPT)
routing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routing)


class AreaPolicyTests(unittest.TestCase):
    def test_route_matrix(self):
        for paths, expected in [
            (["website/src/content/docs/features.md"], (False, True)),
            (["website/package-lock.json"], (False, True)),
            (["photo-export/Export/VariantExporter.swift"], (True, False)),
            (["photo-exportTests/ExportRecordStoreTests.swift"], (True, False)),
            (["photo-exportUITests/Smoke.swift", "photo-export.xcodeproj/project.pbxproj"], (True, False)),
            (["test-fixtures/persistence/manifest.json", ".swiftlint.yml", ".swift-format.json"], (True, False)),
            (["scripts/screenshots/capture.sh"], (True, False)),
            (["website/a", "photo-export/a"], (True, True)),
            ([".github/workflows/ci.yml"], (True, True)),
            (["scripts/ci/ci_routing.py"], (True, True)),
            (["README.md"], (True, True)),
            (["new-unrecognized/tool.txt"], (True, True)),
            (["website/file\nwith newline.md", "website/file with spaces.md"], (False, True)),
            ([], (False, False)),
        ]:
            with self.subTest(paths=paths):
                self.assertEqual(routing.classify_paths(paths), expected)

    def test_gate_truth_table(self):
        for route in ["success", "failure", "cancelled", "skipped", ""]:
            for selected in ["true", "false", "", "unexpected"]:
                for validation in ["success", "failure", "cancelled", "skipped", ""]:
                    expected = (route, selected, validation) in {
                        ("success", "true", "success"), ("success", "false", "skipped"),
                    }
                    with self.subTest(route=route, selected=selected, validation=validation):
                        self.assertEqual(routing.gate_passes(route, selected, validation), expected)


class GitRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repository"
        self.root.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci-fixture@example.invalid")
        self.commit("initial.txt")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def commit(self, name, text="fixture"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.git("add", "--all")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def route(self, event, kind="push"):
        event_path = self.root.parent / "event.json"
        event_path.write_text(json.dumps(event))
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "route", "--event-name", kind,
                                 "--event-path", str(event_path), "--repo", str(self.root),
                                 "--output", str(self.root.parent / "routing-output")],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        return value["app"], value["website"], value["reason"]

    def test_push_uses_all_commits_before_to_after(self):
        before = self.git("rev-parse", "HEAD")
        self.commit("website/a.md")
        after = self.commit("photo-export/a.swift")
        self.assertEqual(self.route({"before": before, "after": after})[:2], (True, True))

    def test_pr_uses_merge_base_not_target_changes_or_checkout_merge(self):
        ancestor = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "feature")
        head = self.commit("website/feature.md")
        self.git("checkout", "-q", "main")
        base = self.commit("photo-export/base-only.swift")
        self.git("merge", "--no-ff", "--no-edit", "feature")
        self.assertNotEqual(self.git("rev-parse", "HEAD"), head)
        self.assertNotEqual(ancestor, base)
        event = {"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}
        self.assertEqual(self.route(event, "pull_request")[:2], (False, True))

    def test_cross_area_rename_includes_both_paths_and_deletion_is_routed(self):
        before = self.commit("website/original.md")
        (self.root / "photo-export").mkdir()
        self.git("mv", "website/original.md", "photo-export/moved.swift")
        self.git("commit", "-qm", "rename")
        after = self.git("rev-parse", "HEAD")
        self.assertEqual(self.route({"before": before, "after": after})[:2], (True, True))
        self.git("mv", "photo-export/moved.swift", "website/back.md")
        self.git("commit", "-qm", "reverse rename")
        returned = self.git("rev-parse", "HEAD")
        self.assertEqual(self.route({"before": after, "after": returned})[:2], (True, True))
        self.git("rm", "website/back.md")
        self.git("commit", "-qm", "delete")
        self.assertEqual(self.route({"before": returned, "after": self.git("rev-parse", "HEAD")})[:2], (False, True))

    def test_nul_delimited_filenames_and_empty_diff(self):
        before = self.git("rev-parse", "HEAD")
        after = self.commit("website/line\nbreak.md")
        self.assertEqual(self.route({"before": before, "after": after})[:2], (False, True))
        self.assertEqual(self.route({"before": after, "after": after})[:2], (False, False))

    def test_missing_history_and_new_branch_select_both(self):
        head = self.git("rev-parse", "HEAD")
        for before in ["f" * 40, "0" * 40]:
            app, website, reason = self.route({"before": before, "after": head})
            self.assertEqual((app, website), (True, True))
            self.assertTrue(reason)
        event = {"pull_request": {"base": {"sha": head}, "head": {"sha": "f" * 40}}}
        self.assertEqual(self.route(event, "pull_request")[:2], (True, True))
        self.assertEqual(self.route({}, "workflow_dispatch")[:2], (True, True))

    def test_malformed_payload_and_non_sha_refs_are_errors(self):
        for event in [[], {}, {"before": "--output=/tmp/no", "after": "f" * 40}, {"before": "main", "after": "HEAD"}]:
            with self.subTest(event=event), self.assertRaises(ValueError):
                routing.route("push", event, self.root)

    def test_real_git_repository_errors_fail_visibly(self):
        head = self.git("rev-parse", "HEAD")
        with self.assertRaises(subprocess.CalledProcessError):
            routing.route("push", {"before": head, "after": head}, self.root / "missing")

    def test_cli_outputs_and_gate_failures(self):
        before = self.git("rev-parse", "HEAD")
        after = self.commit("website/feature.md")
        event = self.root / "event.json"
        event.write_text(json.dumps({"before": before, "after": after}))
        output = self.root / "output"
        command = [sys.executable, "-B", str(SCRIPT), "route", "--event-name", "push", "--event-path", str(event),
                   "--repo", str(self.root), "--output", str(output)]
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), "app=false\nwebsite=true\n")
        for args, expected in [(["success", "false", "skipped"], 0), (["success", "true", "skipped"], 1),
                               (["failure", "false", "skipped"], 1)]:
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), "check", *args], text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)
        event.write_text("not json")
        output.unlink()
        result = subprocess.run(command, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
