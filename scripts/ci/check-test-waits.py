#!/usr/bin/env python3
"""Keep test waits progress-based and backstopped (issue #277).

On the 3-vCPU CI runner every test shares one congested main actor, so a wait
that gives up after a fixed wall-clock deadline measures scheduler load rather
than progress. Tests wait with `eventually` (or `AsyncCheckpoint.waitForEnter`)
and rely on their `.timeLimit` as the hang backstop instead.

This is a lexical guard over comment- and string-masked source:
- no `< deadline` comparisons outside the allow-listed anti-hang backstops;
- every test file that calls `eventually(` declares a `.timeLimit(`.
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402

TESTS = pathlib.Path("photo-exportTests")
# Anti-hang backstops, not progress oracles.
DEADLINE_ALLOWED = {
    TESTS / "TestHelpers" / "TestWait.swift",
    TESTS / "TestHelpers" / "ExportManager+TestWait.swift",
}
DEADLINE = re.compile(r"<\s*deadline\b")
EVENTUALLY = re.compile(r"(?<![\w.])eventually\s*\(")
TIME_LIMIT = re.compile(r"\.timeLimit\s*\(")


def problems(root):
    found = []
    for path in sorted((root / TESTS).rglob("*.swift")):
        relative = path.relative_to(root)
        code = code_only(path.read_text())
        if relative not in DEADLINE_ALLOWED:
            for match in DEADLINE.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                found.append(
                    f"{relative}:{line}: wall-clock deadline wait; use eventually or "
                    "AsyncCheckpoint.waitForEnter with the test's .timeLimit as backstop")
        if relative.parent != TESTS / "TestHelpers" and EVENTUALLY.search(code):
            if not TIME_LIMIT.search(code):
                found.append(
                    f"{relative}: calls eventually( but declares no .timeLimit( backstop")
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    print(f"Checking test waits under {root / TESTS} ...")
    found = problems(root)
    for problem in found:
        print(f"  {problem}")
    if found:
        print(f"{len(found)} test-wait problem(s) found.")
        return 1
    print("Test waits are progress-based and backstopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
