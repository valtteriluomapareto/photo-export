"""Run the real persistence-doc guard against disposable source trees and documents."""

import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


CI_DIRECTORY = pathlib.Path(__file__).resolve().parents[1]
GUARD = CI_DIRECTORY / "check-persistence-doc.py"

SOURCES = {
    "Models/ExportPlacement.swift":
        "struct ExportPlacement: Codable {\n"
        "  enum Kind: String, Codable {\n"
        "    case timeline\n"
        "    case favorites\n"
        "    case album\n"
        "    case sharedAlbum\n"
        "  }\n"
        "  let kind: Kind\n"
        "}\n",
    "Models/ExportVariant.swift":
        "enum ExportVariant: String, Codable {\n"
        "  case original\n"
        "  case edited\n"
        "}\n",
    "Models/ExportRecord.swift":
        "enum ExportStatus: String, Codable {\n"
        "  case pending\n"
        "  case done\n"
        "}\n"
        "struct ExportRecordMutation: Codable {\n"
        "  enum Operation: String, Codable {\n"
        "    case upsert\n"
        "    case delete\n"
        "  }\n"
        "}\n",
    "Models/ExportVariantReason.swift":
        "struct ExportVariantReason: RawRepresentable, Codable {\n"
        "  let rawValue: String\n"
        "  static let interrupted = Self(rawValue: \"interrupted\")\n"
        "  static let pairedVideoUnavailable = Self(rawValue: \"pairedVideoUnavailable\")\n"
        "}\n",
    "Records/CollectionExportRecordStore.swift":
        "final class CollectionExportRecordStore {\n"
        "  enum LogOp: Codable {\n"
        "    case upsertRecord(placementId: String)\n"
        "    case deleteRecord(placementId: String)\n"
        "    private enum OpDiscriminator: String, Codable {\n"
        "      case upsertRecord, deleteRecord\n"
        "    }\n"
        "  }\n"
        "}\n",
}

ROWS = {
    "ExportPlacement.Kind": ["timeline", "favorites", "album", "sharedAlbum"],
    "ExportVariant": ["original", "edited"],
    "ExportStatus": ["pending", "done"],
    "ExportVariantReason": ["interrupted", "pairedVideoUnavailable"],
    "ExportRecordMutation.Operation": ["upsert", "delete"],
    "CollectionExportRecordStore.LogOp.OpDiscriminator": ["upsertRecord", "deleteRecord"],
}

HEADER = "| Value set | Persisted as | Values |\n| --- | --- | --- |\n"


def row(name, values):
    return f"| `{name}` | a field | {', '.join(f'`{value}`' for value in values)} |\n"


def table(rows=None):
    return HEADER + "".join(row(name, values) for name, values in (rows or ROWS).items())


class PersistenceDocGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        ci = self.root / "scripts/ci"
        ci.mkdir(parents=True)
        shutil.copy(GUARD, ci / GUARD.name)
        shutil.copy(CI_DIRECTORY / "swift_source.py", ci / "swift_source.py")
        for name, source in SOURCES.items():
            self.source(name, source)
        self.doc(table())

    def source(self, name, text):
        path = self.root / "photo-export" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def doc(self, text):
        path = self.root / "docs/reference/persistence-store.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# Export Record Persistence Store\n\n## Record-store value sets\n\n"
                        + text + "\nProse after the table.\n")

    def run_guard(self):
        return subprocess.run(
            [sys.executable, "-B", str(self.root / "scripts/ci" / GUARD.name), str(self.root)],
            capture_output=True, text=True)

    def assert_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("match the source", result.stdout)

    def assert_fails(self, *messages):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for message in messages:
            self.assertIn(message, result.stdout)
        return result

    def test_matching_table_passes(self):
        self.assert_passes()

    def test_case_missing_from_the_table_fails(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: String, Codable {\n"
                    "  case original\n  case edited\n  case originalPairedVideo\n}\n")
        self.assert_fails("`ExportVariant`", "source declares `originalPairedVideo`")

    def test_extra_documented_value_fails(self):
        self.doc(table(dict(ROWS, ExportStatus=["pending", "done", "skipped"])))
        self.assert_fails("`ExportStatus`", "table lists `skipped`")

    def test_switch_inside_a_computed_property_is_not_a_case(self):
        self.source("Models/ExportPlacement.swift",
                    "struct ExportPlacement {\n"
                    "  enum Kind: String {\n"
                    "    case timeline, favorites, album, sharedAlbum\n"
                    "    var policy: Int {\n"
                    "      switch self {\n"
                    "      case .sharedAlbum: return 1\n"
                    "      case .timeline, .favorites, .album: return 0\n"
                    "      }\n    }\n  }\n}\n")
        self.assert_passes()

    def test_nested_enum_cases_are_not_counted(self):
        self.source("Models/ExportRecord.swift",
                    "enum ExportStatus: String { case pending, done }\n"
                    "struct ExportRecordMutation {\n"
                    "  enum Operation: String, Codable {\n"
                    "    case upsert\n    case delete\n"
                    "    private enum CodingKeys: String, CodingKey {\n"
                    "      case op, id, record\n    }\n  }\n}\n")
        self.assert_passes()

    def test_same_named_enum_in_another_type_is_not_used(self):
        self.source("Models/ExportPlacement.swift",
                    "struct PhotoCollectionDescriptor {\n"
                    "  enum Kind: String { case album, smartAlbum }\n}\n"
                    + SOURCES["Models/ExportPlacement.swift"]
                    + "enum Kind: String { case other }\n")
        self.assert_passes()

    def test_ambiguous_or_missing_type_fails_loudly(self):
        self.source("Models/ExportPlacement.swift",
                    SOURCES["Models/ExportPlacement.swift"] * 2)
        self.source("Models/ExportVariant.swift", "enum ExportVariants: String { case original }\n")
        self.assert_fails(
            "photo-export/Models/ExportPlacement.swift: `ExportPlacement.Kind`: "
            "2 declarations of `ExportPlacement`",
            "photo-export/Models/ExportVariant.swift: `ExportVariant`: "
            "no declaration of `ExportVariant`")

    def test_case_list_spread_over_lines_and_attribute_lines(self):
        self.source("Records/CollectionExportRecordStore.swift",
                    "final class CollectionExportRecordStore {\n"
                    "  enum LogOp {\n"
                    "    private enum OpDiscriminator: String, Codable {\n"
                    "      @available(*, deprecated, message: \"use upsertRecord, x\")\n"
                    "      case legacyRecord\n"
                    "      case upsertRecord,  // the common write\n"
                    "        deleteRecord\n"
                    "    }\n  }\n}\n")
        self.doc(table(dict(ROWS, **{
            "CollectionExportRecordStore.LogOp.OpDiscriminator":
                ["legacyRecord", "upsertRecord", "deleteRecord"]})))
        self.assert_passes()

    def test_conditional_compilation_in_the_body_fails(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: String {\n"
                    "  case original\n  #if DEBUG\n  case edited\n  #endif\n}\n")
        self.assert_fails("`ExportVariant`: `#if` in the body")

    def test_associated_values_and_indirect_fail(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: String { case original(String), edited }\n")
        self.source("Models/ExportRecord.swift",
                    "indirect enum ExportStatus { case pending, done }\n"
                    + SOURCES["Models/ExportRecord.swift"].split("\n", 4)[4])
        self.assert_fails("`ExportVariant`: case `original` has associated values",
                          "`ExportStatus`: `indirect` enum")

    def test_static_let_values_are_read_from_the_literal(self):
        self.source("Models/ExportVariantReason.swift",
                    "struct ExportVariantReason: RawRepresentable {\n"
                    "  let rawValue: String\n"
                    "  static let interrupted = Self(rawValue: \"interrupted\")\n"
                    "  static let pairedVideoUnavailable = Self(rawValue: \"pairedVideoUnavailable\")\n"
                    "  static let destinationGone = ExportVariantReason(rawValue: \"destination-gone\")\n"
                    "  var label: String { switch self { case .interrupted: \"x\" default: \"y\" } }\n"
                    "}\n")
        self.assert_fails("`ExportVariantReason`", "source declares `destination-gone`")

    def test_static_let_without_a_literal_raw_value_fails(self):
        self.source("Models/ExportVariantReason.swift",
                    "struct ExportVariantReason: RawRepresentable {\n"
                    "  let rawValue: String\n"
                    "  static let interrupted = Self(rawValue: \"interrupted\")\n"
                    "  static let pairedVideoUnavailable = Self(rawValue: prefix + \"video\")\n"
                    "}\n")
        self.assert_fails("`ExportVariantReason`: `static let pairedVideoUnavailable` "
                          "is not a reason constant")

    def test_reason_code_added_in_an_extension_counts(self):
        self.source("Export/ReasonCodes.swift",
                    "extension ExportVariantReason {\n"
                    "  static let destinationGone = Self(rawValue: \"destinationGone\")\n"
                    "  var isGone: Bool { self == .destinationGone }\n}\n"
                    "extension ExportVariantReason.Nested { static let x = 1 }\n")
        self.assert_fails("`ExportVariantReason`", "source declares `destinationGone`")
        self.doc(table(dict(ROWS, ExportVariantReason=[
            "interrupted", "pairedVideoUnavailable", "destinationGone"])))
        self.assert_passes()

    def test_reason_static_var_fails(self):
        self.source("Export/ReasonCodes.swift",
                    "extension ExportVariantReason: CustomStringConvertible {\n"
                    "  static var destinationGone: Self { Self(rawValue: \"destinationGone\") }\n}\n")
        self.assert_fails("photo-export/Export/ReasonCodes.swift: "
                          "`static var destinationGone`; declare reason constants with "
                          "`static let`")

    def test_unrelated_reason_static_let_fails(self):
        self.source("Models/ExportVariantReason.swift",
                    "struct ExportVariantReason: RawRepresentable {\n"
                    "  let rawValue: String\n"
                    "  init(rawValue: String) { self.rawValue = rawValue }\n"
                    "  static let interrupted = Self(rawValue: \"interrupted\")\n"
                    "  static let pairedVideoUnavailable = Self(rawValue: \"pairedVideoUnavailable\")\n"
                    "  static let all: [Self] = [interrupted, pairedVideoUnavailable]\n"
                    "}\n")
        self.assert_fails("`static let all` is not a reason constant "
                          "(`Self(rawValue: \"...\")`); teach the guard about it")

    def test_raw_value_literal_outside_a_reason_constant_fails(self):
        self.source("Export/ReasonCodes.swift",
                    "extension ExportVariantReason {\n"
                    "  static func gone() -> Self { Self(rawValue: \"destinationGone\") }\n}\n")
        self.assert_fails("photo-export/Export/ReasonCodes.swift: line 2: "
                          "`rawValue:` literal outside a reason constant")

    def test_non_string_raw_type_fails(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: Int, Codable { case original, edited }\n")
        self.source("Models/ExportRecord.swift",
                    "enum ExportStatus { case pending, done }\n"
                    "struct ExportRecordMutation { enum Operation: String { case upsert, delete } }\n")
        self.assert_fails("`ExportVariant`: raw type must be `String`, found `Int`",
                          "`ExportStatus`: raw type must be `String`, found none")

    def test_case_list_line_beginning_with_a_comma_fails(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: String {\n  case original\n    , edited\n}\n")
        self.assert_fails("`ExportVariant`: a case-list line begins with `,`")

    def test_explicit_raw_value_is_honored(self):
        self.source("Models/ExportRecord.swift",
                    "enum ExportStatus: String {\n"
                    "  case pending = \"waiting\"  // \"pending\" in older builds\n"
                    "  case done\n}\n"
                    "struct ExportRecordMutation { enum Operation: String { case upsert, delete } }\n")
        self.assert_fails("source declares `waiting`", "table lists `pending`")
        self.doc(table(dict(ROWS, ExportStatus=["waiting", "done"])))
        self.assert_passes()

    def test_computed_raw_value_fails(self):
        self.source("Models/ExportVariant.swift",
                    "enum ExportVariant: String { case original = prefix, edited }\n")
        self.assert_fails("`ExportVariant`: case `original` raw value is not a string literal")

    def test_table_format_errors(self):
        name = "CollectionExportRecordStore.LogOp.OpDiscriminator"
        cases = {
            "missing header": (
                table().replace("| Persisted as |", "| Field |"),
                "no `| Value set | Persisted as | Values |` table"),
            "missing row": (
                table({key: value for key, value in ROWS.items() if key != "ExportStatus"}),
                "no row for `ExportStatus`"),
            "unknown row": (
                table() + row("AutoSyncFailureCategory", ["unknown"]),
                ":13: unknown value set `AutoSyncFailureCategory`"),
            "duplicate row": (
                table() + row("ExportVariant", ["original", "edited"]),
                ":13: duplicate row for `ExportVariant`"),
            "value not in backticks": (
                table().replace("`upsertRecord`, `deleteRecord`", "`upsertRecord`, deleteRecord"),
                f":12: `{name}` value \"deleteRecord\" is not a single backticked name"),
            "duplicate value": (
                table(dict(ROWS, ExportVariant=["original", "edited", "original"])),
                ":8: `ExportVariant` lists `original` twice"),
            "wrong cell count": (
                table().replace("| a field | `upsert`", "`upsert`"),
                ":11: expected 3 cells"),
        }
        for label, (text, message) in cases.items():
            with self.subTest(label):
                self.doc(text)
                self.assert_fails(message)

    def test_missing_document_is_a_problem(self):
        (self.root / "docs/reference/persistence-store.md").unlink()
        result = self.assert_fails("docs/reference/persistence-store.md: cannot read the document")
        self.assertNotIn("Traceback", result.stderr)

    def test_prose_only_document_fails(self):
        self.doc("- `kind` (String) - `timeline` | `favorites` | `album`.\n"
                 "- `variants` (Object) - keyed by variant name (`original`, `edited`).\n")
        self.assert_fails("no `| Value set | Persisted as | Values |` table")


if __name__ == "__main__":
    unittest.main()
