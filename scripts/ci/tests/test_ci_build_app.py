"""Run build-app.sh against a stub xcodebuild to check the warnings-as-errors switch."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/ci/build-app.sh'
SETTING = 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES'
EARLY_ERROR = 'Early.swift:3:9: error: CI_BUILD_EARLY_ERROR'
LATE_ERROR = 'Late.swift:7:1: error: CI_BUILD_LATE_ERROR'


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.arguments = self.root / 'arguments.txt'
        stub = self.root / 'xcodebuild'
        # Records its arguments, then prints an error the 200-line tail would cut off.
        stub.write_text('#!/bin/bash\n'
                        f'printf "%s\\n" "$@" > "{self.arguments}"\n'
                        'if [[ "${FIXTURE_EXIT:-0}" != 0 ]]; then\n'
                        f'  echo "{EARLY_ERROR}"\n'
                        f'  echo "   | \\`- error: CI_BUILD_EARLY_ERROR"\n'
                        f'  echo "{EARLY_ERROR}"\n'
                        'fi\n'
                        'for ((i=0; i<500; i++)); do echo "compile step $i"; done\n'
                        'if [[ "${FIXTURE_EXIT:-0}" != 0 ]]; then\n'
                        f'  echo "{LATE_ERROR}" >&2\n'
                        '  echo "** BUILD FAILED **"\n'
                        'fi\n'
                        'exit "${FIXTURE_EXIT:-0}"\n')
        stub.chmod(0o755)

    def run_script(self, configuration='Debug', switch=None, exit_code=0):
        environment = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}',
                           FIXTURE_EXIT=str(exit_code))
        environment.pop('SWIFT_WARNINGS_AS_ERRORS', None)
        if switch is not None:
            environment['SWIFT_WARNINGS_AS_ERRORS'] = switch
        return subprocess.run(['bash', str(SCRIPT), configuration], cwd=self.root,
                              env=environment, capture_output=True, text=True, timeout=10)

    def passed_arguments(self):
        return self.arguments.read_text().splitlines()

    def test_switch_on_passes_the_setting_and_says_so(self):
        for configuration in ['Debug', 'Release']:
            with self.subTest(configuration=configuration):
                result = self.run_script(configuration, switch='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(SETTING, self.passed_arguments())
                self.assertIn('CODE_SIGNING_ALLOWED=NO', self.passed_arguments())
                self.assertIn('Swift warnings are errors', result.stdout)

    def test_switch_off_or_unset_never_passes_the_setting(self):
        for switch in [None, '', '0']:
            with self.subTest(switch=switch):
                result = self.run_script(switch=switch)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(SETTING, self.passed_arguments())
                self.assertFalse(any('WARNINGS' in argument for argument in self.passed_arguments()))
                self.assertIn('Swift warnings are not errors', result.stdout)

    def test_unknown_switch_value_fails_before_building(self):
        for switch in ['yes', 'true', '2']:
            with self.subTest(switch=switch):
                result = self.run_script(switch=switch)
                self.assertEqual(result.returncode, 64)
                self.assertIn('SWIFT_WARNINGS_AS_ERRORS must be 1 or 0', result.stderr)
                self.assertFalse(self.arguments.exists())

    def test_failure_prints_every_error_line_once_and_keeps_the_status(self):
        for switch in ['1', '0']:
            with self.subTest(switch=switch):
                result = self.run_script(switch=switch, exit_code=65)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertNotIn('succeeded.', result.stdout)
                errors = result.stdout.split('build errors (every error: line in debug-build.log)', 1)
                self.assertEqual(len(errors), 2, result.stdout)
                self.assertEqual(errors[1].count('CI_BUILD_EARLY_ERROR'), 1)
                self.assertIn(EARLY_ERROR, errors[1])
                self.assertEqual(errors[1].count(LATE_ERROR), 1)
                self.assertIn('Debug build failed with status 65', result.stdout)

    def test_success_prints_no_error_section(self):
        result = self.run_script(switch='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Debug build succeeded.', result.stdout)
        self.assertNotIn('build errors', result.stdout)


if __name__ == '__main__':
    unittest.main()
