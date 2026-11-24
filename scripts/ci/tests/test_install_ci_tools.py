"""Execute the pinned CI tool installer against offline tool fixtures."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
INSTALLER = ROOT / "scripts/ci/install-ci-tools.sh"
URLS = {
    "swiftlint": "https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip",
    "swift-format": "https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9",
    "actionlint": "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz",
    "shellcheck": "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz",
}
HASHES = {"swiftlint": "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
          "swift-format": "a32eef7ab3a18682cc5865060d25801dd948936704ff82f50cc0afeec1416ca9",
          "actionlint": "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
          "shellcheck": "339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f"}
# Where each archive's binary lands under its extraction directory.
BINARIES = {"swiftlint": "swiftlint", "swift-format": "swift-format/603.0.0/bin/swift-format",
            "actionlint": "actionlint", "shellcheck": "shellcheck-v0.11.0/shellcheck"}
VERSIONS = {"swiftlint": (["version"], "0.65.1"), "swift-format": (["--version"], "603.0.0"),
            "actionlint": (["-version"], "1.7.12\ninstalled by downloading from release page"),
            "shellcheck": (["--version"], "ShellCheck - shell script analysis tool\nversion: 0.11.0\nlicense: GNU GPL")}


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
        binary = destination / json.loads(os.environ["BINARIES"])[tool]
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sys.argv[0], binary)
        binary.chmod(0o755)
        audit("extract", tool)
    elif name in ("swiftlint", "swift-format", "actionlint", "shellcheck"):
        expected_args, output = json.loads(os.environ["VERSIONS"])[name]
        assert args == expected_args
        audit("version", name, str(pathlib.Path(sys.argv[0]).resolve()))
        print("wrong" if fail("version", name) else output)
        if fail("version-exit", name): sys.exit(9)
    else:
        raise AssertionError([name, *args])
except Exception as error:
    pathlib.Path(os.environ["UNEXPECTED"]).write_text(repr(error))
    raise
'''
        for name in ("uname", "sw_vers", "brew", "curl", "shasum", "unzip", "tar", *URLS):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.path_file = self.root / "github-path"
        self.path_file.write_text("existing-path\n")
        if INSTALLER.exists():
            target = self.root / "scripts/ci/install-ci-tools.sh"
            target.parent.mkdir(parents=True)
            shutil.copyfile(INSTALLER, target)

    def install(self, failure="", system="Darwin", arch="arm64", macos="15.7.9"):
        self.path_file.write_text("existing-path\n")
        for name in ("audit", "unexpected"):
            (self.root / name).unlink(missing_ok=True)
        environment = {"PATH": str(self.bin), "RUNNER_TEMP": str(self.root), "GITHUB_PATH": str(self.path_file),
                       "AUDIT": str(self.root / "audit"), "UNEXPECTED": str(self.root / "unexpected"),
                       "FAKE_OS": system, "FAKE_ARCH": arch, "FAKE_MACOS": macos, "FAILURE": failure,
                       "URLS": json.dumps(URLS), "HASHES": json.dumps(HASHES),
                       "BINARIES": json.dumps(BINARIES), "VERSIONS": json.dumps(VERSIONS)}
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/ci/install-ci-tools.sh")],
                                cwd=self.root, env=environment, capture_output=True, text=True)
        audit = self.root / "audit"
        self.assertFalse((self.root / "unexpected").exists(), result.stdout + result.stderr)
        return result, [json.loads(line) for line in audit.read_text().splitlines()] if audit.exists() else []

    def test_actual_installer_uses_verified_pins_and_publishes_only_complete_tools(self):
        result, events = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(["mutable-brew-install"], events)
        for tool in URLS:
            stages = [event[0] for event in events if len(event) > 1 and event[1] == tool]
            self.assertEqual(stages, ["download", "hash", "extract", "version"])
        paths = self.path_file.read_text().splitlines()
        self.assertEqual(paths[0], "existing-path")
        installed = [Path(directory) / tool for directory, tool in zip(paths[1:], URLS)]
        self.assertEqual(len(paths), 1 + len(URLS))
        self.assertTrue(all(binary.is_file() for binary in installed))
        self.assertEqual([event[2] for event in events if event[0] == "version"],
                         [str(binary.resolve()) for binary in installed])
        self.assertEqual([path.name for path in self.root.glob("ci-tools.*/*") if path.is_file()], [])

    def test_each_tool_failure_exports_no_partial_path(self):
        for tool in URLS:
            for stage in ("download", "hash", "extract", "version"):
                with self.subTest(tool=tool, stage=stage):
                    result, _ = self.install(f"{stage}:{tool}")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.path_file.read_text(), "existing-path\n")
                    self.assertEqual(list(self.root.glob("ci-tools.*")), [])

    def test_expected_version_output_with_failed_command_exports_no_path(self):
        for tool in URLS:
            with self.subTest(tool=tool):
                result, _ = self.install(f"version-exit:{tool}")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.path_file.read_text(), "existing-path\n")
                self.assertEqual(list(self.root.glob("ci-tools.*")), [])

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
