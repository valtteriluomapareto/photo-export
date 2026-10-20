"""Run build-app.sh against a stub xcodebuild to check the warnings-as-errors switch."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/ci/build-app.sh'
SETTING = 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES'
LOGS = {'Debug': ('debug-build.log', 'debug-werror-build.log'),
        'Release': ('release-build.log', 'release-werror-build.log')}


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.arguments = self.root / 'arguments.txt'
        stub = self.root / 'xcodebuild'
        stub.write_text('#!/bin/bash\n'
                        f'printf "%s\\n" "$@" > "{self.arguments}"\n'
                        'echo "compile step"\n')
        stub.chmod(0o755)

    def run_script(self, configuration='Debug', switch=None):
        for log in [name for pair in LOGS.values() for name in pair]:
            (self.root / log).unlink(missing_ok=True)
        environment = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}')
        environment.pop('SWIFT_WARNINGS_AS_ERRORS', None)
        if switch is not None:
            environment['SWIFT_WARNINGS_AS_ERRORS'] = switch
        return subprocess.run(['bash', str(SCRIPT), configuration], cwd=self.root,
                              env=environment, capture_output=True, text=True, timeout=10)

    def passed_arguments(self):
        return self.arguments.read_text().splitlines()

    def saved_logs(self):
        return sorted(path.name for path in self.root.glob('*.log'))

    def test_switch_on_passes_the_setting_and_keeps_its_own_log(self):
        for configuration, (_, werror_log) in LOGS.items():
            with self.subTest(configuration=configuration):
                result = self.run_script(configuration, switch='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(SETTING, self.passed_arguments())
                self.assertIn('CODE_SIGNING_ALLOWED=NO', self.passed_arguments())
                self.assertIn('Swift warnings are errors', result.stdout)
                self.assertEqual(self.saved_logs(), [werror_log])

    def test_switch_off_or_unset_never_passes_the_setting(self):
        for switch in [None, '', '0']:
            with self.subTest(switch=switch):
                result = self.run_script(switch=switch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any('WARNINGS' in argument for argument in self.passed_arguments()))
                self.assertIn('Swift warnings are not errors', result.stdout)
                self.assertEqual(self.saved_logs(), ['debug-build.log'])

    def test_unknown_switch_value_fails_before_building(self):
        for switch in ['yes', 'true', '2']:
            with self.subTest(switch=switch):
                result = self.run_script(switch=switch)
                self.assertEqual(result.returncode, 64)
                self.assertIn('SWIFT_WARNINGS_AS_ERRORS must be 1 or 0', result.stderr)
                self.assertFalse(self.arguments.exists())


if __name__ == '__main__':
    unittest.main()
