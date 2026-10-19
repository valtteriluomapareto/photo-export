#!/usr/bin/env python3
"""Fail unless every regression gate in scripts/ci/regression-gates.txt ran and passed.

Reads `xcrun xcresulttool get test-results tests` for a result bundle (or a
pre-dumped copy of that JSON) and checks each listed row:

  gate struct Suite         the suite ran at least one test case, and every
                            "Test Case" and "Arguments" node under it Passed
  gate func Suite.method    at least one test case whose identifier starts with
                            "Suite/method(" ran, and every "Test Case" and
                            "Arguments" node at or under the matches Passed
  pin struct Suite          the suite is present in the results

A missing result or any value other than "Passed" on those nodes fails the gate.
Missing results, a failing xcresulttool or unreadable JSON fail the check.

This file also holds the only parser for the gate list; check-regression-gates.sh
reads the rows through --print-rows.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

REPOSITORY = Path(__file__).resolve().parents[2]
DEFAULT_GATE_LIST = REPOSITORY / "scripts/ci/regression-gates.txt"
RESULT_NODE_TYPES = ("Test Case", "Arguments")
STRUCT_DECLARATION = re.compile(r"struct [A-Za-z_][A-Za-z0-9_]*")
FUNC_DECLARATION = re.compile(r"func [A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*")
XCRESULTTOOL_TIMEOUT_SECONDS = 300


class GateListError(ValueError):
    pass


class ResultsError(ValueError):
    pass


def parse_gate_list(text, source="gate list"):
    """Parse gate rows into (file, kind, declaration) tuples.

    Text from "#" to the end of a line is a comment, blank lines are ignored and
    fields are trimmed. A malformed row or an empty list raises GateListError
    with one message per line.
    """
    rows, errors = [], []
    for number, line in enumerate(text.split("\n"), start=1):
        line = line.removesuffix("\r").split("#", 1)[0].strip()
        if not line:
            continue
        if line.count("|") != 2:
            errors.append(f"{source}:{number}: expected <file>|<gate|pin>|<declaration>: {line}")
            continue
        file, kind, declaration = (field.strip() for field in line.split("|"))
        if not file:
            errors.append(f"{source}:{number}: empty test file: {line}")
        elif kind not in ("gate", "pin"):
            errors.append(f"{source}:{number}: kind must be 'gate' or 'pin', not '{kind}'")
        elif kind == "pin" and not STRUCT_DECLARATION.fullmatch(declaration):
            errors.append(f"{source}:{number}: a pin must be 'struct SuiteName', not '{declaration}'")
        elif not (STRUCT_DECLARATION.fullmatch(declaration) or FUNC_DECLARATION.fullmatch(declaration)):
            errors.append(f"{source}:{number}: declaration must be 'struct SuiteName' or "
                          f"'func SuiteName.methodName', not '{declaration}'")
        else:
            rows.append((file, kind, declaration))
    if errors:
        raise GateListError("\n".join(errors))
    if not rows:
        raise GateListError(f"{source} has no rows")
    return rows


def load_results(text):
    try:
        results = json.loads(text)
    except json.JSONDecodeError as error:
        raise ResultsError(f"test results are not valid JSON: {error}") from error
    if not isinstance(results, dict) or not isinstance(results.get("testNodes"), list):
        raise ResultsError("test results have no testNodes list")
    return results["testNodes"]


def read_bundle(bundle):
    if not bundle.is_dir():
        raise ResultsError(f"result bundle {bundle} is missing")
    command = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=XCRESULTTOOL_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        raise ResultsError(f"could not run xcresulttool: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ResultsError(f"xcresulttool exited with status {result.returncode}: {detail}")
    return result.stdout


def children(node):
    items = node.get("children")
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


def walk(nodes):
    """Yield every node dictionary in the tree, at any depth."""
    stack = [node for node in reversed(nodes) if isinstance(node, dict)]
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(children(node)))


def url_path(node):
    """The node's test path from nodeIdentifierURL, without the bundle prefix or query.

    "test://com.apple.xcode/photo-export/photo-exportTests/Suite/method(x:)?args=…"
    becomes "Suite/method(x:)".
    """
    url = node.get("nodeIdentifierURL")
    if not isinstance(url, str) or not url.startswith("test://"):
        return None
    parts = url[len("test://"):].split("?", 1)[0].split("/")
    return unquote("/".join(parts[3:])) if len(parts) > 3 else None


def suite_identity(node):
    """The last segment of nodeIdentifier, else of nodeIdentifierURL, else the display name.

    `@Suite("…")` display names can replace `name`, so it is only a last resort.
    """
    if isinstance(node.get("nodeIdentifier"), str):
        return node["nodeIdentifier"].rsplit("/", 1)[-1]
    path = url_path(node)
    if path:
        return path.rsplit("/", 1)[-1]
    return node.get("name")


def case_identifier(node):
    if isinstance(node.get("nodeIdentifier"), str):
        return node["nodeIdentifier"]
    return url_path(node)


def is_suite(node, suite):
    return node.get("nodeType") == "Test Suite" and suite_identity(node) == suite


def is_case(node, prefix=None):
    if node.get("nodeType") != "Test Case":
        return False
    identifier = case_identifier(node)
    return prefix is None or (isinstance(identifier, str) and identifier.startswith(prefix))


def label(node, case):
    if node.get("nodeType") == "Test Case":
        return str(case_identifier(node) or node.get("name", "Test Case"))
    return f"{label(case, case) if case else 'test'} [{node.get('nodeType')}: {node.get('name', '?')}]"


def unpassed(nodes):
    """List the Test Case and Arguments nodes at or under `nodes` that did not pass."""
    problems = []

    def visit(node, case):
        if node.get("nodeType") == "Test Case":
            case = node
        if node.get("nodeType") in RESULT_NODE_TYPES and node.get("result") != "Passed":
            result = node.get("result")
            problems.append(f"{result if isinstance(result, str) else 'no result'}: {label(node, case)}")
        for child in children(node):
            visit(child, case)

    for node in nodes:
        visit(node, None)
    return problems


def summarize(problems, limit=5):
    shown = "; ".join(problems[:limit])
    return shown + (f"; and {len(problems) - limit} more" if len(problems) > limit else "")


def check_row(test_nodes, kind, declaration):
    """Return (ok, message) for one gate-list row."""
    keyword, symbol = declaration.split(" ", 1)
    if keyword == "struct":
        matches = [node for node in walk(test_nodes) if is_suite(node, symbol)]
        if not matches:
            return False, "suite not found in the test results"
        if kind == "pin":
            return True, "suite present"
        cases = [node for node in walk(matches) if is_case(node)]
        if not cases:
            return False, "suite has no test cases in the test results"
        problems = unpassed(matches)
        if problems:
            return False, summarize(problems)
        return True, f"{len(cases)} test case(s) passed"
    suite, method = symbol.split(".", 1)
    prefix = f"{suite}/{method}("
    matches = [node for node in walk(test_nodes) if is_case(node, prefix)]
    if not matches:
        return False, f"no test case with identifier {prefix}…) in the test results"
    problems = unpassed(matches)
    if problems:
        return False, summarize(problems)
    return True, f"{len(matches)} test case(s) passed"


def check(test_nodes, rows):
    failed = False
    for _, kind, declaration in rows:
        ok, message = check_row(test_nodes, kind, declaration)
        failed |= not ok
        print(f"  {'OK' if ok else 'FAIL'}: {kind} {declaration}: {message}")
    return not failed


def print_rows(gate_list):
    try:
        rows = parse_gate_list(gate_list.read_text(), str(gate_list))
    except (GateListError, OSError) as error:
        for line in str(error).splitlines():
            print(f"  INVALID GATE LIST: {line}", file=sys.stderr)
        return 1
    for row in rows:
        print("|".join(row))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--result-bundle", type=Path, help="xcresult bundle to read with xcresulttool")
    inputs.add_argument("--json-file", type=Path, help="pre-dumped `get test-results tests` JSON")
    inputs.add_argument("--print-rows", action="store_true",
                        help="print the gate list as <file>|<kind>|<declaration> lines and exit")
    parser.add_argument("--gate-list", type=Path, default=DEFAULT_GATE_LIST)
    args = parser.parse_args(argv)
    if args.print_rows:
        return print_rows(args.gate_list)
    source = args.json_file or args.result_bundle
    print(f"Checking that the regression gates in {args.gate_list} ran in {source}...")
    try:
        rows = parse_gate_list(args.gate_list.read_text(), str(args.gate_list))
        text = args.json_file.read_text() if args.json_file else read_bundle(args.result_bundle)
        test_nodes = load_results(text)
    except (GateListError, ResultsError, OSError) as error:
        print(f"  FAIL: {error}")
        print()
        print("Could not verify the regression gates; treating them as not run.")
        return 1
    if not check(test_nodes, rows):
        print()
        print("One or more regression gates did not run cleanly. A gate must run and pass")
        print("without being skipped. If a gate was renamed, moved or removed, update")
        print("scripts/ci/regression-gates.txt and the documented gate lists in the same PR.")
        return 1
    print("All regression gates ran and passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
