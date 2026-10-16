#!/usr/bin/env python3
"""Owned-process Release captures; no capture is allowed by an elapsed delay."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / 'photo-export/Resources/screenshot-states.json'


def catalog():
    states = json.loads(CATALOG.read_text())
    keys = [state['key'] for state in states]
    names = [state['filename'] for state in states]
    if len(set(keys)) != len(keys) or len(set(names)) != len(names):
        raise ValueError('duplicate capture state or filename')
    if any(not re.fullmatch(r'[a-z0-9-]+', value) for value in keys + names):
        raise ValueError('invalid capture state or filename')
    return states


def wait_ready(path, session, state, child, timeout, *, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    last = 'no readiness report'
    while clock() < deadline:
        if child.poll() is not None:
            raise RuntimeError(f'{state}: app PID {child.pid} exited ({child.returncode}); last: {last}')
        if path.exists():
            try:
                report = json.loads(path.read_text())
            except (OSError, ValueError) as error:
                raise RuntimeError(f'{state}: unreadable readiness report: {error}') from error
            last = repr(report)
            if not isinstance(report, dict):
                raise RuntimeError(f'{state}: malformed readiness report: {last}')
            identity = (report.get('session'), report.get('state'), report.get('pid'))
            if identity == (session, state, child.pid):
                if report.get('status') == 'error':
                    raise RuntimeError(f'{state}: readiness failed: {last}')
                if report.get('status') == 'ready':
                    window = report.get('windowID')
                    if (type(window) is not int or window <= 0 or report.get('pending') != []
                            or report.get('contentReady') is not True
                            or type(report.get('generation')) is not int):
                        raise RuntimeError(f'{state}: invalid ready report: {last}')
                    return report
        sleep(0.05)
    raise RuntimeError(f'{state}: readiness timeout after {timeout}s (PID {child.pid}); last: {last}')


def stop_owned(child):
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def capture_state(executable, size, state, output, timeout):
    session = str(uuid.uuid4()).upper()
    scratch = Path('/tmp') / f'photo-export-capture-{session}'
    scratch.mkdir(mode=0o700)
    report_path = scratch / 'readiness.json'
    target = output / f'{state["filename"]}.png'
    temporary = output / f'.{state["filename"]}.{session}.png'
    log_path = output / f'{state["filename"]}.log'
    evidence = output / f'{state["filename"]}.json'
    # Failed recaptures must not leave an old image masquerading as this run.
    for path in (target, temporary, evidence):
        path.unlink(missing_ok=True)
    width, height = size.split('x')
    child = None
    try:
        with log_path.open('w') as log:
            child = subprocess.Popen([str(executable), '--screenshot-mode',
                                      f'--screenshot-session={session}',
                                      f'--screenshot-surface={state["key"]}',
                                      f'--screenshot-width={width}', f'--screenshot-height={height}',
                                      '-ApplePersistenceIgnoreState', 'YES'], stdout=log, stderr=log)
            report = wait_ready(report_path, session, state['key'], child, timeout)
            subprocess.run(['/usr/sbin/screencapture', '-t', 'png', '-o',
                            f'-l{report["windowID"]}', str(temporary)], check=True)
            if child.poll() is not None:
                raise RuntimeError(f'{state["key"]}: app PID {child.pid} exited during capture ({child.returncode})')
            if json.loads(report_path.read_text()) != report:
                raise RuntimeError(f'{state["key"]}: readiness changed during capture; retry after inspecting diagnostics')
            if not temporary.is_file() or temporary.stat().st_size == 0:
                raise RuntimeError('screencapture produced no image')
            temporary.replace(target)
            evidence.write_text(json.dumps(report, indent=2) + '\n')
            print(f'{state["key"]}: {target}', flush=True)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        target.unlink(missing_ok=True)
        if report_path.exists():
            shutil.copyfile(report_path, evidence)
        print(f'Diagnostics: {log_path}; readiness: {evidence}', file=sys.stderr)
        if log_path.exists():
            print(log_path.read_text(errors='replace')[-4000:], file=sys.stderr)
        raise
    finally:
        if child is not None:
            stop_owned(child)
        temporary.unlink(missing_ok=True)
        shutil.rmtree(scratch)
        # The suite is exclusively owned by this UUID. Wait for the child first.
        subprocess.run(['/usr/bin/defaults', 'delete', f'com.valtteriluoma.photo-export.capture.{session}'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--list', action='store_true', help='list states without building')
    parser.add_argument('--timeout', type=float, default=30, help='readiness deadline in seconds')
    parser.add_argument('size', nargs='?', default='2880x1800')
    parser.add_argument('states', nargs='*')
    args = parser.parse_args()
    states = catalog()
    if args.list:
        for state in states:
            print(f'{state["key"]:48} {state["kind"]}' + (' (default)' if state['default'] else ''))
        return 0
    if (not re.fullmatch(r'[1-9][0-9]{2,3}x[1-9][0-9]{2,3}', args.size)
            or not 0 < args.timeout <= 300):
        parser.error('expected WIDTHxHEIGHT (100–9999) and timeout in (0, 300]')
    by_key = {state['key']: state for state in states}
    unknown = set(args.states) - by_key.keys()
    if unknown:
        parser.error(f'unknown state(s): {", ".join(sorted(unknown))}; use --list')
    selected = [by_key[key] for key in dict.fromkeys(args.states)] if args.states else [
        state for state in states if state['default']]
    derived = ROOT / 'build/screenshots'
    print('Building Photo Export (Release, no signing)', flush=True)
    subprocess.run(['xcodebuild', '-project', 'photo-export.xcodeproj', '-scheme', 'photo-export',
                    '-configuration', 'Release', '-destination', 'platform=macOS',
                    '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO', 'build'],
                   cwd=ROOT, stdout=subprocess.DEVNULL, check=True)
    executable = derived / 'Build/Products/Release/Photo Export.app/Contents/MacOS/Photo Export'
    output = ROOT / 'screenshots' / args.size
    output.mkdir(parents=True, exist_ok=True)
    for state in selected:
        capture_state(executable, args.size, state, output, args.timeout)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Capture failed: {error}', file=sys.stderr)
        sys.exit(1)
