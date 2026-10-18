"""Execute the actual tool-install step offline and pin workflow cancellation/link gates."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_release_safety import expression, render, selected_steps

ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / "scripts/ci/install-swift-tools.sh"
URLS = {
    "swiftlint": "https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip",
    "swift-format": "https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9",
}
HASHES = {"swiftlint": "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
          "swift-format": "a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9"}


def concurrency(source, values):
    blocks = re.findall(r"^concurrency:\n(.*?)(?=^\S)", source, re.M | re.S)
    if len(blocks) != 1:
        raise ValueError("Expected one concurrency block")
    fields = dict(re.findall(r"^  (group|cancel-in-progress): (.+)$", blocks[0], re.M))
    group = fields["group"]
    if group == "ci-${{ github.event_name == 'pull_request' && github.ref || github.sha }}":
        group = "ci-" + (values["github.ref"] if values["github.event_name"].casefold() == "pull_request"
                         else values["github.sha"])
    else:
        group = render(group, values)
    cancel = fields["cancel-in-progress"]
    if cancel in ("true", "false"):
        cancel = cancel == "true"
    elif cancel.startswith("${{ ") and cancel.endswith(" }}"):
        cancel = expression(cancel[4:-3], values)
    else:
        raise ValueError("Unsupported cancellation expression")
    return group.casefold(), cancel


class InstallerFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, target in {"bash": "/bin/bash", "mkdir": "/bin/mkdir", "rm": "/bin/rm",
                             "mktemp": "/usr/bin/mktemp"}.items():
            (self.bin / name).symlink_to(target)
        stub = f"#!{sys.executable}\n" + '''import json, os, pathlib, shutil, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
log = pathlib.Path(os.environ["AUDIT"])
def audit(*entry):
    with log.open("a") as output: output.write(json.dumps(entry) + "\\n")
def fail(stage, tool):
    return os.environ["FAILURE"] == stage + ":" + tool
try:
    if name == "uname":
        assert args in (["-s"], ["-m"])
        print(os.environ["FAKE_OS"] if args == ["-s"] else os.environ["FAKE_ARCH"])
    elif name == "sw_vers":
        assert args == ["-productVersion"]
        print(os.environ["FAKE_MACOS"])
    elif name == "brew":
        assert args == ["install", "swiftlint", "swift-format"]
        audit("mutable-brew-install")
    elif name == "curl":
        url = next(value for value in args if value.startswith("https://"))
        urls = json.loads(os.environ["URLS"])
        tool = next(tool for tool, known in urls.items() if known == url)
        assert "--fail" in args and "--location" in args
        audit("download", tool, url)
        if fail("download", tool): sys.exit(22)
        pathlib.Path(args[args.index("--output") + 1]).write_text(tool)
    elif name == "shasum":
        assert args == ["-a", "256", "-c"]
        digest, filename = sys.stdin.read().strip().split(None, 1)
        tool = pathlib.Path(filename).read_text()
        assert digest == json.loads(os.environ["HASHES"])[tool]
        audit("hash", tool, digest)
        if fail("hash", tool): sys.exit(1)
    elif name in ("unzip", "tar"):
        archive = pathlib.Path(args[1])
        tool = archive.read_text()
        events = [json.loads(line) for line in log.read_text().splitlines()]
        assert any(event[:2] == ["hash", tool] for event in events)
        if fail("extract", tool): sys.exit(1)
        destination = pathlib.Path(args[args.index("-d" if name == "unzip" else "-C") + 1])
        binary = destination / ("swiftlint" if name == "unzip" else "swift-format/603.0.0/bin/swift-format")
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sys.argv[0], binary)
        binary.chmod(0o755)
        audit("extract", tool)
    elif name in ("swiftlint", "swift-format"):
        assert args == (["version"] if name == "swiftlint" else ["--version"])
        audit("version", name, str(pathlib.Path(sys.argv[0]).resolve()))
        print("wrong" if fail("version", name) else "0.65.1" if name == "swiftlint" else "603.0.0")
        if fail("version-exit", name): sys.exit(9)
    else:
        raise AssertionError([name, *args])
except Exception as error:
    pathlib.Path(os.environ["UNEXPECTED"]).write_text(repr(error))
    raise
'''
        for name in ("uname", "sw_vers", "brew", "curl", "shasum", "unzip", "tar", "swiftlint", "swift-format"):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.path_file = self.root / "github-path"
        self.path_file.write_text("existing-path\n")
        if INSTALLER.exists():
            target = self.root / "scripts/ci/install-swift-tools.sh"
            target.parent.mkdir(parents=True)
            shutil.copyfile(INSTALLER, target)

    def install(self, failure="", system="Darwin", arch="arm64", macos="15.7.9"):
        self.path_file.write_text("existing-path\n")
        for name in ("audit", "unexpected"):
            (self.root / name).unlink(missing_ok=True)
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        step = selected_steps(source, ["Install SwiftLint and swift-format"])[0]
        environment = {"PATH": str(self.bin), "RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.path_file),
                       "AUDIT": str(self.root / "audit"), "UNEXPECTED": str(self.root / "unexpected"),
                       "FAKE_OS": system, "FAKE_ARCH": arch, "FAKE_MACOS": macos, "FAILURE": failure,
                       "URLS": json.dumps(URLS), "HASHES": json.dumps(HASHES)}
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", step["run"]],
                                cwd=self.root, env=environment, capture_output=True, text=True)
        audit = self.root / "audit"
        self.assertFalse((self.root / "unexpected").exists(), result.stdout + result.stderr)
        return result, [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []

    def test_actual_install_step_uses_verified_pins_and_publishes_only_complete_tools(self):
        result, events = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(["mutable-brew-install"], events)
        for tool in URLS:
            stages = [event[0] for event in events if len(event) > 1 and event[1] == tool]
            self.assertEqual(stages, ["download", "hash", "extract", "version"])
        paths = self.path_file.read_text().splitlines()
        self.assertEqual(len(paths), 3)
        self.assertEqual(paths[0], "existing-path")
        self.assertTrue((Path(paths[1]) / "swiftlint").is_file())
        self.assertTrue((Path(paths[2]) / "swift-format").is_file())
        self.assertEqual([event[2] for event in events if event[0] == "version"],
                         [str((Path(paths[1]) / "swiftlint").resolve()),
                          str((Path(paths[2]) / "swift-format").resolve())])

    def test_each_tool_failure_exports_no_partial_path(self):
        for tool in URLS:
            for stage in ("download", "hash", "extract", "version"):
                with self.subTest(tool=tool, stage=stage):
                    result, _ = self.install(f"{stage}:{tool}")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.path_file.read_text(), "existing-path\n")
                    self.assertEqual(list(self.root.glob("swift-tools.*")), [])

    def test_expected_version_output_with_failed_command_exports_no_path(self):
        for tool in URLS:
            with self.subTest(tool=tool):
                result, _ = self.install(f"version-exit:{tool}")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.path_file.read_text(), "existing-path\n")
                self.assertEqual(list(self.root.glob("swift-tools.*")), [])

    def test_newer_supported_macos_uses_the_same_pins(self):
        result, events = self.install(macos="26.6")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([event[2] for event in events if event[0] == "download"], list(URLS.values()))

    def test_unsupported_platforms_fail_before_any_download(self):
        for system, arch, macos in [("Linux", "arm64", "15.0"), ("Darwin", "x86_64", "15.0"),
                                     ("Darwin", "arm64", "14.7")]:
            with self.subTest(system=system, arch=arch, macos=macos):
                result, events = self.install(system=system, arch=arch, macos=macos)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(event[0] == "download" for event in events))
                self.assertEqual(self.path_file.read_text(), "existing-path\n")


class WorkflowHardeningTests(unittest.TestCase):
    def test_main_commits_are_independent_while_pr_updates_cancel_their_predecessor(self):
        source = (ROOT / ".github/workflows/ci.yml").read_text()
        def key(event, ref, sha):
            return concurrency(source, {"github.event_name": event, "github.ref": ref, "github.sha": sha})
        main_a, cancel = key("push", "refs/heads/main", "aaa")
        self.assertFalse(cancel)
        self.assertNotEqual(main_a, key("push", "refs/heads/main", "bbb")[0])
        pr_a, cancel = key("pull_request", "refs/pull/1/merge", "aaa")
        self.assertTrue(cancel)
        self.assertEqual(pr_a, key("PULL_REQUEST", "REFS/PULL/1/MERGE", "bbb")[0])
        self.assertNotEqual(pr_a, key("pull_request", "refs/pull/2/merge", "aaa")[0])

    def test_pages_link_gates_precede_artifact_and_deployment(self):
        source = (ROOT / ".github/workflows/deploy-website.yml").read_text()
        _, cancel = concurrency(source, {})
        self.assertFalse(cancel)
        block = source.split("  build:\n", 1)[1].split("  deploy:\n", 1)[0]
        bodies = re.findall(r"^      - name: Test and check built website links\n(.*?)(?=^      - |\Z)",
                            block, re.M | re.S)
        self.assertEqual(len(bodies), 1)
        self.assertEqual(re.findall(r"^        working-directory: (.+)$", bodies[0], re.M), ["website"])
        body = re.sub(r"^        working-directory: .+\n", "", bodies[0], flags=re.M)
        links = selected_steps("      - name: Test and check built website links\n" + body,
                               ["Test and check built website links"])[0]
        self.assertEqual(links.get("if"), None)
        self.assertEqual(links["run"].strip(), "npm run test:links\nnpm run check:links")
        self.assertLess(block.index("Validate website"), block.index("Test and check built website links"))
        self.assertLess(block.index("Test and check built website links"), block.index("actions/upload-pages-artifact@"))
        self.assertNotIn("continue-on-error", block)
        deployment = source.split("  deploy:\n", 1)[1]
        self.assertRegex(deployment, r"^    needs: build\n")
        self.assertNotRegex(deployment, r"(?m)^    if:")

    def test_unknown_workflow_syntax_and_missing_context_are_rejected(self):
        with self.assertRaises(ValueError):
            concurrency("concurrency:\n  group: ci-${{ unknown() }}\n  cancel-in-progress: true\njobs:\n", {})
        with self.assertRaises(KeyError):
            concurrency("concurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true\njobs:\n", {})
