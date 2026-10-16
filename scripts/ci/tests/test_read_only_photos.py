"""Exercise the actual Photos scanner in disposable source trees."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


SCANNER = pathlib.Path(__file__).resolve().parents[1] / "check-read-only-photos.py"


class ReadOnlyPhotosTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)

    def scan(self, source):
        (self.root / "Sample.swift").write_text(source)
        return subprocess.run(
            [sys.executable, str(SCANNER), str(self.root)], capture_output=True, text=True
        )

    def test_reading_and_destination_writes_pass(self):
        result = self.scan(
            'import Photos\nlet assets = PHAsset.fetchAssets(with: nil)\n'
            'PHAssetResourceManager.default().writeData(for: resource, toFile: url)\n'
            'try FileManager.default.moveItem(at: temp, to: destination)\n'
            'let performChangesCount = 0\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Read-only Photos guard passed", result.stdout)

    def test_mutation_identifiers_fail_at_their_source_line(self):
        for token in (
            "PHAssetChangeRequest", "PHAssetCreationRequest",
            "PHAssetCollectionChangeRequest", "PHCollectionListChangeRequest",
            "performChanges", "performChangesAndWait",
        ):
            with self.subTest(token=token):
                result = self.scan("import Photos\n\n" + token + "()\n")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Sample.swift:3:", result.stderr)
                self.assertIn("forbidden PhotoKit mutation identifier: " + token, result.stderr)

    def test_comments_and_strings_are_ignored_without_hiding_later_code(self):
        ignored = [
            "// PHAssetChangeRequest()\n",
            "/* outer /* performChanges() */ PHAssetCreationRequest() */\n",
            'let help = "PHAssetChangeRequest() // example"\n',
            'let help = #"performChanges() \\" still text"#\n',
            'let help = """\nPHAssetChangeRequest()\n"""\n',
            'let help = ##"""\nperformChangesAndWait()\n"""##\n',
        ]
        for source in ignored:
            with self.subTest(source=source):
                clean = self.scan(source)
                self.assertEqual(clean.returncode, 0, clean.stderr)
                result = self.scan(source + "PHAssetChangeRequest()\n")
                line = source.count("\n") + 1
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"Sample.swift:{line}:", result.stderr)
                self.assertIn("forbidden PhotoKit mutation identifier", result.stderr)

    def test_missing_and_empty_source_roots_fail(self):
        for root in (self.root / "missing", self.root):
            with self.subTest(root=root):
                result = subprocess.run(
                    [sys.executable, str(SCANNER), str(root)], capture_output=True, text=True
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("Photos guard input error:", result.stderr)

    def test_interpolation_cannot_hide_code_after_the_string(self):
        for expression in (
            r'let s = "\(String("//"))"; PHAssetChangeRequest()',
            r'let s = #"\#(String("/*"))"#; PHAssetChangeRequest()',
            r'let s = "\(String("\(String("//"))"))"; PHAssetChangeRequest()',
        ):
            with self.subTest(expression=expression):
                result = self.scan(expression + "\n")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Sample.swift:1:", result.stderr)
                self.assertIn("forbidden PhotoKit mutation identifier: PHAssetChangeRequest", result.stderr)

    def test_unterminated_comment_fails_instead_of_hiding_source(self):
        result = self.scan("/* PHAssetChangeRequest()\n")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unterminated block comment", result.stderr)


if __name__ == "__main__":
    unittest.main()
