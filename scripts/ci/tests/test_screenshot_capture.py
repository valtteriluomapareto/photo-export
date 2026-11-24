"""Offline checks for scripts/screenshots/capture.py with the app, screencapture and sips faked."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('capture', ROOT / 'scripts/screenshots/capture.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class FakeTime:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class FakeApp:
    """Answers `open` by writing the window file and `screencapture` by writing a frame."""

    def __init__(self, opened_surface='requested', writes_window=True):
        self.opened_surface = opened_surface
        self.writes_window = writes_window
        self.commands = []
        self.frames = 0

    def run(self, arguments, **options):
        self.commands.append(arguments)
        if arguments[0] == 'open' and self.writes_window:
            window_file = next(a.split('=', 1)[1] for a in arguments
                               if a.startswith('--screenshot-window-file='))
            requested = next(a.split('=', 1)[1] for a in arguments
                             if a.startswith('--screenshot-surface='))
            surface = requested if self.opened_surface == 'requested' else self.opened_surface
            Path(window_file).write_text(json.dumps({'window': 77, 'surface': surface}))
        if arguments[0] == 'screencapture':
            self.frames += 1
            Path(arguments[-1]).write_text(f'frame {self.frames}')
        return mock.Mock(stdout='')


class CaptureSurfaceTests(unittest.TestCase):
    def setUp(self):
        self.time = FakeTime()
        for name in ('quit_app', 'reset_domain'):
            patcher = mock.patch.object(capture, name)
            patcher.start()
            self.addCleanup(patcher.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.destination = Path(temporary.name) / 'raw.png'

    def capture(self, app, size=capture.RAW_PIXELS, same=None):
        same = same or (lambda first, second: True)
        with mock.patch.object(capture, 'run', app.run), \
                mock.patch.object(capture, 'image_size', return_value=size), \
                mock.patch.object(capture, 'same_pixels', side_effect=same):
            capture.capture_surface('timeline', self.destination,
                                    sleep=self.time.sleep, monotonic=self.time.monotonic)

    def test_saves_the_first_capture_that_matches_the_one_before(self):
        app = FakeApp()
        results = iter([False, False, True])
        self.capture(app, same=lambda first, second: next(results))
        self.assertEqual(self.destination.read_text(), 'frame 4')
        self.assertIn('-l77', next(c for c in app.commands if c[0] == 'screencapture'))
        launch = next(c for c in app.commands if c[0] == 'open')
        self.assertIn('--screenshot-mode', launch)
        self.assertIn('--screenshot-surface=timeline', launch)

    def test_a_different_opened_surface_fails_before_capturing(self):
        app = FakeApp(opened_surface=None)
        with self.assertRaisesRegex(capture.Failure, r'\[timeline\] the app opened surface None'):
            self.capture(app)
        self.assertEqual(app.frames, 0)

    def test_a_capture_of_the_wrong_size_fails(self):
        with self.assertRaisesRegex(capture.Failure, r'captured 5440x3400 .* 2x display'):
            self.capture(FakeApp(), size=(5440, 3400))
        self.assertFalse(self.destination.exists())

    def test_a_missing_window_report_times_out_naming_the_surface(self):
        app = FakeApp(writes_window=False)
        with self.assertRaisesRegex(capture.Failure, r'\[timeline\] the app did not report'):
            self.capture(app)
        self.assertGreaterEqual(self.time.now, capture.SURFACE_TIMEOUT)
        self.assertEqual(app.frames, 0)

    def test_a_window_that_keeps_changing_times_out(self):
        with self.assertRaisesRegex(capture.Failure, r'still changing'):
            self.capture(FakeApp(), same=lambda first, second: False)


class CommandLineTests(unittest.TestCase):
    def test_an_unknown_surface_exits_before_the_build(self):
        with mock.patch.object(capture, 'build') as build, \
                mock.patch.object(capture, 'require_pillow') as pillow:
            with self.assertRaises(SystemExit) as raised:
                capture.main(['timeline', 'collections-typo'])
        self.assertIn('collections-typo', str(raised.exception.code))
        build.assert_not_called()
        pillow.assert_not_called()

    def test_the_store_set_is_the_default(self):
        self.assertEqual(capture.surfaces_from([]), capture.STORE_SURFACES)
        self.assertEqual(capture.surfaces_from(['collections-favorites']),
                         ['collections-favorites'])


if __name__ == '__main__':
    unittest.main()
