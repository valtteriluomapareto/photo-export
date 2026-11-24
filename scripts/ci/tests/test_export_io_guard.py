"""Keep direct platform IO at named export boundaries, including future export files."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'check-export-io-boundaries.py'


class ExportIOGuardTests(unittest.TestCase):
    def run_guard(self, files):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            return subprocess.run([sys.executable, '-B', str(SCRIPT), str(root)],
                                  capture_output=True, text=True)

    def test_direct_io_in_new_export_file_is_rejected(self):
        for expression in ['FileManager.default.fileExists(atPath: p)',
                           'url.resourceValues(forKeys: [.fileSizeKey])',
                           'url.checkResourceIsReachable()',
                           'PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)',
                           'PHAssetResource.assetResources(for: asset)',
                           'photoLibraryService.fetchAssetDescriptor(for: id)',
                           'photoLibraryService.resources(for: id)']:
            with self.subTest(expression=expression):
                result = self.run_guard({'Export/NewPlanner.swift': expression})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('NewPlanner.swift:1:', result.stderr)

    def test_explicit_boundaries_allow_only_their_operation(self):
        allowed = {
            'Export/FileIOService.swift': 'FileManager.default.removeItem(at: url)',
            'Export/ProductionAssetResourceWriter.swift': 'PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)',
            'Destination/DestinationValidationProbe.swift': 'url.resourceValues(forKeys: [])',
            'Export/ProductionPhotoKitReader.swift': 'PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)\nPHAssetResource.assetResources(for: asset)',
        }
        self.assertEqual(self.run_guard(allowed).returncode, 0)
        allowed['Export/ProductionAssetResourceWriter.swift'] += '\nFileManager.default.removeItem(at: url)'
        self.assertEqual(self.run_guard(allowed).returncode, 1)

    def test_picker_adapter_is_function_scoped_and_comments_are_ignored(self):
        permitted = 'private static func fileResourceIdentifier(of url: URL) -> String { url.resourceValues(forKeys: []) }'
        result = self.run_guard({'Destination/ExportDestinationManager.swift': permitted,
                                 'Export/NewPlanner.swift': '// FileManager.default\nlet message = "PHAsset.fetchAssets()"'})
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_guard({'Destination/ExportDestinationManager.swift': permitted + '\nfunc prepare() { url.resourceValues(forKeys: []) }'})
        self.assertEqual(result.returncode, 1)


if __name__ == '__main__':
    unittest.main()
