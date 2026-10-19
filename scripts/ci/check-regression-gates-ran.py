#!/usr/bin/env python3
"""Fail unless every regression gate in scripts/ci/regression-gates.txt ran and passed.

Reads `xcrun xcresulttool get test-results tests` for a result bundle (or a
pre-dumped copy of that JSON) and checks each listed row:

  gate struct Suite         the suite ran at least one test case, and no node at
                            or under it is Skipped, Failed or Expected Failure
  gate func Suite.method    at least one test case whose identifier starts with
                            "Suite/method(" ran, and no node at or under any of
                            them (argument cases, repetitions) has those results
  pin struct Suite          the suite is present in the results

Missing results, a failing xcresulttool or unreadable JSON fail the check.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

REPOSITORY = Path(__file__).resolve().parents[2]
DEFAULT_GATE_LIST = REPOSITORY / "scripts/ci/regression-gates.txt"
BAD_RESULTS = ("Skipped", "Failed", "Expected Failure")
STRUCT_DECLARATION = re.compile(r"struct [A-Za-z_][A-Za-z0-9_]*")
FUNC_DECLARATION = re.compile(r"func [A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*")
XCRESULTTOOL_TIMEOUT_SECONDS = 300


class GateListError(ValueError):
    pass


class ResultsError(ValueError):
    pass


def parse_gate_list(text, source="gate list"):
    """Parse gate rows with the same rules as check-regression-gates.sh.

    Returns (file, kind, declaration) tuples. Text from "#" to the end of a line
    is a comment, blank lines are ignored and fields are trimmed.
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


def is_suite(node, suite):
    if node.get("nodeType") != "Test Suite":
        return False
    url = node.get("nodeIdentifierURL")
    return suite in (node.get("name"), node.get("nodeIdentifier"),
                     url.rsplit("/", 1)[-1] if isinstance(url, str) else None)


def is_case(node, prefix=None):
    if node.get("nodeType") != "Test Case":
        return False
    identifier = node.get("nodeIdentifier")
    return prefix is None or (isinstance(identifier, str) and identifier.startswith(prefix))


def label(node, case):
    if isinstance(node.get("nodeIdentifier"), str):
        return node["nodeIdentifier"]
    name = node.get("name", node.get("nodeType", "node"))
    if case is None or case is node:
        return str(name)
    return f"{case.get('nodeIdentifier', case.get('name'))} [{node.get('nodeType', 'node')}: {name}]"


def bad_results(nodes):
    """List the nodes at or under `nodes` whose result is not a clean pass."""
    problems = []

    def visit(node, case):
        if node.get("nodeType") == "Test Case":
            case = node
        if node.get("result") in BAD_RESULTS:
            problems.append(f"{node['result']}: {label(node, case)}")
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
        problems = bad_results(matches)
        if problems:
            return False, summarize(problems)
        return True, f"{len(cases)} test case(s) passed"
    suite, method = symbol.split(".", 1)
    prefix = f"{suite}/{method}("
    matches = [node for node in walk(test_nodes) if is_case(node, prefix)]
    if not matches:
        return False, f"no test case with identifier {prefix}…) in the test results"
    problems = bad_results(matches)
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--result-bundle", type=Path, help="xcresult bundle to read with xcresulttool")
    inputs.add_argument("--json-file", type=Path, help="pre-dumped `get test-results tests` JSON")
    parser.add_argument("--gate-list", type=Path, default=DEFAULT_GATE_LIST)
    args = parser.parse_args(argv)
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
