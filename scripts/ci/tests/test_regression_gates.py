"""Run the real regression-symbol scanner in disposable repository skeletons."""

import pathlib
import shutil
import subprocess
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
REPOSITORY = CI_DIRECTORY.parents[1]
GUARD = CI_DIRECTORY / "check-regression-gates.sh"
GATE_LIST = CI_DIRECTORY / "regression-gates.txt"
GATE_PARSER = CI_DIRECTORY / "check-regression-gates-ran.py"
DOCS = ("docs/reference/architecture-conventions.md", "AGENTS.md", "CONTRIBUTING.md")


def gate_rows():
    """Read the real gate list as (file, declaration) pairs."""
    rows = []
    for line in GATE_LIST.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            file, _, declaration = (field.strip() for field in line.split("|"))
            rows.append((file, declaration))
    return rows


def sources():
    """Build one minimal Swift file per listed test file, declaring its gates."""
    suites = {}
    for file, declaration in gate_rows():
        keyword, symbol = declaration.split(" ", 1)
        suite, _, method = symbol.partition(".")
        methods = suites.setdefault(file, {}).setdefault(suite, [])
        if keyword == "func":
            methods.append(method)
    return {
        file: "".join(
            f"struct {suite} {{\n" + "".join(f"  func {method}() {{}}\n" for method in methods) + "}\n"
            for suite, methods in declared.items())
        for file, declared in suites.items()
    }


class RegressionGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        ci = self.root / "scripts/ci"
        ci.mkdir(parents=True)
        shutil.copy(GUARD, ci / GUARD.name)
        shutil.copy(GATE_LIST, ci / GATE_LIST.name)
        shutil.copy(GATE_PARSER, ci / GATE_PARSER.name)
        shutil.copy(CI_DIRECTORY / "swift_source.py", ci / "swift_source.py")
        for doc in DOCS:
            (self.root / doc).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPOSITORY / doc, self.root / doc)
        for name, source in sources().items():
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text(source)
        self.tests = self.root / "photo-exportTests"
        self.gate_list = ci / GATE_LIST.name
        self.guard = ci / GUARD.name

    def run_guard(self):
        return subprocess.run(["bash", str(self.guard)], capture_output=True, text=True)

    def assert_violation(self, diagnostic):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(diagnostic, result.stdout + result.stderr)
        return result

    def edit(self, relative, old, new):
        path = self.root / relative
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def test_sources_cover_every_listed_test_file(self):
        self.assertTrue(gate_rows())
        self.assertTrue((self.tests / "ImportIdempotencyTests.swift").is_file())
        self.assertTrue((self.tests / "ExportManagerRunExportTests.swift").is_file())

    def test_clean_tree_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All regression-gate symbols present", result.stdout)
        self.assertIn("All documented regression-gate lists name every gate", result.stdout)
        for file, declaration in gate_rows():
            self.assertIn(f"{declaration} in {file}", result.stdout)

    def test_missing_file_fails(self):
        (self.tests / "ImportIdempotencyTests.swift").unlink()
        self.assert_violation("MISSING FILE: photo-exportTests/ImportIdempotencyTests.swift")

    def test_renamed_suite_does_not_match_required_prefix(self):
        path = self.tests / "ImportIdempotencyTests.swift"
        path.write_text("struct ImportIdempotencyTestsExtra {}\n")
        self.assert_violation("MISSING SYMBOL: 'struct ImportIdempotencyTests'")

    def test_renamed_method_does_not_match_required_prefix(self):
        path = self.tests / "ExportManagerRunExportTests.swift"
        path.write_text(path.read_text().replace("BeforeRetryCheck()", "BeforeRetryCheckExtra()"))
        self.assert_violation("MISSING SYMBOL: 'func autoSyncRunFilterAlreadyExportedBeforeRetryCheck'")

    def test_commented_and_quoted_declarations_do_not_count(self):
        path = self.tests / "ImportIdempotencyTests.swift"
        for source in (
            "// struct ImportIdempotencyTests {}\n",
            "/*\nstruct ImportIdempotencyTests {}\n*/\n",
            'let documentation = "struct ImportIdempotencyTests {}"\n',
        ):
            with self.subTest(source=source):
                path.write_text(source)
                self.assert_violation("MISSING SYMBOL: 'struct ImportIdempotencyTests'")

    def test_missing_method_fails_even_when_suite_remains(self):
        path = self.tests / "ExportManagerRunExportTests.swift"
        path.write_text("struct ExportManagerRunExportTests {}\n")
        self.assert_violation("MISSING SYMBOL: 'func autoSyncRunFilterAlreadyExportedBeforeRetryCheck'")

    def test_method_gate_requires_its_qualifying_suite(self):
        path = self.tests / "AutoSyncSeamCharacterizationTests.swift"
        path.write_text(path.read_text().replace(
            "struct AutoSyncSeamCharacterizationTests {", "struct RenamedSeamTests {"))
        self.assert_violation(
            "MISSING SYMBOL: 'struct AutoSyncSeamCharacterizationTests' (suite of "
            "'func AutoSyncSeamCharacterizationTests.autoSyncRunYieldsCanonicalSequence')")

    def test_rows_come_from_the_gate_list(self):
        with self.gate_list.open("a") as gate_list:
            gate_list.write("photo-exportTests/NewGateTests.swift|gate|struct NewGateTests\n")
        self.assert_violation("MISSING FILE: photo-exportTests/NewGateTests.swift (looking for: struct NewGateTests)")

    def test_malformed_gate_list_rows_fail(self):
        for row in ("photo-exportTests/A.swift|struct A",
                    "photo-exportTests/A.swift|gate|struct A|extra",
                    "photo-exportTests/A.swift|skip|struct A",
                    "photo-exportTests/A.swift|pin|func A.method",
                    "photo-exportTests/A.swift|gate|func method",
                    "|gate|struct A"):
            with self.subTest(row=row):
                self.gate_list.write_text(GATE_LIST.read_text() + row + "\n")
                self.assert_violation("INVALID GATE LIST: scripts/ci/regression-gates.txt:")

    def test_empty_gate_list_fails(self):
        self.gate_list.write_text("# nothing listed\n\n")
        self.assert_violation("INVALID GATE LIST: scripts/ci/regression-gates.txt has no rows")

    def test_doc_missing_a_gate_fails(self):
        self.edit("AGENTS.md", "- `ImportIdempotencyTests`\n", "")
        self.assert_violation("DOC DRIFT: AGENTS.md does not list gate 'ImportIdempotencyTests'")

    def test_other_names_in_a_gate_section_do_not_fail(self):
        self.edit("AGENTS.md", "- `ImportIdempotencyTests`\n",
                  "- `ImportIdempotencyTests`\n- `RetiredGateTests`\n- `scripts/ci/test-guards.sh` runs the guards.\n")
        self.edit("CONTRIBUTING.md", "   - `ImportIdempotencyTests`",
                  "   - `ExportManagerRunExportTests` — a pin.\n   - `ImportIdempotencyTests`")
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_gate_name_must_be_complete_in_the_doc(self):
        self.edit("AGENTS.md", "- `ImportIdempotencyTests`\n", "- `ImportIdempotencyTestsExtra`\n")
        self.assert_violation("DOC DRIFT: AGENTS.md does not list gate 'ImportIdempotencyTests'")

    def test_doc_table_missing_a_method_gate_and_its_pin_fails(self):
        doc = "docs/reference/architecture-conventions.md"
        path = self.root / doc
        lines = path.read_text().splitlines(keepends=True)
        path.write_text("".join(line for line in lines
                                if not line.startswith("| `ExportManagerRunExportTests.")))
        result = self.assert_violation(
            f"DOC DRIFT: {doc} does not list gate "
            "'ExportManagerRunExportTests.autoSyncRunFilterAlreadyExportedBeforeRetryCheck'")
        self.assertIn(f"DOC DRIFT: {doc} does not mention pinned suite 'ExportManagerRunExportTests'",
                      result.stdout)

    def test_doc_without_its_gate_section_fails(self):
        self.edit("CONTRIBUTING.md", "## Developing new features\n", "## Renamed section\n")
        self.assert_violation("DOC DRIFT: CONTRIBUTING.md has no '## Developing new features' section")

    def test_gate_mentions_outside_the_gate_section_do_not_count(self):
        self.edit("AGENTS.md", "- `ImportIdempotencyTests`\n", "")
        with (self.root / "AGENTS.md").open("a") as agents:
            agents.write("\n## Elsewhere\n\n- `ImportIdempotencyTests`\n")
        self.assert_violation("DOC DRIFT: AGENTS.md does not list gate 'ImportIdempotencyTests'")


if __name__ == "__main__":
    unittest.main()
