"""Check the exclusive-rename probe on every pull request, since the canary job runs it only
weekly and on dispatch: the shell and its embedded Python must parse, and on macOS the
--folder mode must pass on a temporary folder."""
import pathlib
import platform
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
PROBE = ROOT / "scripts/probe-exclusive-rename.sh"


class ProbeExclusiveRenameTests(unittest.TestCase):
    def test_shell_parses(self):
        result = subprocess.run(["bash", "-n", str(PROBE)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_embedded_python_compiles(self):
        blocks = re.findall(r"<<'PY'\n(.*?)\nPY\n", PROBE.read_text(), flags=re.S)
        self.assertEqual(len(blocks), 1)
        compile(blocks[0], f"{PROBE.name} heredoc", "exec")

    def test_unknown_arguments_are_rejected(self):
        result = subprocess.run(["bash", str(PROBE), "--bogus"], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage: probe-exclusive-rename.sh", result.stderr)

    @unittest.skipUnless(platform.system() == "Darwin", "renamex_np and getattrlist are macOS calls")
    def test_folder_mode_passes_and_removes_its_subfolder(self):
        with tempfile.TemporaryDirectory() as folder:
            result = subprocess.run(["bash", str(PROBE), "--folder", folder],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("existing_rename=EEXIST", result.stdout)
            self.assertIn("destination=intact", result.stdout)
            self.assertEqual(list(pathlib.Path(folder).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
