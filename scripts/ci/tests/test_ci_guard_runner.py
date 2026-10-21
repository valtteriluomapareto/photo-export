"""Run the real local guard entry point against nonrecursive disposable guard stubs."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / 'scripts/ci/run-guards.sh'
GUARDS = [
    'test-guards.sh', 'check-read-only-photos.py', 'check-no-plan-refs.py',
    'check-test-waits.py', 'check-test-scratch.py', 'check-persistence-doc.py',
    'check-version.py', 'check-regression-gates.sh', 'check-fingerprint-id-keying.sh',
]


class GuardRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / 'scripts/ci'
        scripts.mkdir(parents=True)
        if RUNNER.exists():
            shutil.copy(RUNNER, scripts)
        self.invocations = self.root / 'invocations'
        self.environment = dict(os.environ, INVOCATIONS=str(self.invocations), FAILED_GUARDS='')
        for name in GUARDS:
            path = scripts / name
            if name.endswith('.py'):
                path.write_text('import os, sys\n'
                                f'name = {name!r}\n'
                                'with open(os.environ["INVOCATIONS"], "a") as f: f.write(name + "\\n")\n'
                                'sys.exit(4 if name in os.environ["FAILED_GUARDS"].split(",") else 0)\n')
            else:
                # In particular, test-guards.sh is a stub: never invoke this suite recursively.
                path.write_text(f'#!/bin/bash\necho {name} >> "$INVOCATIONS"\n'
                                f'[[ ",$FAILED_GUARDS," != *",{name},"* ]]\n')
            path.chmod(0o755)

    def run_fixture(self, failures=''):
        return subprocess.run(['bash', str(self.root / 'scripts/ci/run-guards.sh')],
                              cwd=self.root.parent,
                              env=dict(self.environment, FAILED_GUARDS=failures),
                              capture_output=True, text=True, timeout=10)

    def test_every_static_ci_guard_is_in_the_fixture_inventory(self):
        invoked = set(re.findall(r'scripts/ci/(check-[\w-]+\.(?:py|sh)|test-guards\.sh)',
                                 (ROOT / '.github/workflows/ci.yml').read_text()))
        invoked -= {'check-built-app.sh', 'check-regression-gates-ran.py'}
        self.assertEqual(invoked, set(GUARDS))

    def test_clean_guards_all_run_from_another_directory(self):
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invocations.read_text().splitlines(), GUARDS)
        for guard in GUARDS:
            self.assertIn(guard, result.stdout)
        self.assertIn('All static guards passed.', result.stdout)

    def test_multiple_failures_are_reported_and_later_success_still_runs(self):
        failures = ['test-guards.sh', 'check-test-waits.py']
        result = self.run_fixture(','.join(failures))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.invocations.read_text().splitlines(), GUARDS)
        self.assertNotIn('All static guards passed.', result.stdout)
        for guard in failures:
            self.assertIn(f'FAIL: {guard}', result.stdout)
        self.assertIn('PASS: check-fingerprint-id-keying.sh', result.stdout)
