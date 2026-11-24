"""Execute channel context scripts; GitHub's workflow predicates are not simulated."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class ReleaseContextTests(unittest.TestCase):
    def context(self, channel, event, ref, flag, project_version='1.6.5'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / 'photo-export.xcodeproj/project.pbxproj'
            project.parent.mkdir()
            project.write_text(f'MARKETING_VERSION = {project_version};\n' * 6)
            output = root / 'output'
            environment = dict(PATH='/usr/bin:/bin', GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                               GITHUB_RUN_NUMBER='42', GITHUB_RUN_ATTEMPT='2', GITHUB_OUTPUT=str(output))
            if flag is not None:
                environment['INPUT_DRY_RUN' if channel == 'direct' else 'INPUT_SKIP_UPLOAD'] = flag
            result = subprocess.run(['/bin/bash', str(ROOT / f'scripts/ci/release-context-{channel}.sh')],
                                    cwd=root, env=environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return dict(line.split('=', 1) for line in output.read_text().splitlines())

    def test_literal_channel_event_ref_and_version_outputs(self):
        # event, ref, input, project version, direct dry-run/create, Store upload
        cases = [
            ('push', 'refs/tags/v1.6.5', '', '1.6.5', 'false', 'true', 'true'),
            ('push', 'refs/tags/v1.7.0-beta.1', '', '1.7.0-beta.1', 'false', 'true', 'false'),
            ('push', 'refs/heads/main', 'false', '1.6.5', 'true', 'false', 'false'),
            ('workflow_dispatch', 'refs/tags/v1.6.5', 'false', '1.6.5', 'false', 'true', 'true'),
            ('workflow_dispatch', 'refs/tags/v1.7.0-beta.1', 'false', '1.7.0-beta.1', 'false', 'true', 'false'),
            ('workflow_dispatch', 'refs/heads/main', 'false', '1.6.5', 'false', 'false', 'true'),
            ('workflow_dispatch', 'refs/heads/feature/release-safety', 'false', '1.6.5', 'false', 'false', 'true'),
            ('workflow_dispatch', 'refs/heads/main', 'false', '1.7.0-beta.1', 'false', 'false', 'false'),
            ('workflow_dispatch', 'refs/tags/other', 'false', '1.6.5', 'true', 'false', 'false'),
            ('workflow_dispatch', 'refs/pull/1/merge', 'false', '1.6.5', 'true', 'false', 'false'),
        ]
        for event, ref, flag, version, dry_run, create, upload in cases:
            with self.subTest(event=event, ref=ref, flag=flag, version=version):
                tag = ref.startswith('refs/tags/v')
                direct = self.context('direct', event, ref, flag, version)
                self.assertEqual(direct, dict(is_tag=str(tag).lower(),
                    version=ref.removeprefix('refs/tags/v') if tag else '0.0.0-dev',
                    is_dry_run=dry_run, should_create_release=create))
                store = self.context('appstore', event, ref, flag, version)
                self.assertEqual(store, dict(is_tag=str(tag).lower(), version=version,
                                            should_upload=upload, build_number='42.2'))

    def test_build_only_missing_invalid_and_unsupported_events_do_not_opt_in(self):
        for event in ['workflow_dispatch', 'schedule', 'unexpected']:
            flags = [None, 'true', '', 'FALSE', 'invalid'] if event == 'workflow_dispatch' else [None, 'false']
            for ref in ['refs/heads/main', 'refs/tags/v1.6.5']:
                for flag in flags:
                    with self.subTest(event=event, ref=ref, flag=flag):
                        direct = self.context('direct', event, ref, flag)
                        self.assertEqual((direct['is_dry_run'], direct['should_create_release']), ('true', 'false'))
                        self.assertEqual(self.context('appstore', event, ref, flag)['should_upload'], 'false')

    def test_store_context_suppresses_prerelease_versions_independently_of_job_filter(self):
        for event in ['push', 'workflow_dispatch']:
            for flag in ['true', 'false', '', 'invalid']:
                with self.subTest(event=event, flag=flag):
                    store = self.context('appstore', event, 'refs/tags/v1.7.0-beta.1', flag, '1.7.0-beta.1')
                    self.assertEqual(store['should_upload'], 'false')
                    self.assertEqual(store['version'], '1.7.0-beta.1')
