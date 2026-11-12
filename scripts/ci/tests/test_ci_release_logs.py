"""Exercise archive logging offline with fake credentials and a fake xcodebuild."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SANITIZER = ROOT / 'scripts/ci/sanitize-release-log.py'
CHANNELS = [
    ('direct', 'archive-direct.sh', 'photo-export-direct-archive.log'),
    ('appstore', 'archive-appstore.sh', 'photo-export-appstore-archive.log'),
]


class ReleaseArchiveLogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / 'scripts/ci'
        scripts.mkdir(parents=True)
        for name in ['archive-direct.sh', 'archive-appstore.sh']:
            shutil.copy(ROOT / 'scripts/ci' / name, scripts)
        if SANITIZER.exists():
            shutil.copy(SANITIZER, scripts)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        runner = self.root / 'runner'
        runner.mkdir()
        profiles = self.root / 'profiles'
        profiles.mkdir()
        self.env = dict(
            PATH=f'{self.bin}:{os.environ["PATH"]}', PROJECT='fixture.xcodeproj',
            SCHEME='fixture', RUNNER_TEMP=str(runner), GITHUB_ENV=str(self.root / 'github-env'),
            APPLE_TEAM_ID='fixture-team-private', KEYCHAIN_PASSWORD='fixture-keychain-private',
            CERTIFICATE_PASSWORD='fixture-certificate-private',
            APPLE_APP_SPECIFIC_PASSWORD='fixture-multiline\ncredential-private',
            KEYCHAIN_PATH=str(runner / 'fixture.keychain-db'), PROFILE_UUID='fixture-profile-id',
            PROFILE_NAME='Fixture Profile', BUILD_NUMBER='42', APPSTORE_BUNDLE_ID='fixture.bundle',
            PROFILES_DIR=str(profiles), ARGUMENTS_FILE=str(self.root / 'arguments'),
            GITHUB_RUN_NUMBER='42',
        )
        stub = self.bin / 'xcodebuild'
        stub.write_text('''#!/bin/bash
if [[ "$1" != archive ]]; then
  echo 'CODE_SIGN_STYLE = Manual'
  echo "DEVELOPMENT_TEAM = $APPLE_TEAM_ID"
  echo "build settings stderr $KEYCHAIN_PASSWORD" >&2
  exit 0
fi
printf '%s\\0' "$@" > "$ARGUMENTS_FILE"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -archivePath ]]; then mkdir -p "$2/Products/Applications"; fi
  shift
done
echo 'EARLY ARCHIVE DIAGNOSTIC'
echo "early stdout $KEYCHAIN_PASSWORD"
echo "early stderr $CERTIFICATE_PASSWORD" >&2
for ((i=0; i<500; i++)); do echo "archive detail $i"; done
echo "late stdout $APPLE_TEAM_ID"
printf 'late multiline %s\\n' "$APPLE_APP_SPECIFIC_PASSWORD" >&2
printf 'unterminated %s' "$KEYCHAIN_PASSWORD"
exit "${FIXTURE_EXIT:-0}"
''')
        stub.chmod(0o755)

    def run_archive(self, script, exit_code=0):
        return subprocess.run(['bash', 'scripts/ci/' + script], cwd=self.root,
                              env=dict(self.env, FIXTURE_EXIT=str(exit_code)), capture_output=True,
                              text=True, timeout=15)

    def assert_secrets_absent(self, text):
        for name in ['KEYCHAIN_PASSWORD', 'CERTIFICATE_PASSWORD', 'APPLE_TEAM_ID',
                     'APPLE_APP_SPECIFIC_PASSWORD']:
            self.assertNotIn(self.env[name], text)
        self.assertNotIn('credential-private', text)

    def test_full_sanitized_log_and_short_console_for_each_channel(self):
        for channel, script, log in CHANNELS:
            with self.subTest(channel=channel):
                result = self.run_archive(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                saved = self.root / 'runner' / log
                self.assertTrue(saved.exists(), 'archive must retain its complete sanitized log')
                text = saved.read_text()
                self.assertIn('EARLY ARCHIVE DIAGNOSTIC', text)
                self.assertGreater(len(text.splitlines()), 500)
                self.assertNotIn('EARLY ARCHIVE DIAGNOSTIC', result.stdout)
                self.assertLess(len(result.stdout.splitlines()), 80)
                self.assertIn('[REDACTED]', text)
                self.assert_secrets_absent(text)
                self.assert_secrets_absent(result.stdout + result.stderr)

    def test_archive_failure_keeps_exit_status_log_and_no_success_epilogue(self):
        for channel, script, log in CHANNELS:
            with self.subTest(channel=channel):
                result = self.run_archive(script, exit_code=65)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertNotIn('Archive created at:', result.stdout)
                self.assertNotIn('ARCHIVE_PATH=', (self.root / 'github-env').read_text()
                                 if (self.root / 'github-env').exists() else '')
                self.assertIn('EARLY ARCHIVE DIAGNOSTIC', (self.root / 'runner' / log).read_text())
                self.assert_secrets_absent(result.stdout + result.stderr)

    def test_sanitizer_failure_is_closed_without_raw_fallback_or_epilogue(self):
        python = self.bin / 'python3'
        python.write_text('#!/bin/bash\ncat > /dev/null\necho sanitizer-unavailable >&2\nexit 7\n')
        python.chmod(0o755)
        for channel, script, log in CHANNELS:
            with self.subTest(channel=channel):
                result = self.run_archive(script)
                self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
                self.assertNotIn('Archive created at:', result.stdout)
                self.assertNotIn('EARLY ARCHIVE DIAGNOSTIC', result.stdout)
                self.assert_secrets_absent(result.stdout + result.stderr)
                saved = self.root / 'runner' / log
                if saved.exists():
                    self.assertEqual(saved.read_bytes(), b'')

    def test_archive_arguments_are_unchanged(self):
        for channel, script, _ in CHANNELS:
            with self.subTest(channel=channel):
                result = self.run_archive(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = (self.root / 'arguments').read_bytes().decode().split('\0')[:-1]
                archive = ('photo-export.xcarchive' if channel == 'direct'
                           else 'photo-export-appstore.xcarchive')
                expected = [
                    'archive', '-project', 'fixture.xcodeproj', '-scheme', 'fixture',
                    '-configuration', 'Release', '-destination', 'platform=macOS', '-archivePath',
                    str(self.root / 'runner' / archive), 'ARCHS=arm64 x86_64', 'CODE_SIGN_STYLE=Manual',
                    ('CODE_SIGN_IDENTITY=Developer ID Application' if channel == 'direct'
                     else 'CODE_SIGN_IDENTITY=Apple Distribution'),
                    'DEVELOPMENT_TEAM=fixture-team-private',
                    f'OTHER_CODE_SIGN_FLAGS=--keychain {self.env["KEYCHAIN_PATH"]}',
                ]
                if channel == 'appstore':
                    expected += ['PRODUCT_BUNDLE_IDENTIFIER=fixture.bundle',
                                 'PROVISIONING_PROFILE_SPECIFIER=Fixture Profile']
                self.assertEqual(actual, expected + ['CURRENT_PROJECT_VERSION=42'])


class StreamingSanitizerTests(unittest.TestCase):
    def test_multiline_chunk_boundary_overlap_and_unterminated_final_line(self):
        env = dict(os.environ, KEYCHAIN_PASSWORD='boundary-secret-long',
                   CERTIFICATE_PASSWORD='boundary-secret',
                   APPLE_APP_SPECIFIC_PASSWORD='multiline\ncredential-value')
        payload = (b'x' * 8189 + b'boundary-secret-long\nmultiline\ncredential-value\n'
                   + b'y' * 8190 + b'boundary-secret-long')
        result = subprocess.run([sys.executable, str(SANITIZER)], input=payload,
                                env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = payload.replace(b'boundary-secret-long', b'[REDACTED]').replace(
            b'multiline\ncredential-value', b'[REDACTED]')
        self.assertEqual(result.stdout, expected)
        self.assertEqual(result.stderr, b'')

    def test_no_secret_values_is_lossless(self):
        payload = b'diagnostic\nfinal line without newline'
        result = subprocess.run([sys.executable, str(SANITIZER)], input=payload,
                                env={'PATH': os.environ['PATH']}, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, payload)
