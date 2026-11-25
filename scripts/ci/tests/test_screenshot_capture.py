"""Offline checks for scripts/screenshots/capture.py with the app, screencapture and sips faked."""
import importlib.util
import json
from pathlib import Path
import subprocess
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

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeApp:
    """Answers `open` by writing the window file and `screencapture` by writing a frame."""

    def __init__(self, record=None, writes_window=True, capture_fails=False):
        self.record = record
        self.writes_window = writes_window
        self.capture_fails = capture_fails
        self.commands = []
        self.frames = 0

    def run(self, arguments, check=True, **options):
        self.commands.append(arguments)
        if arguments[0] == 'open' and self.writes_window:
            value = lambda prefix: next(a.split('=', 1)[1] for a in arguments
                                        if a.startswith(prefix))
            record = self.record or {'window': 77, 'surface': value('--screenshot-surface=')}
            Path(value('--screenshot-window-file=')).write_text(json.dumps(record))
        if arguments[0] == 'screencapture':
            if self.capture_fails:
                raise subprocess.CalledProcessError(1, arguments)
            self.frames += 1
            Path(arguments[-1]).write_text(f'frame {self.frames}')
        return mock.Mock(stdout='', returncode=0)


def frame_number(path):
    return int(Path(path).stem.split('-')[1])


class CaptureSurfaceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.destination = Path(temporary.name) / 'raw.png'
        clock = FakeTime()
        for target, name, replacement in [
                (capture, 'quit_app', mock.DEFAULT), (capture, 'reset_domain', mock.DEFAULT),
                (capture.time, 'monotonic', clock.monotonic), (capture.time, 'sleep', clock.sleep)]:
            patcher = mock.patch.object(target, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.clock = clock

    def capture(self, app, size=capture.RAW_PIXELS, same=None, early_sizes=()):
        def compare(first, second):
            # Each capture is compared with the one just before it.
            self.assertEqual(frame_number(second), frame_number(first) + 1)
            return (same or (lambda: True))()
        sizes = iter(early_sizes)
        with mock.patch.object(capture, 'run', app.run), \
                mock.patch.object(capture, 'image_size',
                                  side_effect=lambda path: next(sizes, size)), \
                mock.patch.object(capture, 'same_pixels', side_effect=compare):
            capture.capture_surface('timeline', self.destination)

    def test_saves_a_capture_once_three_in_a_row_match(self):
        app = FakeApp()
        results = iter([False, True, False, True, True])
        self.capture(app, same=lambda: next(results))
        self.assertEqual(self.destination.read_text(), 'frame 6')
        self.assertIn('-l77', next(c for c in app.commands if c[0] == 'screencapture'))
        launch = next(c for c in app.commands if c[0] == 'open')
        self.assertIn('--screenshot-mode', launch)
        self.assertIn('--screenshot-surface=timeline', launch)

    def test_a_different_opened_surface_fails_before_capturing(self):
        app = FakeApp(record={'window': 77, 'surface': None})
        with self.assertRaisesRegex(capture.Failure, r'\[timeline\] the app opened surface None'):
            self.capture(app)
        self.assertEqual(app.frames, 0)

    def test_a_missing_window_fails_with_the_apps_reason(self):
        app = FakeApp(record={'window': None, 'surface': 'timeline', 'error': 'No visible window'})
        with self.assertRaisesRegex(capture.Failure, r'found no window: No visible window'):
            self.capture(app)
        self.assertEqual(app.frames, 0)

    def test_captures_before_the_resize_lands_are_skipped(self):
        self.capture(FakeApp(), early_sizes=[(2724, 1704), (2724, 1704)])
        self.assertEqual(self.destination.read_text(), 'frame 5')

    def test_a_window_that_never_reaches_the_size_fails(self):
        with self.assertRaisesRegex(capture.Failure, r'captured 5440x3400 .* 2x display'):
            self.capture(FakeApp(), size=(5440, 3400))
        self.assertGreaterEqual(self.clock.now, capture.SURFACE_TIMEOUT)
        self.assertFalse(self.destination.exists())

    def test_a_failed_screencapture_names_screen_recording(self):
        with self.assertRaisesRegex(capture.Failure, r'\[timeline\] .*Screen Recording'):
            self.capture(FakeApp(capture_fails=True))

    def test_a_missing_window_report_times_out_naming_the_surface(self):
        app = FakeApp(writes_window=False)
        with self.assertRaisesRegex(capture.Failure, r'\[timeline\] the app did not report'):
            self.capture(app)
        self.assertGreaterEqual(self.clock.now, capture.SURFACE_TIMEOUT)
        self.assertEqual(app.frames, 0)

    def test_a_window_that_keeps_changing_times_out(self):
        with self.assertRaisesRegex(capture.Failure, r'still changing'):
            self.capture(FakeApp(), same=lambda: False)


class IsolationTests(unittest.TestCase):
    def test_the_build_uses_the_separate_bundle_id(self):
        self.assertTrue(capture.BUNDLE_ID.endswith('.screenshots'))
        app = FakeApp()
        with mock.patch.object(capture, 'run', side_effect=lambda arguments, **options: (
                app.run(arguments), mock.Mock(stdout=capture.BUNDLE_ID + '\n'))[1]):
            capture.build()
        build = next(c for c in app.commands if c[0] == 'xcodebuild')
        self.assertIn(f'PRODUCT_BUNDLE_IDENTIFIER={capture.BUNDLE_ID}', build)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', build)

    def test_a_build_with_another_bundle_id_is_refused(self):
        with mock.patch.object(capture, 'run',
                               return_value=mock.Mock(stdout='com.valtteriluoma.photo-export\n')):
            with self.assertRaisesRegex(capture.Failure, 'refusing to run it'):
                capture.build()

    def test_reset_touches_only_the_capture_bundle_id(self):
        with tempfile.TemporaryDirectory() as home:
            library = Path(home) / 'Library'
            real = 'com.valtteriluoma.photo-export'
            paths = [library / 'Application Support' / capture.BUNDLE_ID,
                     library / 'Saved Application State' / f'{capture.BUNDLE_ID}.savedState',
                     library / 'Application Support' / real,
                     library / 'Saved Application State' / f'{real}.savedState']
            for path in paths:
                path.mkdir(parents=True)
            app = FakeApp()
            with mock.patch.object(capture.Path, 'home', return_value=Path(home)), \
                    mock.patch.object(capture, 'run', app.run):
                capture.reset_domain()
            self.assertEqual([path.exists() for path in paths], [False, False, True, True])
            self.assertEqual(app.commands, [
                ['defaults', 'delete', capture.BUNDLE_ID],
                ['defaults', 'write', capture.BUNDLE_ID, 'AppleLocale', 'en_US'],
                ['defaults', 'write', capture.BUNDLE_ID, 'AppleLanguages', '-array', 'en']])


class SipsTests(unittest.TestCase):
    def sips(self, *lines):
        output = '\n'.join(['/tmp/shot.png', *lines]) + '\n'
        return mock.patch.object(capture, 'run', return_value=mock.Mock(stdout=output))

    def test_reads_the_size_from_indented_sips_output(self):
        with self.sips('  pixelWidth: 2720', '  pixelHeight: 1700'):
            self.assertEqual(capture.image_size(Path('/tmp/shot.png')), (2720, 1700))

    def test_reads_alpha_from_indented_sips_output(self):
        with self.sips('  hasAlpha: yes'):
            self.assertTrue(capture.has_alpha(Path('/tmp/shot.png')))
        with self.sips('  hasAlpha: no'):
            self.assertFalse(capture.has_alpha(Path('/tmp/shot.png')))


class PadTests(unittest.TestCase):
    def pad(self, alpha):
        app = FakeApp()
        with mock.patch.object(capture, 'run', app.run), \
                mock.patch.object(capture, 'image_size', return_value=(2880, 1800)), \
                mock.patch.object(capture, 'has_alpha', return_value=alpha):
            capture.pad(Path('raw.png'), Path('01-timeline.png'))
        return app.commands[0]

    def test_pads_to_the_store_size(self):
        command = self.pad(alpha=False)
        self.assertEqual(command[command.index('--size') + 1], '2880x1800')

    def test_an_image_with_alpha_fails(self):
        with self.assertRaisesRegex(capture.Failure, 'without alpha'):
            self.pad(alpha=True)


class CommandLineTests(unittest.TestCase):
    def test_an_unknown_surface_exits_before_the_build(self):
        with mock.patch.object(capture, 'build') as build, \
                mock.patch.object(capture, 'require_pillow') as pillow:
            with self.assertRaises(SystemExit) as raised:
                capture.main(['timeline', 'collections-album-porvoo'])
        self.assertIn('collections-album-porvoo', str(raised.exception.code))
        build.assert_not_called()
        pillow.assert_not_called()

    def test_recapturing_one_surface_keeps_the_others_and_its_store_number(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            (output / '01-timeline.png').write_text('kept')
            captured = []
            with mock.patch.object(capture, 'OUTPUT', output), \
                    mock.patch.object(capture, 'REPO', output.parent), \
                    mock.patch.object(capture, 'require_pillow'), \
                    mock.patch.object(capture, 'build'), \
                    mock.patch.object(capture, 'quit_app'), \
                    mock.patch.object(capture, 'capture_surface',
                                      side_effect=lambda key, raw: raw.write_text(key)), \
                    mock.patch.object(capture, 'pad',
                                      side_effect=lambda raw, out: captured.append(out.name)):
                self.assertEqual(capture.main(['collections-favorites']), 0)
            self.assertEqual(captured, ['05-collections-favorites.png'])
            self.assertEqual((output / '01-timeline.png').read_text(), 'kept')


if __name__ == '__main__':
    unittest.main()
