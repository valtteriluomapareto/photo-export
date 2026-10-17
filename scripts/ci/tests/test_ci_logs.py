"""Run the actual workflow shell blocks with disposable xcodebuild output."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

WORKFLOW = Path(__file__).resolve().parents[3] / '.github/workflows/ci.yml'
STEPS = [
    ('Build Debug', 'debug-build.log'),
    ('Run Unit Tests (Debug, with coverage)', 'test.log'),
    ('Build Release', 'release-build.log'),
]
MARKER = 'Expectation failed: CI_LOG_EARLY_EXPECTATION'
DETAIL = '↳ CI_LOG_CUSTOM_EXPECTATION_EXPLANATION'
COMPILER = 'Fixture.swift:12:3: error: CI_LOG_EARLY_COMPILER'


def block(name):
    lines = WORKFLOW.read_text().splitlines()
    start = next((i for i, line in enumerate(lines) if line == f'      - name: {name}'), None)
    if start is None:
        return ''
    for i in range(start + 1, len(lines)):
        if lines[i] == '        run: |':
            result = []
            for line in lines[i + 1:]:
                if line and not line.startswith('          '):
                    break
                result.append(line[10:])
            return '\n'.join(result)
        if lines[i].startswith('      - name:'):
            break
    return ''


class WorkflowLogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        stub = self.root / 'xcodebuild'
        stub.write_text('#!/bin/bash\n'
                        'mkdir -p TestResults.xcresult\n'
                        f'echo "{MARKER}"\n'
                        f'echo "{DETAIL}"\n'
                        f'echo "{COMPILER}" >&2\n'
                        'for ((i=0; i<500; i++)); do echo "trailing successful test $i"; done\n'
                        'exit "${FIXTURE_EXIT:-65}"\n')
        stub.chmod(0o755)
        self.environment = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}')

    def run_block(self, name, exit_code=65):
        return subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', block(name)],
                              cwd=self.root, env=dict(self.environment, FIXTURE_EXIT=str(exit_code)),
                              capture_output=True, text=True, timeout=10)

    def test_failure_preserves_status_full_log_and_early_reason_for_all_pipelines(self):
        for name, log in STEPS:
            with self.subTest(step=name):
                for _, previous_log in STEPS:
                    (self.root / previous_log).unlink(missing_ok=True)
                result = self.run_block(name)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertNotIn('succeeded.', result.stdout)
                self.assertNotIn('Unit tests passed.', result.stdout)
                saved = self.root / log
                self.assertTrue(saved.exists(), f'{name} must save its untruncated output')
                self.assertIn(MARKER, saved.read_text())
                self.assertIn(DETAIL, saved.read_text())
                self.assertIn(COMPILER, saved.read_text())
                diagnostic = self.run_block('Print build and test failure diagnostics')
                self.assertEqual(diagnostic.returncode, 0, diagnostic.stderr)
                self.assertIn(MARKER, diagnostic.stdout)
                self.assertIn(DETAIL, diagnostic.stdout)
                self.assertIn(COMPILER, diagnostic.stdout)

    def test_success_status_and_epilogue_are_preserved(self):
        for name, log in STEPS:
            with self.subTest(step=name):
                result = self.run_block(name, exit_code=0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(result.stdout, r'(succeeded\.|Unit tests passed\.)')
                self.assertTrue((self.root / log).exists())

    def test_failure_diagnostics_print_early_expectation_beyond_tail(self):
        (self.root / 'test.log').write_text(MARKER + '\n' + DETAIL + '\n' + 'passed\n' * 500)
        result = self.run_block('Print build and test failure diagnostics')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(MARKER, result.stdout)
        self.assertIn(DETAIL, result.stdout)

    def test_diagnostic_missing_and_no_match_logs_are_not_failures(self):
        for contents in [None, 'A failure without matching diagnostic text\n']:
            with self.subTest(contents=contents):
                if contents is not None:
                    (self.root / 'test.log').write_text(contents)
                result = self.run_block('Print build and test failure diagnostics')
                self.assertEqual(result.returncode, 0, result.stderr)
