"""The workflow and shell validators fail closed without their native tools, and the shell
validator passes each tracked script to ShellCheck as one argument."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class NativeValidationTests(unittest.TestCase):
    def test_missing_tools_fail_closed(self):
        for tool, present, checks in (("actionlint", "shellcheck", ("check-workflows.sh",)),
                                      ("shellcheck", "actionlint", ("check-workflows.sh", "check-shell-scripts.sh"))):
            for check in checks:
                with self.subTest(tool=tool, check=check), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / "bin").mkdir()
                    (root / "bin" / present).symlink_to(shutil.which("true"))
                    script = root / "scripts/ci" / check
                    script.parent.mkdir(parents=True)
                    shutil.copyfile(ROOT / "scripts/ci" / check, script)
                    result = subprocess.run(["/bin/bash", str(script)], cwd=root,
                                            env={"PATH": f"{root / 'bin'}:/usr/bin:/bin"},
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(tool, result.stderr)
                    self.assertIn("run scripts/ci/install-ci-tools.sh", result.stderr)

    def test_shell_check_keeps_filename_boundaries(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "bin").mkdir()
            calls = root / "shellcheck-args"
            stub = root / "bin" / "shellcheck"
            stub.write_text(f'#!/bin/bash\nprintf "%s\\n" "$@" > "{calls}"\n')
            stub.chmod(0o755)
            script = root / "scripts/ci/check-shell-scripts.sh"
            script.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "scripts/ci/check-shell-scripts.sh", script)
            (root / "fixture with spaces.sh").write_text("#!/bin/bash\n")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "fixture with spaces.sh", "scripts"], cwd=root, check=True)
            result = subprocess.run(["/bin/bash", str(script)], cwd=root,
                                    env={"PATH": f"{root / 'bin'}:/usr/bin:/bin"},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("fixture with spaces.sh", calls.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
