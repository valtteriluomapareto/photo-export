"""Capture CLI regression checks run on Linux too; no GUI or Xcode required."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class CaptureCompatibilityTests(unittest.TestCase):
    def test_list_needs_no_xcode_or_gui(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/screenshots/capture.sh'), '--list'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ('timeline', 'collections-album-paris', 'dev-onboarding',
                    'dev-empty', 'dev-destination-unavailable', 'dev-paused'):
            self.assertIn(key, result.stdout)

    def test_failed_subset_does_not_delete_unrelated_capture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(ROOT / 'scripts/screenshots', root / 'scripts/screenshots')
            resources = root / 'photo-export/Resources'
            resources.mkdir(parents=True)
            catalog = ROOT / 'photo-export/Resources/screenshot-states.json'
            if catalog.exists():
                shutil.copy(catalog, resources)
            output = root / 'screenshots/1440x900'
            output.mkdir(parents=True)
            sentinel = output / '03-collections-favorites.png'
            sentinel.write_bytes(b'existing user capture')
            binary = root / 'bin'
            binary.mkdir()
            fake = binary / 'xcodebuild'
            fake.write_text('#!/bin/sh\nexit 1\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}')
            result = subprocess.run(['bash', str(root / 'scripts/screenshots/capture.sh'),
                                     '1440x900', 'timeline'], env=env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(sentinel.exists(), 'a failed subset capture deleted another surface')
            self.assertEqual(sentinel.read_bytes(), b'existing user capture')


def load_runner():
    spec = importlib.util.spec_from_file_location('capture_runner', ROOT / 'scripts/screenshots/capture.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.runner = load_runner()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'readiness.json'
        self.time = 0
        self.child = type('Child', (), {'pid': 42, 'returncode': None, 'poll': lambda child: None})()
        self.report = dict(session='current', state='dev-empty', pid=42, status='ready',
                           windowID=17, pending=[], contentReady=True, generation=3)

    def sleep(self, delay):
        self.time += delay

    def wait(self):
        return self.runner.wait_ready(self.path, 'current', 'dev-empty', self.child, 0.2,
                                      clock=lambda: self.time, sleep=self.sleep)

    def test_stale_session_state_and_pid_cannot_authorize_capture(self):
        for key, value in [('session', 'old'), ('state', 'timeline'), ('pid', 100)]:
            with self.subTest(key=key):
                self.time = 0
                report = dict(self.report, **{key: value})
                self.path.write_text(json.dumps(report))
                with self.assertRaisesRegex(RuntimeError, 'timeout.*last:'):
                    self.wait()

    def test_delayed_work_must_finish_before_ready(self):
        self.path.write_text(json.dumps(dict(self.report, status='loading', pending=['thumbnail'])))
        def sleep(delay):
            self.time += delay
            if self.time >= 0.1:
                self.path.write_text(json.dumps(self.report))
        result = self.runner.wait_ready(self.path, 'current', 'dev-empty', self.child, 0.2,
                                        clock=lambda: self.time, sleep=sleep)
        self.assertEqual(result['windowID'], 17)
        self.assertGreaterEqual(self.time, 0.1)

    def test_missing_malformed_error_and_invalid_ready_fail_closed(self):
        with self.assertRaisesRegex(RuntimeError, 'timeout'):
            self.wait()
        for value in ('{', '[]', json.dumps(dict(self.report, status='error')),
                      json.dumps(dict(self.report, pending=['image'])),
                      json.dumps(dict(self.report, windowID=True)),
                      json.dumps(dict(self.report, contentReady=False))):
            with self.subTest(report=value):
                self.time = 0
                self.path.write_text(value)
                with self.assertRaises(RuntimeError):
                    self.wait()

    def test_child_exit_is_failure_even_with_ready_file(self):
        self.path.write_text(json.dumps(self.report))
        self.child.poll = lambda: 2
        self.child.returncode = 2
        with self.assertRaisesRegex(RuntimeError, 'exited'):
            self.wait()

    def test_unknown_key_does_not_build_or_launch(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/screenshots/capture.sh'),
                                 '1440x900', 'unknown-key'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown state', result.stderr)
        self.assertNotIn('Building', result.stdout)

    def test_timeout_never_captures_and_cleans_only_owned_process(self):
        from unittest.mock import Mock, patch
        output = Path(self.temporary.name)
        target = output / 'dev-empty.png'
        target.write_bytes(b'old success')
        sibling = output / 'other.png'
        sibling.write_bytes(b'keep')
        child = Mock(pid=42)
        child.poll.return_value = None
        with patch.object(self.runner.subprocess, 'Popen', return_value=child), \
             patch.object(self.runner, 'wait_ready', side_effect=RuntimeError('timeout')), \
             patch.object(self.runner.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'timeout'):
                self.runner.capture_state(Path('/fake/app'), '1440x900',
                                          {'key': 'dev-empty', 'filename': 'dev-empty'}, output, 1)
        child.terminate.assert_called_once()
        child.wait.assert_called_once_with(timeout=5)
        self.assertFalse(target.exists())
        self.assertEqual(sibling.read_bytes(), b'keep')
        self.assertFalse(any(call.args[0][0].endswith('screencapture') for call in run.call_args_list))

    def test_readiness_change_during_capture_does_not_publish_png(self):
        from unittest.mock import Mock, patch
        child = Mock(pid=42)
        child.poll.return_value = None
        report_path = None
        def launch(arguments, **kwargs):
            nonlocal report_path
            session = next(arg.split('=', 1)[1] for arg in arguments if arg.startswith('--screenshot-session='))
            report_path = Path('/tmp') / f'photo-export-capture-{session}' / 'readiness.json'
            report_path.write_text(json.dumps(dict(self.report, session=session)))
            return child
        def run(arguments, **kwargs):
            if arguments[0].endswith('screencapture'):
                Path(arguments[-1]).write_bytes(b'captured image')
                report_path.write_text(json.dumps(dict(self.report, status='loading', pending=['late image'])))
        with patch.object(self.runner.subprocess, 'Popen', side_effect=launch), \
             patch.object(self.runner.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'readiness changed'):
                self.runner.capture_state(Path('/fake/app'), '1440x900',
                                          {'key': 'dev-empty', 'filename': 'dev-empty'},
                                          Path(self.temporary.name), 1)
        self.assertFalse((Path(self.temporary.name) / 'dev-empty.png').exists())
        child.terminate.assert_called_once()

    def test_owned_process_is_killed_and_waited_only_if_graceful_stop_times_out(self):
        from unittest.mock import Mock
        child = Mock()
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired('owned app', 5), 0]
        self.runner.stop_owned(child)
        child.terminate.assert_called_once()
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 2)

    def test_child_exit_during_capture_cannot_publish_success(self):
        from unittest.mock import Mock, patch
        child = Mock(pid=42)
        child.poll.return_value = None
        def launch(arguments, **kwargs):
            session = next(arg.split('=', 1)[1] for arg in arguments if arg.startswith('--screenshot-session='))
            report_path = Path('/tmp') / f'photo-export-capture-{session}' / 'readiness.json'
            report_path.write_text(json.dumps(dict(self.report, session=session)))
            return child
        def run(arguments, **kwargs):
            if arguments[0].endswith('screencapture'):
                Path(arguments[-1]).write_bytes(b'captured image')
                child.poll.return_value = 2
                child.returncode = 2
        with patch.object(self.runner.subprocess, 'Popen', side_effect=launch), \
             patch.object(self.runner.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'exited during capture'):
                self.runner.capture_state(Path('/fake/app'), '1440x900',
                                          {'key': 'dev-empty', 'filename': 'dev-empty'},
                                          Path(self.temporary.name), 1)
        self.assertFalse((Path(self.temporary.name) / 'dev-empty.png').exists())

    def test_success_publishes_image_and_matching_report_then_stops_owned_child(self):
        from unittest.mock import Mock, patch
        child = Mock(pid=42)
        child.poll.return_value = None
        def launch(arguments, **kwargs):
            session = next(arg.split('=', 1)[1] for arg in arguments if arg.startswith('--screenshot-session='))
            report_path = Path('/tmp') / f'photo-export-capture-{session}' / 'readiness.json'
            report_path.write_text(json.dumps(dict(self.report, session=session)))
            return child
        def run(arguments, **kwargs):
            if arguments[0].endswith('screencapture'):
                Path(arguments[-1]).write_bytes(b'controlled image')
        output = Path(self.temporary.name)
        with patch.object(self.runner.subprocess, 'Popen', side_effect=launch), \
             patch.object(self.runner.subprocess, 'run', side_effect=run):
            self.runner.capture_state(Path('/fake/app'), '1440x900',
                                      {'key': 'dev-empty', 'filename': 'dev-empty'}, output, 1)
        self.assertEqual((output / 'dev-empty.png').read_bytes(), b'controlled image')
        report = json.loads((output / 'dev-empty.json').read_text())
        self.assertEqual(report['state'], 'dev-empty')
        self.assertEqual(report['pid'], child.pid)
        child.terminate.assert_called_once()
        self.assertFalse((Path('/tmp') / f'photo-export-capture-{report["session"]}').exists())
