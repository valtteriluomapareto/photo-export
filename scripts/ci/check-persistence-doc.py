#!/usr/bin/env python3
"""Keep the persistence doc's value-set table in step with the Swift source.

docs/reference/persistence-store.md lists, in its "Record-store value sets" table, every
string the record stores write for an enum-like field. This guard reads each listed
type from the app source and fails when the table and the source disagree.

Each table row names a qualified type path, looked up by nesting (zero or several
declarations fail). For an enum, which must have a `String` raw type, the values are its
`case` declarations at the top level of its body, using an explicit string raw value
when there is one; `switch` cases and nested types are skipped. For a
`RawRepresentable` struct, the values are its `static let x = Self(rawValue: "...")`
literals, in the struct and in every `extension` of it under photo-export/. Shapes the
guard cannot read fail loudly rather than being skipped: `#if` in the body, `indirect`,
associated values, non-literal raw values, a case-list line that begins with `,`, and,
on the struct, a `static var`, any other `static let`, or a `rawValue:` literal outside
a reason constant.

Structure comes from comment- and string-masked source; literals are read from the
original text at the same offsets. The table format is strict: the exact header, one
row per configured type, and backticked, comma-separated values.
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402

DOC = pathlib.Path("docs/reference/persistence-store.md")
APP = pathlib.Path("photo-export")
HEADER = "| Value set | Persisted as | Values |"
DIVIDER = "| --- | --- | --- |"
VALUE_SETS = {
    "ExportPlacement.Kind": "Models/ExportPlacement.swift",
    "ExportVariant": "Models/ExportVariant.swift",
    "ExportStatus": "Models/ExportRecord.swift",
    "ExportVariantReason": "Models/ExportVariantReason.swift",
    "ExportRecordMutation.Operation": "Models/ExportRecord.swift",
    "CollectionExportRecordStore.LogOp.OpDiscriminator":
        "Records/CollectionExportRecordStore.swift",
}
DECLARATION = re.compile(r"\b(enum|struct|class|actor)\s+(\w+)")
CASE = re.compile(r"\bcase\b")
CASE_ITEM = re.compile(r"\s*(\w+)\s*(=)?")
STATIC_LET = re.compile(r"\bstatic\s+let\s+(\w+)")
STATIC_VAR = re.compile(r"\bstatic\s+var\s+(\w+)")
RAW_VALUE = re.compile(r"\brawValue\s*:")
LEADING_COMMA = re.compile(r"(?m)^[ \t]*,")
LITERAL = re.compile(r'\s*"([^"\\\n]*)"')


class SourceError(Exception):
    pass


def depths(code):
    """Brace depth at each offset; a brace counts from the character after it."""
    result, depth = [], 0
    for char in code:
        if char == "}":
            depth -= 1
        result.append(depth)
        if char == "{":
            depth += 1
    return result


def find_type(code, depth, path):
    """Body span, depth, keyword and inheritance clause of the type at a dotted path."""
    start, end, level, keyword, clause = 0, len(code), 0, None, ""
    for name in path.split("."):
        found = [match for match in DECLARATION.finditer(code, start, end)
                 if match.group(2) == name and depth[match.start()] == level]
        if len(found) != 1:
            raise SourceError(f"{len(found) or 'no'} declaration{'s' * (len(found) > 1)} "
                              f"of `{name}`")
        if re.search(r"\bindirect\s+$", code[:found[0].start()]):
            raise SourceError("`indirect` enum")
        keyword = found[0].group(1)
        start = code.index("{", found[0].end()) + 1
        clause = code[found[0].end():start - 1]
        end = body_end(code, depth, start, level)
        level += 1
    return start, end, level, keyword, clause


def body_end(code, depth, start, level):
    end = next((index for index in range(start, len(code))
                if code[index] == "}" and depth[index] == level), None)
    if end is None:
        raise SourceError("unbalanced braces")
    return end


def at_level(pattern, code, depth, start, end, level):
    return [match for match in pattern.finditer(code, start, end) if depth[match.start()] == level]


def literal_at(source, code, index, end):
    """A string literal starting at index, with only masked text after it up to end."""
    literal = LITERAL.match(source, index)
    if literal is None or code[literal.end():end].strip():
        return None
    return literal.group(1)


def case_values(source, code, depth, start, end, level):
    if at_level(LEADING_COMMA, code, depth, start, end, level):
        raise SourceError("a case-list line begins with `,`; end the previous line with it")
    values = []
    for case in at_level(CASE, code, depth, start, end, level):
        stop = case.end()
        while True:  # A trailing comma continues the case list on the next line.
            line_end = code.find("\n", stop)
            line_end = end if line_end == -1 or line_end > end else line_end
            stop = line_end + 1
            if not code[case.end():line_end].rstrip().endswith(",") or stop >= end:
                break
        item_start = case.end()
        for item in code[case.end():line_end].split(","):
            item_end = item_start + len(item)
            match = CASE_ITEM.match(item)
            if match is None:
                raise SourceError(f"unreadable case `{item.strip()}`")
            name = match.group(1)
            rest = item[match.end():]
            if match.group(2):
                value = literal_at(source, code, item_start + match.end(), item_end)
                if value is None:
                    raise SourceError(f"case `{name}` raw value is not a string literal")
                values.append(value)
            elif rest.lstrip().startswith("("):
                raise SourceError(f"case `{name}` has associated values")
            elif rest.strip():
                raise SourceError(f"unreadable case `{item.strip()}`")
            else:
                values.append(name)
            item_start = item_end + 1
    return values


def static_values(source, code, depth, start, end, level, type_name):
    """Reason constants in one struct or extension body."""
    values, consumed = [], set()
    shape = re.compile(rf"\s*=\s*(?:Self|{type_name})\s*\(\s*rawValue\s*:")
    for match in at_level(STATIC_VAR, code, depth, start, end, level):
        raise SourceError(f"`static var {match.group(1)}`; declare reason constants with "
                          "`static let`")
    for match in at_level(STATIC_LET, code, depth, start, end, level):
        call = shape.match(code, match.end())
        close = code.find(")", call.end()) if call else -1
        value = literal_at(source, code, call.end(), close) if call else None
        if value is None:
            raise SourceError(f"`static let {match.group(1)}` is not a reason constant "
                              "(`Self(rawValue: \"...\")`); teach the guard about it")
        values.append(value)
        consumed.add(call.end())
    for match in RAW_VALUE.finditer(code, start, end):
        if match.end() not in consumed and LITERAL.match(source, match.end()):
            line = code.count("\n", 0, match.start()) + 1
            raise SourceError(f"line {line}: `rawValue:` literal outside a reason constant")
    return values


def type_values(source, path):
    """Values declared in the type's own body, and its keyword."""
    code = code_only(source)
    depth = depths(code)
    start, end, level, keyword, clause = find_type(code, depth, path)
    if at_level(re.compile(r"#if\b"), code, depth, start, end, level):
        raise SourceError("`#if` in the body")
    if keyword == "enum":
        raw_type = re.match(r"\s*:\s*([\w.]+)", clause)
        if raw_type is None or raw_type.group(1) != "String":
            found = f"`{raw_type.group(1)}`" if raw_type else "none"
            raise SourceError(f"raw type must be `String`, found {found}")
        return keyword, case_values(source, code, depth, start, end, level)
    return keyword, static_values(source, code, depth, start, end, level, path.split(".")[-1])


def extension_values(source, path):
    """Reason constants declared in top-level extensions of the type."""
    code = code_only(source)
    depth = depths(code)
    values = []
    extension = re.compile(rf"\bextension\s+{re.escape(path)}\b(?!\s*\.)")
    for match in extension.finditer(code):
        if depth[match.start()] != 0:
            continue
        start = code.index("{", match.end()) + 1
        end = body_end(code, depth, start, 0)
        if at_level(re.compile(r"#if\b"), code, depth, start, end, 1):
            raise SourceError("`#if` in an extension body")
        values += static_values(source, code, depth, start, end, 1, path.split(".")[-1])
    return values


def source_values(root, file, path):
    keyword, values = type_values((root / APP / file).read_text(), path)
    if keyword != "enum":
        for other in sorted((root / APP).rglob("*.swift")):
            try:
                values += extension_values(other.read_text(), path)
            except SourceError as error:
                raise SourceError(f"{other.relative_to(root)}: {error}") from None
    if not values:
        raise SourceError("no values found")
    return values


def table_rows(doc):
    """The table's rows by type path, and the problems in its format."""
    lines = doc.split("\n") + [""]
    if lines.count(HEADER) != 1 or lines[lines.index(HEADER) + 1] != DIVIDER:
        return {}, [f"{DOC}: no `{HEADER}` table (followed by `{DIVIDER}`)"]
    rows, problems = {}, []
    number = lines.index(HEADER) + 2
    while number < len(lines) and lines[number].startswith("|"):
        where = f"{DOC}:{number + 1}"
        cells = [cell.strip() for cell in lines[number].strip().strip("|").split("|")]
        number += 1
        if len(cells) != 3:
            problems.append(f"{where}: expected 3 cells, found {len(cells)}")
            continue
        name = cells[0].strip("`")
        if cells[0] != f"`{name}`" or name not in VALUE_SETS:
            problems.append(f"{where}: unknown value set {cells[0]}")
        elif name in rows:
            problems.append(f"{where}: duplicate row for `{name}`")
        else:
            values = [value.strip() for value in cells[2].split(",")]
            for value in values:
                if not re.fullmatch(r"`[^`\s]+`", value):
                    problems.append(f"{where}: `{name}` value \"{value}\" is not a single "
                                    "backticked name")
            values = [value.strip("`") for value in values]
            for value in sorted({value for value in values if values.count(value) > 1}):
                problems.append(f"{where}: `{name}` lists `{value}` twice")
            rows[name] = values
    problems += [f"{DOC}: no row for `{name}`" for name in VALUE_SETS if name not in rows]
    return rows, problems


def problems(root):
    try:
        rows, found = table_rows((root / DOC).read_text())
    except (OSError, UnicodeError) as error:
        rows, found = {}, [f"{DOC}: cannot read the document: {error}"]
    for name, file in VALUE_SETS.items():
        location = APP / file
        try:
            values = source_values(root, file, name)
        except (OSError, UnicodeError, ValueError, SourceError) as error:
            found.append(f"{location}: `{name}`: {error}")
            continue
        if name not in rows:
            continue
        found += [f"`{name}` ({location}): source declares `{value}`, missing from the table"
                  for value in values if value not in rows[name]]
        found += [f"`{name}` ({location}): table lists `{value}`, not declared in the source"
                  for value in dict.fromkeys(rows[name]) if value not in values]
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    print(f"Checking the value-set table in {root / DOC} against {root / APP} ...")
    found = problems(root)
    for problem in found:
        print(f"  {problem}")
    if found:
        print(f"{len(found)} persistence-doc problem(s) found. Update the "
              "\"Record-store value sets\" table to match the source.")
        return 1
    print(f"All {len(VALUE_SETS)} record-store value sets in {DOC} match the source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
