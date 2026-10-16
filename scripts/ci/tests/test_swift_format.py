"""Exercise the real CI formatting step with disposable Swift source fixtures."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
FORMATTER = shutil.which("swift-format")


@unittest.skipUnless(FORMATTER, "swift-format is optional locally; CI installs and verifies it before guard tests")
class SwiftFormatGateTests(unittest.TestCase):
    def run_step(self, source, indentation=None):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        blocks = re.findall(
            r"^      - name: SwiftFormat \(check\)\n(.*?)(?=^      - name: |\Z)",
            workflow, re.M | re.S)
        self.assertEqual(len(blocks), 1, "Expected exactly one formatting step")
        lines = blocks[0].splitlines()
        self.assertEqual(lines[0], "        run: |", "Unexpected formatting step structure")
        for line in lines[1:]:
            self.assertTrue(not line.strip() or line.startswith("          ") or line.lstrip().startswith("#"),
                            f"Unexpected formatting step structure: {line}")
        script = "\n".join(line[10:] if line.startswith("          ") else "" for line in lines[1:])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = json.loads((ROOT / ".swift-format.json").read_text())
            if indentation is not None:
                # A conflicting discovered config proves explicit configuration wins.
                discovered = {"version": 1, "indentation": {"spaces": 2}}
                (root / ".swift-format").write_text(json.dumps(discovered))
                config["indentation"]["spaces"] = indentation
            (root / ".swift-format.json").write_text(json.dumps(config))
            (root / "photo-export").mkdir()
            (root / "photo-export/Fixture.swift").write_text(source)
            # Deliberately invalid formatting in the test target must stay out of scope.
            (root / "photo-exportTests").mkdir()
            (root / "photo-exportTests/OutsideScope.swift").write_text("struct Outside{let value=1}\n")
            return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                                  cwd=root, env={"PATH": os.pathsep.join([str(Path(FORMATTER).parent), "/usr/bin", "/bin"]),
                                                "HOME": str(root)}, capture_output=True, text=True)

    def test_formatted_app_source_passes_without_expanding_to_tests(self):
        result = self.run_step("struct Fixture {\n  let value = 1\n}\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("swift-format lint passed.", result.stdout)

    def test_formatting_warning_fails_before_the_success_message(self):
        result = self.run_step("struct Fixture{let value=1}\n")
        # Formatter versions differ in whether strict mode promotes diagnostic severity.
        self.assertRegex(result.stderr, r"Fixture.swift:\d+:\d+: (?:warning|error): \[Spacing\]")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("swift-format lint passed.", result.stdout)

    def test_actual_step_loads_the_explicit_configuration(self):
        result = self.run_step("struct Fixture {\n    let value = 1\n}\n", indentation=4)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "", "CI must load the fixture config instead of formatter defaults")


if __name__ == "__main__":
    unittest.main()
