import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'run-export-seam-stress.py'
SPEC = importlib.util.spec_from_file_location('export_seam_stress', SCRIPT)
stress = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stress)


class ExportSeamStressSelectionTests(unittest.TestCase):
    def test_selection_comes_from_gate_rows_and_pins_do_not_promote_suites(self):
        rows = [
            ('Seam.swift', 'gate', 'struct AutoSyncSeamCharacterizationTests'),
            ('Seam.swift', 'gate', 'func AutoSyncSeamCharacterizationTests.addedLater'),
            ('Snapshot.swift', 'pin', 'struct ExportQueueStateSnapshotTests'),
            ('Snapshot.swift', 'gate', 'func ExportQueueStateSnapshotTests.addedLater'),
            ('Parity.swift', 'gate', 'struct PublisherParityTests'),
            ('Other.swift', 'gate', 'struct UnrelatedTests'),
        ]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Snapshot.swift').write_text('func addedLater(external internalName: Int) {}')
            selected, selectors = stress.select(rows, root)
        self.assertEqual(len(selected), 5)
        self.assertEqual(selectors, [
            'photo-exportTests/AutoSyncSeamCharacterizationTests',
            'photo-exportTests/ExportQueueStateSnapshotTests/addedLater(external:)',
            'photo-exportTests/PublisherParityTests',
        ])
        self.assertNotIn('photo-exportTests/ExportQueueStateSnapshotTests', selectors)

    def test_unrecognized_or_missing_method_signature_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'Snapshot.swift').write_text('func other() {}')
            with self.assertRaisesRegex(ValueError, 'Cannot derive the test selector'):
                stress.select([
                    ('Seam.swift', 'gate', 'struct AutoSyncSeamCharacterizationTests'),
                    ('Parity.swift', 'gate', 'struct PublisherParityTests'),
                    ('Snapshot.swift', 'gate', 'func ExportQueueStateSnapshotTests.missing'),
                ], root)

    def test_real_manifest_selection_has_only_required_gate_families(self):
        root = SCRIPT.parents[2]
        rows = stress.gates.parse_gate_list((root / 'scripts/ci/regression-gates.txt').read_text())
        selected, selectors = stress.select(rows, root)
        self.assertTrue(selected)
        self.assertTrue(any('/teardownQueue_synchronouslyClearsManagerMirrors()' in s for s in selectors))
        self.assertEqual({stress.suite(row) for row in selected}, stress.FAMILIES)
