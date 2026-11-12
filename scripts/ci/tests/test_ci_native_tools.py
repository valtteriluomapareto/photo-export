"""Exercise pinned native installers and real workflow/shell validators offline."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
ACTIONLINT = shutil.which("actionlint")
SHELLCHECK = shutil.which("shellcheck")
URLS = {
    "actionlint": "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
    "shellcheck": "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz",
}
HASHES = {
    "actionlint": "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
    "shellcheck": "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f",
}
VALID_WORKFLOW = """name: Fixture
on: push
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo "valid"
"""


class NativeInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="native tools ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("mkdir", "rm", "mktemp"):
            (self.bin / name).symlink_to(shutil.which(name))
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
    elif name == "curl":
        url = next(value for value in args if value.startswith("https://"))
        tool = next(tool for tool, known in json.loads(os.environ["URLS"]).items() if known == url)
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
    elif name == "tar":
        tool = pathlib.Path(args[1]).read_text()
        events = [json.loads(line) for line in log.read_text().splitlines()]
        assert any(event[:2] == ["hash", tool] for event in events)
        if fail("extract", tool): sys.exit(1)
        destination = pathlib.Path(args[args.index("-C") + 1])
        binary = destination / ("actionlint" if tool == "actionlint" else "shellcheck-v0.11.0/shellcheck")
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sys.argv[0], binary)
        binary.chmod(0o755)
        audit("extract", tool)
    elif name in ("actionlint", "shellcheck"):
        assert args == (["-version"] if name == "actionlint" else ["--version"])
        audit("version", name, str(pathlib.Path(sys.argv[0]).resolve()))
        if fail("version", name): print("wrong")
        elif name == "actionlint": print("1.7.12\\ninstalled from release")
        else: print("ShellCheck - shell script analysis tool\\nversion: 0.11.0\\nlicense: GNU GPL")
        if fail("version-exit", name): sys.exit(9)
    else:
        raise AssertionError([name, *args])
except Exception as error:
    pathlib.Path(os.environ["UNEXPECTED"]).write_text(repr(error))
    raise
'''
        for name in ("uname", "curl", "shasum", "tar"):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.path_file = self.root / "github-path"

    def install(self, failure="", system="Darwin", arch="arm64"):
        self.path_file.write_text("existing-path\n")
        for name in ("audit", "unexpected"):
            (self.root / name).unlink(missing_ok=True)
        environment = {
            "PATH": str(self.bin), "RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.path_file),
            "AUDIT": str(self.root / "audit"), "UNEXPECTED": str(self.root / "unexpected"),
            "FAKE_OS": system, "FAKE_ARCH": arch, "FAILURE": failure,
            "URLS": json.dumps(URLS), "HASHES": json.dumps(HASHES),
        }
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/ci/install-ci-tools.sh")],
                                cwd=self.root, env=environment, capture_output=True, text=True)
        self.assertFalse((self.root / "unexpected").exists(), result.stdout + result.stderr)
        audit = self.root / "audit"
        return result, [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []

    def test_verified_pair_publishes_only_complete_tools(self):
        result, events = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for tool in URLS:
            self.assertEqual([event[0] for event in events if event[1] == tool],
                             ["download", "hash", "extract", "version"])
        paths = self.path_file.read_text().splitlines()
        self.assertEqual(paths[0], "existing-path")
        self.assertEqual(len(paths), 3)
        for directory, tool in zip(paths[1:], URLS):
            self.assertTrue((Path(directory) / tool).is_file())
        self.assertEqual([event[2] for event in events if event[0] == "version"],
                         [str((Path(directory) / tool).resolve()) for directory, tool in zip(paths[1:], URLS)])
        self.assertEqual(list(self.root.glob("ci-tools.*/*.tar.gz")), [])

    def test_each_tool_failure_cleans_install_and_publishes_no_partial_path(self):
        for tool in URLS:
            for stage in ("download", "hash", "extract", "version", "version-exit"):
                with self.subTest(tool=tool, stage=stage):
                    result, _ = self.install(f"{stage}:{tool}")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.path_file.read_text(), "existing-path\n")
                    self.assertEqual(list(self.root.glob("ci-tools.*")), [])

    def test_unsupported_platforms_fail_before_download(self):
        for system, arch in (("Linux", "arm64"), ("Darwin", "x86_64")):
            with self.subTest(system=system, arch=arch):
                result, events = self.install(system=system, arch=arch)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [])
                self.assertEqual(self.path_file.read_text(), "existing-path\n")


class NativeValidationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="native validation ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, binary in (("actionlint", ACTIONLINT), ("shellcheck", SHELLCHECK)):
            (self.bin / name).symlink_to(binary or shutil.which("true"))
        for name in ("check-workflows.sh", "check-shell-scripts.sh"):
            destination = self.root / "scripts/ci" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "scripts/ci" / name, destination)
        workflows = self.root / ".github/workflows"
        workflows.mkdir(parents=True)
        self.workflow = workflows / "fixture.yml"
        self.workflow.write_text(VALID_WORKFLOW)
        shutil.copyfile(ROOT / ".github/actionlint.yaml", self.root / ".github/actionlint.yaml")
        self.shell = self.root / "fixture with spaces.sh"
        self.shell.write_text('#!/bin/bash\nprintf "%s\\n" "valid"\n')
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)

    def run_check(self, name):
        return subprocess.run(["/bin/bash", str(self.root / "scripts/ci" / name)], cwd=self.root,
                              env={"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root)},
                              capture_output=True, text=True)

    @unittest.skipUnless(ACTIONLINT and SHELLCHECK, "native fixture tools are installed before CI guards")
    def test_valid_workflow_and_tracked_shell_pass(self):
        for check in ("check-workflows.sh", "check-shell-scripts.sh"):
            result = self.run_check(check)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipUnless(ACTIONLINT and SHELLCHECK, "native fixture tools are installed before CI guards")
    def test_malformed_yaml_and_invalid_expression_fail(self):
        for source, expected in (("name: [unclosed\n", "syntax-check"),
                                 (VALID_WORKFLOW.replace('echo "valid"', 'echo "${{ unknown.value }}"'),
                                  "expression")):
            with self.subTest(expected=expected):
                self.workflow.write_text(source)
                result = self.run_check("check-workflows.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout + result.stderr)

    @unittest.skipUnless(ACTIONLINT and SHELLCHECK, "native fixture tools are installed before CI guards")
    def test_embedded_shell_is_checked(self):
        self.workflow.write_text(VALID_WORKFLOW.replace('echo "valid"', "value='two words'; echo $value"))
        result = self.run_check("check-workflows.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SC2086", result.stdout + result.stderr)

    @unittest.skipUnless(ACTIONLINT and SHELLCHECK, "native fixture tools are installed before CI guards")
    def test_standalone_shell_is_checked_with_filename_boundaries(self):
        self.shell.write_text("#!/bin/bash\nvalue='two words'\necho $value\n")
        result = self.run_check("check-shell-scripts.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SC2086", result.stdout + result.stderr)
        self.assertIn(self.shell.name, result.stdout + result.stderr)

    @unittest.skipUnless(ACTIONLINT and SHELLCHECK, "native fixture tools are installed before CI guards")
    def test_only_exact_preview_runner_is_allowed(self):
        self.workflow.write_text(VALID_WORKFLOW.replace("ubuntu-latest", "xcode-27"))
        result = self.run_check("check-workflows.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.workflow.write_text(VALID_WORKFLOW.replace("ubuntu-latest", "unknown-preview-runner"))
        result = self.run_check("check-workflows.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner-label", result.stdout + result.stderr)

    def test_missing_tools_fail_closed(self):
        for tool, checks in (("actionlint", ("check-workflows.sh",)),
                             ("shellcheck", ("check-workflows.sh", "check-shell-scripts.sh"))):
            with self.subTest(tool=tool):
                link = self.bin / tool
                binary = link.readlink() if link.exists() else None
                link.unlink(missing_ok=True)
                for check in checks:
                    result = self.run_check(check)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(tool, result.stdout + result.stderr)
                if binary:
                    link.symlink_to(binary)


if __name__ == "__main__":
    unittest.main()
