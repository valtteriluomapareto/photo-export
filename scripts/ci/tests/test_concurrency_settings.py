"""Exercise project executor-policy checks with disposable build settings."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'check-concurrency-settings.py'


class ConcurrencySettingsTests(unittest.TestCase):
    def run_guard(self, settings):
        with tempfile.TemporaryDirectory() as directory:
            project = pathlib.Path(directory) / 'project.pbxproj'
            project.write_text(settings)
            return subprocess.run([sys.executable, '-B', str(SCRIPT), str(project)],
                                  capture_output=True, text=True)

    def test_existing_executor_and_language_settings_are_allowed(self):
        result = self.run_guard('SWIFT_VERSION = 5.0;\nSWIFT_STRICT_CONCURRENCY = complete;')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_executor_changing_settings_are_rejected_even_when_disabled(self):
        for key in ['SWIFT_APPROACHABLE_CONCURRENCY', 'SWIFT_DEFAULT_ACTOR_ISOLATION',
                    'SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT']:
            for value in ['YES', 'NO']:
                with self.subTest(key=key, value=value):
                    result = self.run_guard(f'\n"{key}" = {value};')
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn('project.pbxproj:2:', result.stderr)

    def test_upcoming_feature_in_other_swift_flags_is_rejected(self):
        result = self.run_guard('OTHER_SWIFT_FLAGS = "-enable-upcoming-feature NonisolatedNonsendingByDefault";')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('NonisolatedNonsendingByDefault', result.stderr)

    def test_comments_do_not_enable_a_setting(self):
        result = self.run_guard('// SWIFT_APPROACHABLE_CONCURRENCY = YES;\n'
                                '/* SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;\n'
                                'NonisolatedNonsendingByDefault */\nSWIFT_VERSION = 5.0;')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
