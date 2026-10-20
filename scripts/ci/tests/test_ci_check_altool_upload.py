"""Run the altool upload check against a stub xcrun."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-altool-upload.sh"


class CheckAltoolUploadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        bin_dir = Path(temporary.name)
        for name, body in [
            ("xcrun", '#!/bin/bash\nprintf "%s\\n" "$FAKE_HELP"\nexit "${FAKE_EXIT:-0}"\n'),
            ("xcode-select", "#!/bin/bash\necho /Applications/Xcode_26.6.app/Contents/Developer\n"),
        ]:
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")

    def check(self, help_text, exit_code=0):
        return subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, timeout=10,
                              env=dict(self.environment, FAKE_HELP=help_text,
                                       FAKE_EXIT=str(exit_code)))

    def test_upload_flag_passes_even_when_help_exits_non_zero(self):
        long_help = "\n".join(["usage: altool ..."] + [f"  --option-{i}" for i in range(500)]
                              + ["  --upload-package <file>"])
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code):
                result = self.check(long_help, exit_code)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_upload_flag_fails_and_says_what_to_do(self):
        result = self.check("usage: altool --notarize-app (removed)")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no --upload-package", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
