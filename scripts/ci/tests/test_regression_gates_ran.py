"""Run the regression-gate result check against recorded xcresulttool output.

fixtures/xcresult-test-results.json is cut down from real
`xcrun xcresulttool get test-results tests` output, recorded on 2026-10-19 with
Xcode 27.0 (27A266a) on macOS 26.6.2 from a passing full-suite run. Only the
device identifier was replaced. The shapes seen locally:

- Test Plan > Unit test bundle > Test Suite > Test Case. Suites carry `name` and
  `nodeIdentifierURL` but no `nodeIdentifier`; cases carry `nodeIdentifier`
  such as "Suite/method(argument:)".
- A parameterized case has one "Arguments" child per argument, with a result and
  a `nodeIdentifierURL` but no `nodeIdentifier`.
- A known issue makes the case's result "Expected Failure" and adds
  "Expected Failure" children that have no result.

The parser was also confirmed on CI with Xcode 16.2 (xcresulttool 23500):
a `.disabled` case was reported as "Skipped" with a "Failure Message" child, the
suite gate failed on it, and every other row, including the method rows matched
by `nodeIdentifier`, was OK
(https://github.com/valtteriluomapareto/photo-export/actions/runs/39301325072).

Skipped cases, missing or "unknown" results, cases without `nodeIdentifier`,
repetitions and device nodes are built in-test from the node and result types
in xcresulttool's own schema.
"""

import copy
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
CHECK = CI_DIRECTORY / "check-regression-gates-ran.py"
GATE_LIST = CI_DIRECTORY / "regression-gates.txt"
FIXTURE = json.loads((pathlib.Path(__file__).resolve().parent / "fixtures/xcresult-test-results.json").read_text())

SPEC = importlib.util.spec_from_file_location("check_regression_gates_ran", CHECK)
gates_ran = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gates_ran)

FIXTURE_GATES = """\
photo-exportTests/AutoSyncSeamCharacterizationTests.swift|gate|struct AutoSyncSeamCharacterizationTests
photo-exportTests/ExportQueueStateSnapshotTests.swift|pin|struct ExportQueueStateSnapshotTests
photo-exportTests/ExportQueueStateSnapshotTests.swift|gate|func ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors
photo-exportTests/ImportIdempotencyTests.swift|gate|struct ImportIdempotencyTests
photo-exportTests/AutoSyncRunDirtyBoundaryTests.swift|gate|func AutoSyncRunDirtyBoundaryTests.unsuccessfulRunNeverAcknowledgesDirtyWork
photo-exportTests/FileBackedAutoSyncDirtyStateStoreTests.swift|gate|func FileBackedAutoSyncDirtyStateStoreTests.deleteIsNoOpWhenFileMissing
"""

# Comments, blank and indented lines, tabs, an inline comment, a CRLF ending and
# no trailing newline.
TRICKY_LIST = (
    "# leading comment\n"
    "\n"
    "   \n"
    "photo-exportTests/A.swift|gate|struct ASuite\n"
    "  photo-exportTests/B.swift | pin | struct BSuite  \n"
    "\t# indented comment\n"
    "photo-exportTests/B.swift|gate|func BSuite.method_one   # trailing comment\n"
    "photo-exportTests/C.swift\t|\tgate\t|\tfunc CSuite.methodTwo\r\n"
    "\n"
    "photo-exportTests/D.swift|gate|struct DSuite"
)


def nodes(tree):
    return list(gates_ran.walk(tree["testNodes"]))


def suite(tree, name):
    return next(node for node in nodes(tree) if node.get("nodeType") == "Test Suite" and node["name"] == name)


def case(tree, identifier):
    return next(node for node in nodes(tree) if node.get("nodeIdentifier") == identifier)


def add_case(tree, suite_name, method):
    """Add a passing case shaped like the recorded seam cases."""
    target = suite(tree, suite_name)
    added = copy.deepcopy(target["children"][0])
    added.update(name=f"{method}()", nodeIdentifier=f"{suite_name}/{method}()",
                 nodeIdentifierURL=f"test://com.apple.xcode/photo-export/photo-exportTests/{suite_name}/{method}()")
    target["children"].append(added)


def add_suite(tree, suite_name, *methods):
    """Add a passing suite beside an existing one, holding one case per method."""
    template = suite(tree, "ImportIdempotencyTests")
    parent = next(node for node in nodes(tree) if template in node.get("children", []))
    added = copy.deepcopy(template)
    added.update(name=suite_name, nodeIdentifier=suite_name, children=[])
    if "nodeIdentifierURL" in template:
        added["nodeIdentifierURL"] = f"test://com.apple.xcode/photo-export/photo-exportTests/{suite_name}"
    added["children"].append(copy.deepcopy(template["children"][0]))
    parent["children"].append(added)
    first, *rest = methods
    only = added["children"][0]
    only.update(name=f"{first}()", nodeIdentifier=f"{suite_name}/{first}()",
                nodeIdentifierURL=f"test://com.apple.xcode/photo-export/photo-exportTests/{suite_name}/{first}()")
    for method in rest:
        add_case(tree, suite_name, method)


class GateResultCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.results = copy.deepcopy(FIXTURE)

    def run_check(self, gates=FIXTURE_GATES, results=None, text=None, extra_args=(), env=None):
        gate_list = self.root / "regression-gates.txt"
        gate_list.write_text(gates)
        if extra_args:
            source = list(extra_args)
        else:
            dump = self.root / "tests.json"
            dump.write_text(text if text is not None else json.dumps(results or self.results))
            source = ["--json-file", str(dump)]
        return subprocess.run([sys.executable, "-B", str(CHECK), *source, "--gate-list", str(gate_list)],
                              capture_output=True, text=True, env=env, timeout=30)

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All regression gates ran and passed.", result.stdout)
        self.assertNotIn("FAIL", result.stdout)

    def assert_fails(self, result, *diagnostics):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("All regression gates ran and passed.", result.stdout)
        for diagnostic in diagnostics:
            self.assertIn(diagnostic, result.stdout)

    def test_all_passed(self):
        result = self.run_check()
        self.assert_passes(result)
        self.assertIn("OK: gate struct AutoSyncSeamCharacterizationTests: 2 test case(s) passed", result.stdout)
        self.assertIn("OK: pin struct ExportQueueStateSnapshotTests: suite present", result.stdout)
        self.assertIn("OK: gate func AutoSyncRunDirtyBoundaryTests.unsuccessfulRunNeverAcknowledgesDirtyWork: "
                      "1 test case(s) passed", result.stdout)

    def test_real_gate_list_passes_when_every_gate_ran(self):
        for method in ("autoSyncRunYieldsCanonicalSequence", "manualExportSupersedingAutoSyncYieldsCanonicalSequence"):
            add_case(self.results, "AutoSyncSeamCharacterizationTests", method)
        add_suite(self.results, "AmbiguousSameFolderTests",
                  "sameFolderForUnclearPickHoldsAutoExportUntilHistoryCheckEnds")
        self.assert_passes(self.run_check(gates=GATE_LIST.read_text()))

    def test_real_gate_list_fails_without_the_new_seam_cases(self):
        self.assert_fails(self.run_check(gates=GATE_LIST.read_text()),
                          "FAIL: gate func AutoSyncSeamCharacterizationTests.autoSyncRunYieldsCanonicalSequence: "
                          "no test case with identifier "
                          "AutoSyncSeamCharacterizationTests/autoSyncRunYieldsCanonicalSequence(…)")

    def test_skipped_case_under_suite_gate_fails(self):
        skipped = case(self.results, "ImportIdempotencyTests/bulkImportIsIdempotent()")
        skipped["result"] = "Skipped"
        # Xcode 16.2 reports a disabled case with a "Failure Message" child; its
        # result field, if any, is not what decides the gate.
        skipped["children"] = [{"name": "Test skipped: disabled", "nodeType": "Failure Message",
                                "result": "Passed"}]
        self.assert_fails(self.run_check(),
                          "FAIL: gate struct ImportIdempotencyTests: Skipped: ImportIdempotencyTests/bulkImportIsIdempotent()")

    def test_failed_case_under_suite_gate_fails(self):
        case(self.results, "AutoSyncSeamCharacterizationTests/manualExportThenImportYieldsCanonicalSequence()")["result"] = "Failed"
        self.assert_fails(self.run_check(), "FAIL: gate struct AutoSyncSeamCharacterizationTests: Failed: "
                          "AutoSyncSeamCharacterizationTests/manualExportThenImportYieldsCanonicalSequence()")

    def test_case_without_a_result_fails(self):
        del case(self.results, "ImportIdempotencyTests/bulkImportIsIdempotent()")["result"]
        self.assert_fails(self.run_check(), "FAIL: gate struct ImportIdempotencyTests: no result: "
                          "ImportIdempotencyTests/bulkImportIsIdempotent()")

    def test_unknown_result_fails(self):
        case(self.results, "ExportQueueStateSnapshotTests/teardownQueue_synchronouslyClearsManagerMirrors()")[
            "result"] = "unknown"
        self.assert_fails(self.run_check(), "FAIL: gate func ExportQueueStateSnapshotTests."
                          "teardownQueue_synchronouslyClearsManagerMirrors: unknown: "
                          "ExportQueueStateSnapshotTests/teardownQueue_synchronouslyClearsManagerMirrors()")

    def test_argument_without_a_result_fails(self):
        parameterized = case(self.results, "AutoSyncRunDirtyBoundaryTests/unsuccessfulRunNeverAcknowledgesDirtyWork(result:)")
        del parameterized["children"][2]["result"]
        self.assert_fails(self.run_check(), "no result: AutoSyncRunDirtyBoundaryTests/"
                          "unsuccessfulRunNeverAcknowledgesDirtyWork(result:) [Arguments: .interrupted]")

    def test_results_on_other_node_types_are_ignored(self):
        suite(self.results, "ImportIdempotencyTests")["result"] = "Skipped"
        case(self.results, "ImportIdempotencyTests/bulkImportIsIdempotent()")["children"] = [
            {"name": "note", "nodeType": "Failure Message", "result": "Failed"}]
        self.assert_passes(self.run_check())

    def test_case_without_identifier_matches_through_its_url(self):
        for identifier in ("ExportQueueStateSnapshotTests/teardownQueue_synchronouslyClearsManagerMirrors()",
                           "AutoSyncRunDirtyBoundaryTests/unsuccessfulRunNeverAcknowledgesDirtyWork(result:)"):
            del case(self.results, identifier)["nodeIdentifier"]
        tree = nodes(self.results)
        self.assertFalse(any(node.get("nodeIdentifier", "").startswith("ExportQueueStateSnapshotTests/teardown")
                             for node in tree))
        result = self.run_check()
        self.assert_passes(result)
        self.assertIn("OK: gate func ExportQueueStateSnapshotTests.teardownQueue_synchronouslyClearsManagerMirrors: "
                      "1 test case(s) passed", result.stdout)
        teardown = next(node for node in nodes(self.results)
                        if node.get("name") == "teardownQueue_synchronouslyClearsManagerMirrors()")
        teardown["result"] = "Skipped"
        self.assert_fails(self.run_check(), "Skipped: ExportQueueStateSnapshotTests/"
                          "teardownQueue_synchronouslyClearsManagerMirrors()")

    def test_missing_suite_fails(self):
        bundle = self.results["testNodes"][0]["children"][0]
        bundle["children"] = [node for node in bundle["children"] if node["name"] != "ImportIdempotencyTests"]
        self.assert_fails(self.run_check(), "FAIL: gate struct ImportIdempotencyTests: suite not found")

    def test_suite_with_no_cases_fails(self):
        for emptied in ([], None):
            with self.subTest(children=emptied):
                results = copy.deepcopy(FIXTURE)
                target = suite(results, "ImportIdempotencyTests")
                if emptied is None:
                    del target["children"]
                else:
                    target["children"] = emptied
                self.assert_fails(self.run_check(results=results),
                                  "FAIL: gate struct ImportIdempotencyTests: suite has no test cases")

    def test_pin_requires_only_the_suite(self):
        case(self.results, "ExportQueueStateSnapshotTests/pauseResumeCancelStateSnapshot_canonicalTransitions()")[
            "result"] = "Skipped"
        self.assert_passes(self.run_check())
        bundle = self.results["testNodes"][0]["children"][0]
        bundle["children"] = [node for node in bundle["children"] if node["name"] != "ExportQueueStateSnapshotTests"]
        self.assert_fails(self.run_check(), "FAIL: pin struct ExportQueueStateSnapshotTests: suite not found")

    def test_suite_matches_its_identifier_url_when_the_name_differs(self):
        suite(self.results, "ImportIdempotencyTests")["name"] = "Import idempotency"
        self.assert_passes(self.run_check())

    def test_suite_identifier_takes_precedence_over_the_name(self):
        target = suite(self.results, "ImportIdempotencyTests")
        target["nodeIdentifier"] = "photo-exportTests/ImportIdempotencyTests"
        del target["nodeIdentifierURL"]
        target["name"] = "Import idempotency"
        self.assert_passes(self.run_check())
        target["nodeIdentifier"] = "OtherTests"
        target["name"] = "ImportIdempotencyTests"
        self.assert_fails(self.run_check(), "FAIL: gate struct ImportIdempotencyTests: suite not found")

    def test_display_name_cannot_stand_in_for_a_different_suite(self):
        other = suite(self.results, "FileBackedAutoSyncRunSummaryStoreTests")
        other["name"] = "ImportIdempotencyTests"
        bundle = self.results["testNodes"][0]["children"][0]
        bundle["children"] = [node for node in bundle["children"]
                              if node.get("nodeIdentifierURL", "").rsplit("/", 1)[-1] != "ImportIdempotencyTests"]
        self.assert_fails(self.run_check(), "FAIL: gate struct ImportIdempotencyTests: suite not found")

    def test_suite_name_is_used_when_no_identifier_exists(self):
        del suite(self.results, "ImportIdempotencyTests")["nodeIdentifierURL"]
        self.assert_passes(self.run_check())

    def test_parameterized_method_with_one_skipped_argument_fails(self):
        parameterized = case(self.results, "AutoSyncRunDirtyBoundaryTests/unsuccessfulRunNeverAcknowledgesDirtyWork(result:)")
        self.assertEqual([child["nodeType"] for child in parameterized["children"]], ["Arguments"] * 3)
        parameterized["children"][1]["result"] = "Skipped"
        self.assert_fails(self.run_check(),
                          "FAIL: gate func AutoSyncRunDirtyBoundaryTests.unsuccessfulRunNeverAcknowledgesDirtyWork: "
                          "Skipped: AutoSyncRunDirtyBoundaryTests/unsuccessfulRunNeverAcknowledgesDirtyWork(result:) "
                          "[Arguments: .failed]")

    def test_method_gate_counts_only_its_qualifying_suite(self):
        case(self.results, "FileBackedAutoSyncRunSummaryStoreTests/deleteIsNoOpWhenFileMissing()")["result"] = "Skipped"
        self.assert_passes(self.run_check())
        case(self.results, "FileBackedAutoSyncDirtyStateStoreTests/deleteIsNoOpWhenFileMissing()")["result"] = "Skipped"
        self.assert_fails(self.run_check(), "Skipped: FileBackedAutoSyncDirtyStateStoreTests/deleteIsNoOpWhenFileMissing()")

    def test_method_gate_is_missing_when_only_another_suite_has_the_name(self):
        suite(self.results, "FileBackedAutoSyncDirtyStateStoreTests")["children"] = []
        self.assert_fails(self.run_check(),
                          "FAIL: gate func FileBackedAutoSyncDirtyStateStoreTests.deleteIsNoOpWhenFileMissing: "
                          "no test case with identifier")

    def test_method_gate_does_not_match_a_longer_method_name(self):
        renamed = case(self.results, "FileBackedAutoSyncDirtyStateStoreTests/deleteIsNoOpWhenFileMissing()")
        renamed["nodeIdentifier"] = "FileBackedAutoSyncDirtyStateStoreTests/deleteIsNoOpWhenFileMissingExtra()"
        self.assert_fails(self.run_check(), "no test case with identifier")

    def test_expected_failure_fails(self):
        recorded = case(self.results,
                        "ExpectationReflectionSafetyTests/failingExpectationsOnCycleRootsRecordInsteadOfCrashing()")
        self.assertEqual({child["nodeType"] for child in recorded["children"]}, {"Expected Failure"})
        gates = FIXTURE_GATES + ("photo-exportTests/ExpectationReflectionSafetyTests.swift|gate|"
                                 "func ExpectationReflectionSafetyTests.failingExpectationsOnCycleRootsRecordInsteadOfCrashing\n")
        self.assert_fails(self.run_check(gates=gates), "Expected Failure: ExpectationReflectionSafetyTests/"
                          "failingExpectationsOnCycleRootsRecordInsteadOfCrashing()")
        case(self.results, "ImportIdempotencyTests/importStageSequenceMatchesContract()")["result"] = "Expected Failure"
        self.assert_fails(self.run_check(), "FAIL: gate struct ImportIdempotencyTests: Expected Failure: "
                          "ImportIdempotencyTests/importStageSequenceMatchesContract()")

    def test_nested_repetition_and_run_nodes(self):
        # Wrap the bundle in device and configuration nodes, add unknown node types
        # and keys, and give a gate case repetition and run children.
        plan = self.results["testNodes"][0]
        plan["children"] = [{"name": "My Mac", "nodeType": "Device", "futureKey": {"x": 1}, "children": [
            {"name": "Configuration 1", "nodeType": "Test Plan Configuration", "children": [
                {"name": "Grouping", "nodeType": "Future Node Type", "children": plan["children"]}]}]}]
        teardown = case(self.results, "ExportQueueStateSnapshotTests/teardownQueue_synchronouslyClearsManagerMirrors()")
        teardown["children"] = [
            {"name": f"Repetition {index}", "nodeType": "Repetition", "result": "Passed", "children": [
                {"name": "Run 1", "nodeType": "Test Case Run", "result": "Passed", "children": [
                    {"name": "attachment.txt", "nodeType": "Attachment"}]}]}
            for index in (1, 2)]
        self.assert_passes(self.run_check())
        teardown["children"][1]["children"][0]["children"].append(
            {"name": "x: 2", "nodeType": "Arguments", "result": "Skipped"})
        self.assert_fails(self.run_check(),
                          "Skipped: ExportQueueStateSnapshotTests/teardownQueue_synchronouslyClearsManagerMirrors() "
                          "[Arguments: x: 2]")

    def test_tolerates_malformed_children(self):
        suite(self.results, "AutoSyncSeamCharacterizationTests")["children"].extend(["text", 3, None])
        self.results["testNodes"].append("not a node")
        case(self.results, "ImportIdempotencyTests/bulkImportIsIdempotent()")["children"] = {"unexpected": "shape"}
        self.assert_passes(self.run_check())

    def test_bad_json_fails_closed(self):
        self.assert_fails(self.run_check(text="{not json"), "FAIL: test results are not valid JSON")

    def test_missing_test_nodes_fails_closed(self):
        for text in ('{"devices": []}', '{"testNodes": {}}', "[]", ""):
            with self.subTest(text=text):
                self.assert_fails(self.run_check(text=text), "FAIL: test results")

    def test_invalid_gate_list_fails_closed(self):
        self.assert_fails(self.run_check(gates="photo-exportTests/A.swift|struct ASuite\n"),
                          "FAIL: ", "expected <file>|<gate|pin>|<declaration>")
        self.assert_fails(self.run_check(gates="# nothing\n"), "has no rows")

    def fake_xcrun(self, body):
        bin_directory = self.root / "bin"
        bin_directory.mkdir(exist_ok=True)
        xcrun = bin_directory / "xcrun"
        xcrun.write_text(f"#!/bin/bash\nprintf '%s\\n' \"$@\" > '{self.root / 'xcrun-args'}'\n{body}\n")
        xcrun.chmod(0o755)
        bundle = self.root / "TestResults.xcresult"
        bundle.mkdir(exist_ok=True)
        environment = dict(os.environ, PATH=f"{bin_directory}{os.pathsep}{os.environ.get('PATH', '')}")
        return ["--result-bundle", str(bundle)], environment

    def test_reads_the_bundle_through_xcresulttool(self):
        dump = self.root / "dump.json"
        dump.write_text(json.dumps(self.results))
        args, environment = self.fake_xcrun(f"cat '{dump}'")
        self.assert_passes(self.run_check(extra_args=args, env=environment))
        self.assertEqual((self.root / "xcrun-args").read_text().splitlines(),
                         ["xcresulttool", "get", "test-results", "tests", "--path", args[1]])

    def test_xcresulttool_failure_fails_closed(self):
        args, environment = self.fake_xcrun('echo \'{"testNodes": []}\'\necho "Error: bundle unreadable" >&2\nexit 3')
        self.assert_fails(self.run_check(extra_args=args, env=environment),
                          "FAIL: xcresulttool exited with status 3: Error: bundle unreadable")

    def test_missing_result_bundle_fails_closed(self):
        self.assert_fails(self.run_check(extra_args=["--result-bundle", str(self.root / "absent.xcresult")]),
                          "FAIL: result bundle", "is missing")


class GateListReaderTests(unittest.TestCase):
    def print_rows(self, text):
        with tempfile.TemporaryDirectory() as directory:
            gate_list = pathlib.Path(directory) / "gates.txt"
            gate_list.write_bytes(text.encode())
            return subprocess.run([sys.executable, "-B", str(CHECK), "--print-rows", "--gate-list", str(gate_list)],
                                  capture_output=True, text=True, timeout=30)

    def test_print_rows_skips_comments_and_blank_lines(self):
        expected = [
            ("photo-exportTests/A.swift", "gate", "struct ASuite"),
            ("photo-exportTests/B.swift", "pin", "struct BSuite"),
            ("photo-exportTests/B.swift", "gate", "func BSuite.method_one"),
            ("photo-exportTests/C.swift", "gate", "func CSuite.methodTwo"),
            ("photo-exportTests/D.swift", "gate", "struct DSuite"),
        ]
        self.assertFalse(TRICKY_LIST.endswith("\n"))
        self.assertEqual(gates_ran.parse_gate_list(TRICKY_LIST), expected)
        result = self.print_rows(TRICKY_LIST)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([tuple(line.split("|")) for line in result.stdout.splitlines()], expected)

    def test_print_rows_reads_the_real_list(self):
        result = self.print_rows(GATE_LIST.read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([tuple(line.split("|")) for line in result.stdout.splitlines()],
                         gates_ran.parse_gate_list(GATE_LIST.read_text()))

    def test_malformed_rows_are_rejected(self):
        for row in ("photo-exportTests/A.swift|struct A",
                    "photo-exportTests/A.swift|gate|struct A|",
                    "photo-exportTests/A.swift|skip|struct A",
                    "photo-exportTests/A.swift|pin|func A.method",
                    "photo-exportTests/A.swift|gate|func method",
                    "photo-exportTests/A.swift|gate|struct  A",
                    "photo-exportTests/A.swift|gate|class A",
                    " |gate|struct A"):
            with self.subTest(row=row):
                text = "photo-exportTests/B.swift|gate|struct B\n" + row + "\n"
                with self.assertRaisesRegex(gates_ran.GateListError, ":2: "):
                    gates_ran.parse_gate_list(text)
                result = self.print_rows(text)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn("INVALID GATE LIST: ", result.stderr)
                self.assertIn(":2: ", result.stderr)

    def test_empty_list_is_rejected(self):
        with self.assertRaises(gates_ran.GateListError):
            gates_ran.parse_gate_list("# only comments\n\n")
        result = self.print_rows("# only comments\n\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("has no rows", result.stderr)


if __name__ == "__main__":
    unittest.main()
