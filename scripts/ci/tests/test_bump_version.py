"""Run the real preparation helper in disposable repositories; no network or releases."""

import os
from pathlib import Path
import subprocess
import re
import shutil
from unittest.mock import patch
import tempfile
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]


class BumpVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "candidate"
        self.root.mkdir()
        self.environment = {**{key: value for key, value in os.environ.items() if not key.startswith("GIT_")}, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                            "GIT_TERMINAL_PROMPT": "0"}
        self.project = self.root / "photo-export.xcodeproj/project.pbxproj"
        self.project.parent.mkdir()
        self.project.write_text("MARKETING_VERSION = 1.0.0;\n" * 6)
        self.website = self.root / "website/src/layouts/MarketingLayout.astro"
        self.website.parent.mkdir(parents=True)
        self.website.write_text("const softwareVersion = '1.0.0';\n")
        self.catalog = self.root / "photo-export/Models/ReleaseNotesCatalog.swift"
        self.catalog.parent.mkdir(parents=True)
        self.catalog.write_text('version: "1.0.0"\nversion: "1.2.0"\n')
        self.git("init", "-q")
        self.git("config", "user.name", "Offline fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial candidate")

    def git(self, *arguments):
        return subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *arguments],
                              cwd=self.root, env=self.environment, check=True,
                              text=True, capture_output=True).stdout.strip()

    def bump(self, *arguments):
        return subprocess.run(["/bin/bash", str(ROOT / "scripts/bump-version.sh"), *arguments], cwd=self.root,
                              env=self.environment, stdin=subprocess.DEVNULL, text=True, capture_output=True)

    def test_default_and_explicit_preparation_preserve_head_tags_and_existing_index(self):
        for arguments in [("1.2.0",), ("1.2.0", "--no-tag"), ("1.2.0-beta.1",)]:
            with self.subTest(arguments=arguments):
                self.git("reset", "--hard", "-q", "HEAD")
                sentinel = self.root / "staged.txt"
                sentinel.write_text("Preexisting work\n")
                self.git("add", "staged.txt")
                head, index, tags = self.git("rev-parse", "HEAD"), self.git("diff", "--cached"), self.git("tag")
                result = self.bump(*arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.project.read_text(), f"MARKETING_VERSION = {arguments[0]};\n" * 6)
                self.assertEqual(self.website.read_text(), "const softwareVersion = '1.2.0';\n")
                self.assertEqual(self.git("rev-parse", "HEAD"), head)
                self.assertEqual(self.git("diff", "--cached"), index)
                self.assertEqual(self.git("tag"), tags)
                self.assertIn("PR", result.stdout)

    def test_same_version_repairs_website_drift_without_creating_tag(self):
        self.website.write_text("const softwareVersion = '0.9.0';\n")
        head = self.git("rev-parse", "HEAD")
        result = self.bump("1.0.0", "--no-tag")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.website.read_text(), "const softwareVersion = '1.0.0';\n")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("tag"), "")
        self.assertIn("git tag", result.stdout)
        self.assertIn("candidate", result.stdout)

    def test_missing_catalog_blocks_all_writes_unless_explicitly_overridden(self):
        before = self.project.read_bytes(), self.website.read_bytes()
        result = self.bump("1.4.0", "--no-tag")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.project.read_bytes(), self.website.read_bytes()), before)
        for flags in [("--no-tag", "--skip-catalog-check"), ("--skip-catalog-check", "--no-tag")]:
            with self.subTest(flags=flags):
                result = self.bump("1.4.0", *flags)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.git("tag"), "")

    def test_unknown_or_extra_arguments_fail_before_mutation(self):
        before = self.project.read_bytes(), self.website.read_bytes(), self.git("rev-parse", "HEAD")
        for flags in [("--unknown",), ("--no-tag", "--unknown"), ("extra",)]:
            with self.subTest(flags=flags):
                result = self.bump("1.2.0", *flags)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.project.read_bytes(), self.website.read_bytes(),
                                  self.git("rev-parse", "HEAD")), before)
                self.assertEqual(self.git("tag"), "")

    def test_unpublished_tag_recovery_targets_exact_validated_candidate(self):
        remote = Path(self.temporary.name) / "remote.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("tag", "v1.0.0")
        self.git("push", "-q", "origin", "v1.0.0")
        (self.root / "fix.txt").write_text("Reviewed correction\n")
        self.git("add", "fix.txt")
        self.git("commit", "-qm", "Merge reviewed correction")
        candidate = self.git("rev-parse", "HEAD")
        result = self.bump("1.0.0", "--no-tag")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Runbook recovery against a local bare remote; never contact GitHub.
        self.git("push", "-q", "origin", ":refs/tags/v1.0.0")
        self.git("tag", "-d", "v1.0.0")
        self.git("tag", "v1.0.0", candidate)
        self.git("push", "-q", "origin", "refs/tags/v1.0.0")
        self.assertEqual(self.git("rev-parse", "v1.0.0^{commit}"), candidate)
        self.assertEqual(self.git("ls-remote", "--tags", "origin", "refs/tags/v1.0.0").split()[0], candidate)


    def tag_block(self):
        text = (ROOT / "docs/project/release-process.md").read_text().split("### 4. Tag and push", 1)[1]
        body = re.search(r"```bash\n(.*?)```", text, re.S)[1]
        validator = self.root / "scripts/ci/check-version.py"
        validator.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/ci/check-version.py", validator)
        self.git("add", "scripts/ci/check-version.py")
        self.git("commit", "-qm", "Add candidate validator")
        return body.replace("1.2.0", "1.0.0")

    def run_tag_block(self, body):
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", body], cwd=self.root,
                              env={**self.environment, "CANDIDATE_SHA": self.git("rev-parse", "HEAD")},
                              text=True, capture_output=True)

    def test_dirty_candidate_cannot_create_or_push_a_tag(self):
        body = self.tag_block()
        remote = Path(self.temporary.name) / "remote.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("remote", "add", "origin", str(remote))
        (self.root / "unvalidated.txt").write_text("Not part of validated candidate\n")
        result = self.run_tag_block(body)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("tag"), "")
        self.assertEqual(self.git("ls-remote", "--tags", "origin"), "")

    def test_existing_wrong_tag_cannot_be_pushed_after_tag_creation_fails(self):
        body = self.tag_block()
        remote = Path(self.temporary.name) / "remote.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("tag", "v1.0.0", "HEAD^")
        old_target = self.git("rev-parse", "v1.0.0")
        result = self.run_tag_block(body)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("rev-parse", "v1.0.0"), old_target)
        self.assertEqual(self.git("ls-remote", "--tags", "origin"), "")

    def test_inherited_git_variables_cannot_redirect_fixture_operations(self):
        before = self.git("rev-parse", "HEAD"), self.git("status", "--porcelain")
        poisoned_index = self.root / "poisoned-index"
        with patch.dict(os.environ, {"GIT_DIR": str(self.root / ".git"), "GIT_WORK_TREE": str(self.root),
                                     "GIT_INDEX_FILE": str(poisoned_index), "GIT_CONFIG_COUNT": "1",
                                     "GIT_CONFIG_KEY_0": "core.bare", "GIT_CONFIG_VALUE_0": "true"}):
            fixture = BumpVersionTests()
            self.addCleanup(fixture.doCleanups)
            fixture.setUp()
            self.assertEqual(fixture.git("rev-parse", "--show-toplevel"), str(fixture.root.resolve()))
        self.assertFalse(poisoned_index.exists())
        self.assertEqual((self.git("rev-parse", "HEAD"), self.git("status", "--porcelain")), before)


    def test_failed_release_branch_creation_cannot_mutate_or_push_main(self):
        text = (ROOT / "docs/project/release-process.md").read_text().split("### 2. Prepare", 1)[1]
        body = re.search(r"```bash\n(.*?)```", text, re.S)[1]
        for name in ("scripts/bump-version.sh", "scripts/ci/check-version.py"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        self.git("add", "scripts")
        self.git("commit", "-qm", "Fixture release tools")
        self.git("branch", "-M", "main")
        self.git("branch", "release/1.2.0")
        remote = Path(self.temporary.name) / "remote.git"
        self.git("init", "--bare", "-q", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "-u", "origin", "main")
        binaries = Path(self.temporary.name) / "stub-bin"
        binaries.mkdir()
        audit = Path(self.temporary.name) / "pr-call"
        gh = binaries / "gh"
        gh.write_text(f"#!{sys.executable}\nimport pathlib\npathlib.Path({str(audit)!r}).write_text('called')\n")
        gh.chmod(0o755)
        head, index, worktree = self.git("rev-parse", "HEAD"), self.git("diff", "--cached"), self.git("status", "--porcelain")
        before = self.project.read_bytes(), self.website.read_bytes()
        remote_head = self.git("ls-remote", "origin", "refs/heads/main")
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", body], cwd=self.root,
                                env={**self.environment, "PATH": str(binaries) + os.pathsep + self.environment["PATH"]},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("branch", "--show-current"), "main")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("diff", "--cached"), index)
        self.assertEqual(self.git("status", "--porcelain"), worktree)
        self.assertEqual((self.project.read_bytes(), self.website.read_bytes()), before)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main"), remote_head)
        self.assertFalse(audit.exists())


if __name__ == "__main__":
    unittest.main()
