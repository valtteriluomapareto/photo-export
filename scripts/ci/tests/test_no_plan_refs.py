"""Exercise the source-comment guard through its real CLI on disposable Swift files."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'check-no-plan-refs.py'


class NoPlanReferencesTests(unittest.TestCase):
    def run_guard(self, source=None, *, app=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            if app:
                (root / 'photo-export').mkdir()
            if source is not None:
                (root / 'photo-export' / 'Example.swift').write_text(source)
            return subprocess.run([sys.executable, '-B', str(SCRIPT), str(root)],
                                  capture_output=True, text=True)

    def test_comments_report_filename_line_and_reason(self):
        result = self.run_guard('let value = 1\n// Phase 3 will add this\n')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('photo-export/Example.swift:2:', result.stdout)
        self.assertIn('describe the current reason', result.stdout)

    def test_existing_spellings_and_nested_block_comments(self):
        for comment in ['// phase 4a', '/// pre-Phase-0a', '/* outer /* Phase 2 */ end */',
                        '// Plan §Retry', '/// Plan\n/// §State Reducer', '// issue item 5']:
            with self.subTest(comment=comment):
                result = self.run_guard(comment + '\n')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_strings_are_ignored_but_following_comments_are_checked(self):
        literals = ['"// Phase 3"', '#"/* Plan §Retry */"#',
                    '"""\n// Phase 2\n"""', '##"""\n/* Phase-0 */\n"""##',
                    '"value \\(String("Phase 4"))"']
        for literal in literals:
            with self.subTest(literal=literal):
                source = 'let example = ' + literal + '\n'
                valid = self.run_guard(source)
                self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
                invalid = self.run_guard(source + '// Phase 7\n')
                self.assertEqual(invalid.returncode, 1, invalid.stdout + invalid.stderr)
                line = source.count('\n') + 1
                self.assertIn(f'Example.swift:{line}:', invalid.stdout)

    def test_extended_regex_is_ignored_and_following_comment_is_checked(self):
        for literal in ['#/ // Phase 3 /#', '#/"/#', '##/ /* Plan §Retry */ /##']:
            with self.subTest(literal=literal):
                source = 'let pattern = ' + literal + '\n'
                result = self.run_guard(source)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                result = self.run_guard(source + '// Phase 4\n')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('Example.swift:2:', result.stdout)

    def test_current_reasons_and_identifiers_are_allowed(self):
        result = self.run_guard('let phase2 = 2\n// Cache counts to coalesce reads.\n'
                                '// A two-phase commit preserves the log.\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reference_cannot_span_executable_code(self):
        result = self.run_guard('// Plan\nlet value = 1\n// §State\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_or_empty_app_tree_fails(self):
        for app in [False, True]:
            with self.subTest(app=app):
                result = self.run_guard(app=app)
                self.assertEqual(result.returncode, 2)
                self.assertIn('input error', result.stderr)

    def test_malformed_swift_fails(self):
        for source in ['/* unclosed', 'let text = "unclosed', 'let pattern = #/unclosed']:
            with self.subTest(source=source):
                result = self.run_guard(source)
                self.assertEqual(result.returncode, 2)
                self.assertIn('input error', result.stderr)

    def test_ci_invokes_guard(self):
        workflow = SCRIPT.parents[2] / '.github' / 'workflows' / 'ci.yml'
        self.assertIn('python3 -B scripts/ci/check-no-plan-refs.py', workflow.read_text())


if __name__ == '__main__':
    unittest.main()
