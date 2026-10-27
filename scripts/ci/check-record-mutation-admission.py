#!/usr/bin/env python3
"""Keep production store mutations inside their synchronous admitted batch."""
import pathlib
import re
import sys

from swift_source import code_only

MUTATION = re.compile(r'\b(?:markVariantInProgress|markVariantExported|markVariantFailed|'
                      r'bulkImportRecords|upsertPlacement|deletePlacement|removeVariant|'
                      r'removeRecord|retryPersistence|resetToEmpty|configure)\s*\(')
RECEIVER = re.compile(r'(?:\b(?:\w*RecordStore|timelineStore|collectionStore|'
                      r'recordStoreRouter|collections|timeline))\s*\.\s*$')
ADMISSION = re.compile(r'\b(?:with(?:Import)?MutationAdmission|'
                       r'mutationAdmission\s*\.\s*perform)\b[^{}]*$')
OWNERS = {'ExportRecordStore.swift', 'CollectionExportRecordStore.swift', 'RecordStoreRouter.swift'}


def problems(source, *, owned=False):
    code = code_only(source)
    if owned:
        return []
    stack = []
    found = []
    cursor = 0
    for match in re.finditer(r'[{}]|' + MUTATION.pattern, code):
        token = match.group()
        if token == '{':
            stack.append(bool(ADMISSION.search(code[cursor:match.start()])))
            cursor = match.end()
        elif token == '}':
            if stack:
                stack.pop()
            cursor = match.end()
        elif RECEIVER.search(code[max(0, match.start() - 100):match.start()]) and not any(stack):
            found.append((code.count('\n', 0, match.start()) + 1, token.split('(')[0].strip()))
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path('.')
    files = sorted((root / 'photo-export').rglob('*.swift'))
    if not files:
        print('No app Swift files found.', file=sys.stderr)
        return 2
    failures = []
    for path in files:
        owned = path.parent.name == 'Records' and path.name in OWNERS
        failures += [f'{path.relative_to(root)}:{line}: {name} requires mutation admission'
                     for line, name in problems(path.read_text(), owned=owned)]
    print('\n'.join(failures) if failures else 'Production store mutations use admitted batches.')
    return bool(failures)


if __name__ == '__main__':
    sys.exit(main())
