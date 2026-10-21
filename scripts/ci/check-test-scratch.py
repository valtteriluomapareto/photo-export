#!/usr/bin/env python3
"""Keep test preferences and scratch files inside TestScratch's per-run root.

The hosted test process shares the app's identity, so a named preferences suite, the
standard defaults or a system folder written from a test leaves state behind on every
run: in the user's Library and temporary folder when unsigned, or in the app's sandbox
container (next to the shipping app's real data) when signed. `TestScratch`
(photo-exportTests/TestHelpers/TestScratch.swift) puts preferences and folders under
one root that the test process removes when it exits.

This is a lexical guard over comment- and string-masked source, matched across line
breaks. Outside TestScratch.swift it flags:
- `UserDefaults(suiteName:` and `UserDefaults.init(suiteName:`; use
  `TestScratch.defaults(_:)`, or `TestScratch.suiteName(_:)` with
  `TestScratch.defaults(suiteName:)` to share one suite;
- `UserDefaults.standard` and `UserDefaults()`, the app's own domain;
- `.temporaryDirectory`, `NSTemporaryDirectory(`, `.itemReplacementDirectory`,
  `.applicationSupportDirectory` and `.cachesDirectory`; use `TestScratch.directory(_:)`;
- the no-argument `ExportRecordStore()` and `CollectionExportRecordStore()`, which
  open the real Application Support records;
- the shipping compositions, `AppComposition.production`, `.screenshot` and `.forLaunch`,
  qualified or called through a leading dot (`.production(`, `.forLaunch(`,
  `.screenshot(windowSize:`) anywhere: they hold the app's own preferences, Application
  Support folder and PhotoKit. Build a core from a composition with TestScratch roots and
  fakes instead;
- `PhotoExportApp(`, `PhotoExportApp.init(`, `PhotoExportApp.main` and a typed
  `: PhotoExportApp = .init`, which compose the real app.

A use that deliberately exercises real-path behavior is allowed when the line where it
starts, or the line above, carries a `// test-scratch: allow` comment followed by a
reason. The marker counts only in comment text, not inside a string literal.
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from swift_source import STRING_START, code_only, comment_end, string_end  # noqa: E402

TESTS = pathlib.Path("photo-exportTests")
EXEMPT = {TESTS / "TestHelpers" / "TestScratch.swift"}
SUITE = "named preferences suite; use TestScratch.defaults or TestScratch.suiteName"
STANDARD = "the app's own preferences domain; use TestScratch.defaults"
FOLDER = "real system folder; use TestScratch.directory"
APP = "composes the real app (its preferences, Application Support and Photos)"
COMPOSITION = ("shipping composition (real preferences, Application Support and Photos); "
               "build AppCore from a TestScratch composition")
BANNED = [
    (re.compile(r"\bUserDefaults\s*(?:\.\s*init\s*)?\(\s*suiteName\s*:"), SUITE),
    (re.compile(r"\bUserDefaults\s*\.\s*standard\b"), STANDARD),
    (re.compile(r"\bUserDefaults\s*(?:\.\s*init\s*)?\(\s*\)"), STANDARD),
    # A leading `\s*` reports a wrapped `.member` on the line of the expression it continues.
    (re.compile(r"\s*\.\s*temporaryDirectory\b"), FOLDER),
    (re.compile(r"\bNSTemporaryDirectory\s*\("), FOLDER),
    (re.compile(
        r"\s*\.\s*(?:itemReplacementDirectory|applicationSupportDirectory|cachesDirectory)\b"),
     FOLDER),
    (re.compile(r"(?<![\w.])(?:Collection)?ExportRecordStore\s*\(\s*\)"),
     "record store on the real Application Support path; pass a TestScratch directory"),
    # Qualified, including an unapplied reference such as `AppComposition.production`.
    (re.compile(r"\bAppComposition\s*\.\s*(?:production|screenshot|forLaunch)\b"), COMPOSITION),
    # Called through a leading dot in any position: an argument, a return, a ternary arm, a
    # reassignment or a collection element.
    (re.compile(r"\s*\.\s*(?:production|forLaunch)\s*\("), COMPOSITION),
    (re.compile(r"\s*\.\s*screenshot\s*\(\s*windowSize\s*:"), COMPOSITION),
    (re.compile(r"\bPhotoExportApp\s*(?:\.\s*init\s*)?\("), APP),
    (re.compile(r"\bPhotoExportApp\s*\.\s*main\b"), APP),
    (re.compile(r":\s*PhotoExportApp\s*=\s*\.\s*init\b"), APP),
]
# The reason must follow the marker, so a bare marker does not silence the guard.
ALLOW = re.compile(r"\btest-scratch:\s*allow\b\W*\w")


def comment_lines(source, code):
    """Comment text per line: the characters the masker blanked, minus string literals."""
    strings = strings_only(source)
    return [
        "".join(
            char if kept == " " and quoted == " " else " "
            for char, kept, quoted in zip(raw, masked, literal))
        for raw, masked, literal in zip(
            source.split("\n"), code.split("\n"), strings.split("\n"))
    ]


def strings_only(source):
    """The source with everything except string literals blanked."""
    output = [" " if char != "\n" else "\n" for char in source]
    index = 0
    while index < len(source):
        if source.startswith(("//", "/*"), index):
            index = comment_end(source, index)
            continue
        literal = STRING_START.match(source, index)
        if literal is None:
            index += 1
            continue
        end = string_end(source, literal)
        output[index:end] = source[index:end]
        index = end
    return "".join(output)


def allowed(comments, index):
    return any(ALLOW.search(comments[line]) for line in (index, index - 1) if line >= 0)


def problems(root):
    found = []
    for path in sorted((root / TESTS).rglob("*.swift")):
        relative = path.relative_to(root)
        if relative in EXEMPT:
            continue
        source = path.read_text()
        code = code_only(source)
        comments = comment_lines(source, code)
        hits = set()
        for pattern, message in BANNED:
            for match in pattern.finditer(code):
                index = code.count("\n", 0, match.start())
                if not allowed(comments, index):
                    hits.add((index + 1, message))
        found += [f"{relative}:{line}: {message}" for line, message in sorted(hits)]
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    print(f"Checking test scratch state under {root / TESTS} ...")
    found = problems(root)
    for problem in found:
        print(f"  {problem}")
    if found:
        print(f"{len(found)} test-scratch problem(s) found. Mark a deliberate use with "
              "`// test-scratch: allow <reason>` on the line or the line above.")
        return 1
    print("Test preferences and scratch files stay under TestScratch.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
