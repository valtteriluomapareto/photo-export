#!/usr/bin/env python3
"""Reject direct platform IO outside named export execution boundary adapters."""
import argparse
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
from swift_source import code_only

PATTERNS = {
    'filesystem': re.compile(r'\bFileManager\b|\.\s*(?:resourceValues|checkResourceIsReachable|resolvingSymlinksInPath)\s*\('),
    'photos': re.compile(r'\bPHAsset\s*\.\s*fetch[A-Za-z_0-9]*\s*\(|\bPHAssetResource\s*\.\s*assetResources\s*\('),
    'job_metadata': re.compile(r'\bphotoLibraryService\s*\.\s*(?:fetchAssetDescriptor|resources)\s*\('),
}
# These adapters intentionally own platform calls; orchestration files receive no exemption.
BOUNDARIES = {
    'Export/FileIOService.swift': {'filesystem'},
    'Export/LocalHEICStorage.swift': {'filesystem'},
    'Export/ExportRecordsDirectoryCoordinator.swift': {'filesystem'},
    'Export/BackupScanner.swift': {'filesystem'},
    'Export/BackupScanner+Collections.swift': {'filesystem'},
    'Export/ProductionAssetResourceWriter.swift': {'photos'},
    'Export/ProductionPhotoKitReader.swift': {'photos'},
    'Export/ProductionMediaRenderer.swift': {'photos'},
    'Destination/DestinationValidationProbe.swift': {'filesystem'},
}
DESTINATION_FILES = {'ExportDestinationManager.swift', 'ExportDestinationResolver.swift',
                     'DestinationDirectoryAccess.swift', 'DestinationValidationProbe.swift'}


def picker_adapter(code):
    """Mask only explicit folder-picker identity probes, preserving source line offsets."""
    for name in ('fileResourceIdentifier', 'defaultSameFolderEvidence'):
        signature = re.search(r'\bfunc\s+' + name + r'\s*\([^{}]*\)\s*[^{}]*\{', code)
        if not signature:
            continue
        start = signature.start()
        index = signature.end()
        depth = 1
        while index < len(code) and depth:
            depth += (code[index] == '{') - (code[index] == '}')
            index += 1
        if depth:
            raise ValueError('Unterminated picker identity adapter')
        code = code[:start] + ''.join('\n' if c == '\n' else ' ' for c in code[start:index]) + code[index:]
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', nargs='?', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'photo-export')
    args = parser.parse_args()
    try:
        if not args.source_root.is_dir():
            raise ValueError(f'missing production source root: {args.source_root}')
        paths = sorted(set((args.source_root / 'Export').glob('*.swift')) |
                       {p for p in (args.source_root / 'Destination').glob('*.swift')
                        if p.name in DESTINATION_FILES})
        if not paths:
            raise ValueError('no export execution sources')
        violations = []
        for path in paths:
            name = path.relative_to(args.source_root).as_posix()
            code = code_only(path.read_text())
            if name == 'Destination/ExportDestinationManager.swift':
                code = picker_adapter(code)
            for family, pattern in PATTERNS.items():
                if family in BOUNDARIES.get(name, set()):
                    continue
                for match in pattern.finditer(code):
                    line = code.count('\n', 0, match.start()) + 1
                    violations.append(f'{path}:{line}: direct {family} IO belongs in its boundary adapter')
    except (OSError, UnicodeError, ValueError) as error:
        print(f'Export IO guard input error: {error}', file=sys.stderr)
        return 2
    if violations:
        print('\n'.join(violations), file=sys.stderr)
        return 1
    print(f'Export IO boundary guard passed ({len(paths)} Swift files).')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
