#!/usr/bin/env python3
"""Run 20 manifest-selected export seam, queue-snapshot and publisher parity iterations."""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / 'scripts/ci/check-regression-gates-ran.py'
SPEC = importlib.util.spec_from_file_location('regression_gates', CHECK)
gates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gates)
sys.path.insert(0, str(CHECK.parent))
from swift_source import code_only  # noqa: E402

FAMILIES = {'AutoSyncSeamCharacterizationTests', 'ExportQueueStateSnapshotTests', 'PublisherParityTests'}


def suite(row):
    return row[2].split(' ', 1)[1].split('.', 1)[0]


def method_selector(row, root):
    method = row[2].split('.', 1)[1]
    source = code_only((root / row[0]).read_text())
    match = re.search(r'\bfunc\s+' + re.escape(method) + r'\s*\(([^)]*)\)', source)
    if not match:
        raise ValueError(f'Cannot derive the test selector for {row[2]}')
    labels = []
    for parameter in match[1].split(',') if match[1].strip() else []:
        words = parameter.split(':', 1)[0].split()
        if not words or not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', words[0]):
            raise ValueError(f'Cannot derive a parameter label for {row[2]}')
        labels.append(words[0] + ':')
    return method + '(' + ''.join(labels) + ')'


def select(rows, root):
    selected = [row for row in rows if suite(row) in FAMILIES]
    gated = {suite(row) for row in selected if row[1] == 'gate'}
    missing = FAMILIES - gated
    if missing:
        raise ValueError('Missing stress gate families: ' + ', '.join(sorted(missing)))
    whole_suites = {suite(row) for row in selected if row[1] == 'gate' and row[2].startswith('struct ')}
    selectors = []
    for row in selected:
        if row[1] != 'gate':
            continue
        name = suite(row)
        if row[2].startswith('struct '):
            selector = f'photo-exportTests/{name}'
        elif name not in whole_suites:
            selector = f'photo-exportTests/{name}/{method_selector(row, root)}'
        else:
            continue
        if selector not in selectors:
            selectors.append(selector)
    return selected, selectors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=20)
    parser.add_argument('--gate-list', type=Path, default=CHECK.with_name('regression-gates.txt'))
    parser.add_argument('--selection-only', action='store_true')
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error('--iterations must be positive')
    try:
        rows, selectors = select(gates.parse_gate_list(args.gate_list.read_text()), ROOT)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    args.output_dir = args.output_dir.resolve()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    selected_manifest = args.output_dir / 'selected-gates.txt'
    selected_manifest.write_text(''.join('|'.join(row) + '\n' for row in rows))
    if args.selection_only:
        print('\n'.join(selectors))
        return 0
    for iteration in range(1, args.iterations + 1):
        result = args.output_dir / f'iteration-{iteration:02}.xcresult'
        command = ['caffeinate', '-du', 'xcodebuild', '-project', 'photo-export.xcodeproj',
                   '-scheme', 'photo-export', '-destination', 'platform=macOS',
                   '-derivedDataPath', str(args.output_dir / 'DerivedData'),
                   '-resultBundlePath', str(result), 'CODE_SIGNING_ALLOWED=NO']
        command.extend('-only-testing:' + selector for selector in selectors)
        command.append('test' if iteration == 1 else 'test-without-building')
        with (args.output_dir / f'iteration-{iteration:02}.log').open('w') as log:
            completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            if completed.returncode:
                print(f'Iteration {iteration} failed; see {log.name}', file=sys.stderr)
                return completed.returncode
            audit = subprocess.run([sys.executable, str(CHECK), '--gate-list', str(selected_manifest),
                                    '--result-bundle', str(result)], cwd=ROOT,
                                   stdout=log, stderr=subprocess.STDOUT)
            if audit.returncode:
                print(f'Iteration {iteration} gate audit failed; see {log.name}', file=sys.stderr)
                return audit.returncode
        print(f'Iteration {iteration}/{args.iterations} passed', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
