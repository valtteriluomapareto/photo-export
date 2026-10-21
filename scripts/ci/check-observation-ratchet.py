#!/usr/bin/env python3
"""Ratchet the app's remaining Combine-observation patterns down, never up.

The app is moving from `ObservableObject` to `@Observable` one type at a time
(docs/reference/observation-migration-recipe.md). While that happens, new code
(including code arriving from main) must not add old-pattern uses. This guard
counts under photo-export/:

Per file, against `type` and `external-publisher` rows:
- `ObservableObject` conformances, by type name (class, struct, actor, protocol or
  extension declarations whose inheritance clause names it, across line breaks);
- external `$publisher` uses: a `$property` projection reached through another
  object (`manager.$identity`, also wrapped onto the next line). The owner's own
  `$property`, `self.$property` and `self?.$property` are internal and not
  counted; neither are binding projections such as `$model.flag`.

As repository totals, against `total` rows (so moving a use between files passes):
- `@Published` declarations;
- `environmentObject(` calls, with or without a leading dot;
- `@EnvironmentObject`, `@StateObject` and `@ObservedObject` properties;
- external `objectWillChange` uses (through another object; `objectWillChange`,
  `self.objectWillChange` and `self?.objectWillChange` are internal).

It compares them with scripts/ci/observation-ratchet.txt and fails when a count
rises or an unlisted type or file appears, and also when a count falls or a type
stops conforming, so the ceiling is lowered in the same change and cannot creep
back up later.

This is a lexical guard over comment- and string-masked source, like the other
structural guards. Wrapper names may be qualified; imports and name resolution
are not checked.
"""

import collections
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from swift_source import code_only  # noqa: E402

APP = pathlib.Path("photo-export")
CEILING = pathlib.Path("scripts/ci/observation-ratchet.txt")

TYPE_DECLARATION = re.compile(
    r"\b(?:class|struct|actor|protocol|extension)\s+([A-Za-z_][\w.]*)"
    r"(?:\s*<[^{>]*>)?\s*:([^{]*)\{")
OBSERVABLE_OBJECT = re.compile(r"\bObservableObject\b")
EXTERNAL_PUBLISHER = re.compile(r"\.\s*\$[A-Za-z_]\w*")
OBJECT_WILL_CHANGE = re.compile(r"\.\s*objectWillChange\b")
# The receiver before the dot is `self`, `self?` or `self!`.
SELF_RECEIVER = re.compile(r"(?<![\w.])self\s*[?!]?\s*$")
# Match an attribute name after optional module/type qualifiers.
ATTRIBUTE_PREFIX = r"@\s*(?:[A-Za-z_]\w*\s*\.\s*)*"

TOTALS = collections.OrderedDict([
    ("published", ("@Published declarations", re.compile(ATTRIBUTE_PREFIX + r"Published\b(?!\s*\.)"))),
    ("environment-object",
     ("environmentObject( calls", re.compile(r"(?<![\w$@])environmentObject\s*\("))),
    ("environment-object-property",
     ("@EnvironmentObject properties", re.compile(ATTRIBUTE_PREFIX + r"EnvironmentObject\b(?!\s*\.)"))),
    ("state-object", ("@StateObject properties", re.compile(ATTRIBUTE_PREFIX + r"StateObject\b(?!\s*\.)"))),
    ("observed-object", ("@ObservedObject properties", re.compile(ATTRIBUTE_PREFIX + r"ObservedObject\b(?!\s*\.)"))),
    ("object-will-change", ("external objectWillChange uses", None)),
])
EXTERNAL_LABEL = "external $publisher uses"
KINDS = {"type", "external-publisher", "total"}


def external(pattern, code):
    return sum(
        1 for match in pattern.finditer(code)
        if not SELF_RECEIVER.search(code[max(0, match.start() - 64):match.start()]))


def scan(root):
    """Return ({path: types}, {path: external publisher count}, {total kind: count})."""
    types, publishers = {}, {}
    totals = {kind: 0 for kind in TOTALS}
    for path in sorted((root / APP).rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        code = code_only(path.read_text())
        names = {
            match.group(1) for match in TYPE_DECLARATION.finditer(code)
            if OBSERVABLE_OBJECT.search(match.group(2))
        }
        if names:
            types[relative] = names
        count = external(EXTERNAL_PUBLISHER, code)
        if count:
            publishers[relative] = count
        for kind, (_, pattern) in TOTALS.items():
            totals[kind] += (
                external(OBJECT_WILL_CHANGE, code) if pattern is None
                else len(pattern.findall(code)))
    return types, publishers, totals


def read_ceiling(root):
    types = collections.defaultdict(set)
    publishers, totals = {}, {}
    for number, raw in enumerate((root / CEILING).read_text().splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split("|")]
        if len(fields) != 3 or not all(fields):
            raise ValueError(f"{CEILING}:{number}: expected kind|key|value, got {raw!r}")
        kind, key, value = fields
        if kind not in KINDS:
            raise ValueError(f"{CEILING}:{number}: unknown kind {kind!r}")
        if kind == "type":
            types[key].add(value)
            continue
        if not value.isdigit():
            raise ValueError(f"{CEILING}:{number}: {kind} ceiling must be a count, got {value!r}")
        table = publishers if kind == "external-publisher" else totals
        if kind == "total" and key not in TOTALS:
            raise ValueError(f"{CEILING}:{number}: unknown total {key!r}")
        if key in table:
            raise ValueError(f"{CEILING}:{number}: duplicate {kind} row for {key}")
        table[key] = int(value)
    for kind in TOTALS:
        if kind not in totals:
            raise ValueError(f"{CEILING}: missing total row for {kind}")
    return types, publishers, totals


def compare(label, now, limit, prefix, lower_hint):
    if now > limit:
        return [f"{prefix}{label} rose from {limit} to {now}; use the Observation pattern "
                "instead (see docs/reference/observation-migration-recipe.md)"]
    if now < limit:
        return [f"{prefix}{label} fell from {limit} to {now}; {lower_hint}"]
    return []


def problems(found, allowed):
    found_types, found_publishers, found_totals = found
    allowed_types, allowed_publishers, allowed_totals = allowed
    result = []
    for file in sorted(set(found_types) | set(allowed_types)):
        for name in sorted(found_types.get(file, set()) - allowed_types.get(file, set())):
            result.append(
                f"{file}: new ObservableObject type {name}; make it @Observable "
                "(see docs/reference/observation-migration-recipe.md)")
        for name in sorted(allowed_types.get(file, set()) - found_types.get(file, set())):
            result.append(
                f"{file}: {name} no longer conforms to ObservableObject; "
                f"remove its row from {CEILING}")
    for file in sorted(set(found_publishers) | set(allowed_publishers)):
        result += compare(
            EXTERNAL_LABEL, found_publishers.get(file, 0), allowed_publishers.get(file, 0),
            f"{file}: ", f"lower its row in {CEILING} to the new count (or remove it at zero)")
    for kind, (label, _) in TOTALS.items():
        result += compare(
            label, found_totals[kind], allowed_totals[kind], "",
            f"lower its total row in {CEILING} to the new count")
    return result


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    print(f"Checking observation patterns under {root / APP} against {CEILING} ...")
    try:
        allowed = read_ceiling(root)
        found = scan(root)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"observation ratchet input error: {error}", file=sys.stderr)
        return 2
    types, publishers, totals = found
    print(f"  ObservableObject types: {sum(len(n) for n in types.values())} "
          f"(ceiling {sum(len(n) for n in allowed[0].values())})")
    for file, names in sorted(types.items()):
        print(f"    {file}: {', '.join(sorted(names))}")
    print(f"  {EXTERNAL_LABEL}: {sum(publishers.values())} "
          f"(ceiling {sum(allowed[1].values())})")
    for file, count in sorted(publishers.items()):
        print(f"    {file}: {count} (ceiling {allowed[1].get(file, 0)})")
    for kind, (label, _) in TOTALS.items():
        print(f"  {label}: {totals[kind]} (ceiling {allowed[2][kind]})")
    result = problems(found, allowed)
    for problem in result:
        print(f"  {problem}")
    if result:
        print(f"{len(result)} observation-ratchet problem(s) found.")
        return 1
    print("Observation patterns match the ratchet ceiling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
