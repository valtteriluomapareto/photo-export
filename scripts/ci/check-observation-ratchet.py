#!/usr/bin/env python3
"""Ratchet the app's remaining Combine-observation patterns down, never up.

The app is moving from `ObservableObject` to `@Observable` one type at a time
(docs/reference/observation-migration-recipe.md). While that happens, new code
(including code arriving from main) must not add old-pattern uses. This guard
counts, per file under photo-export/:

- `ObservableObject` conformances, by type name (class, struct, actor or extension
  declarations whose inheritance clause names it, across line breaks);
- `@Published` declarations;
- external `$publisher` uses: a `$property` projection reached through another
  object (`manager.$identity`, also wrapped onto the next line). The owning type's
  own `$property` and `self.$property` are internal and not counted; neither are
  binding projections such as `$model.flag`;
- `.environmentObject(` calls.

It compares them with scripts/ci/observation-ratchet.txt and fails when a count
rises, when a file or type appears that the file does not list, and also when a
count falls or a type stops conforming, so the ceiling is lowered in the same
change and cannot creep back up later.

This is a lexical guard over comment- and string-masked source, like the other
structural guards.
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
    r"\b(?:class|struct|actor|extension)\s+([A-Za-z_][\w.]*)(?:\s*<[^{>]*>)?\s*:([^{]*)\{")
OBSERVABLE_OBJECT = re.compile(r"\bObservableObject\b")
PUBLISHED = re.compile(r"@Published\b")
EXTERNAL_PUBLISHER = re.compile(r"\.\s*\$[A-Za-z_]\w*")
SELF_RECEIVER = re.compile(r"(?<![\w.])self\s*$")
ENVIRONMENT_OBJECT = re.compile(r"\.\s*environmentObject\s*\(")

COUNTED = collections.OrderedDict([
    ("published", "@Published declarations"),
    ("external-publisher", "external $publisher uses"),
    ("environment-object", ".environmentObject( calls"),
])
KINDS = {"type", *COUNTED}


def scan(root):
    """Return ({path: set(type names)}, {kind: {path: count}}) for the app tree."""
    types = {}
    counts = {kind: {} for kind in COUNTED}
    for path in sorted((root / APP).rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        code = code_only(path.read_text())
        names = {
            match.group(1) for match in TYPE_DECLARATION.finditer(code)
            if OBSERVABLE_OBJECT.search(match.group(2))
        }
        if names:
            types[relative] = names
        external = sum(
            1 for match in EXTERNAL_PUBLISHER.finditer(code)
            if not SELF_RECEIVER.search(code[max(0, match.start() - 64):match.start()]))
        for kind, value in (
            ("published", len(PUBLISHED.findall(code))),
            ("external-publisher", external),
            ("environment-object", len(ENVIRONMENT_OBJECT.findall(code))),
        ):
            if value:
                counts[kind][relative] = value
    return types, counts


def read_ceiling(root):
    types = collections.defaultdict(set)
    counts = {kind: {} for kind in COUNTED}
    path = root / CEILING
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split("|")]
        if len(fields) != 3 or not all(fields):
            raise ValueError(f"{CEILING}:{number}: expected kind|path|value, got {raw!r}")
        kind, file, value = fields
        if kind not in KINDS:
            raise ValueError(f"{CEILING}:{number}: unknown kind {kind!r}")
        if kind == "type":
            types[file].add(value)
            continue
        if not value.isdigit():
            raise ValueError(f"{CEILING}:{number}: {kind} ceiling must be a count, got {value!r}")
        if file in counts[kind]:
            raise ValueError(f"{CEILING}:{number}: duplicate {kind} row for {file}")
        counts[kind][file] = int(value)
    return types, counts


def problems(found_types, found_counts, allowed_types, ceilings):
    found = []
    for file in sorted(set(found_types) | set(allowed_types)):
        for name in sorted(found_types.get(file, set()) - allowed_types.get(file, set())):
            found.append(
                f"{file}: new ObservableObject type {name}; make it @Observable "
                "(see docs/reference/observation-migration-recipe.md)")
        for name in sorted(allowed_types.get(file, set()) - found_types.get(file, set())):
            found.append(
                f"{file}: {name} no longer conforms to ObservableObject; "
                f"remove its row from {CEILING}")
    for kind, label in COUNTED.items():
        actual, ceiling = found_counts[kind], ceilings[kind]
        for file in sorted(set(actual) | set(ceiling)):
            now, limit = actual.get(file, 0), ceiling.get(file, 0)
            if now > limit:
                found.append(
                    f"{file}: {label} rose from {limit} to {now}; use the Observation "
                    "pattern instead (see docs/reference/observation-migration-recipe.md)")
            elif now < limit:
                found.append(
                    f"{file}: {label} fell from {limit} to {now}; lower its row in {CEILING} "
                    "to the new count (or remove it at zero)")
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    print(f"Checking observation patterns under {root / APP} against {CEILING} ...")
    try:
        allowed_types, ceilings = read_ceiling(root)
        found_types, found_counts = scan(root)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"observation ratchet input error: {error}", file=sys.stderr)
        return 2
    type_total = sum(len(names) for names in found_types.values())
    print(f"  ObservableObject types: {type_total} "
          f"(ceiling {sum(len(names) for names in allowed_types.values())})")
    for file, names in sorted(found_types.items()):
        print(f"    {file}: {', '.join(sorted(names))}")
    for kind, label in COUNTED.items():
        print(f"  {label}: {sum(found_counts[kind].values())} "
              f"(ceiling {sum(ceilings[kind].values())})")
        for file, count in sorted(found_counts[kind].items()):
            print(f"    {file}: {count} (ceiling {ceilings[kind].get(file, 0)})")
    found = problems(found_types, found_counts, allowed_types, ceilings)
    for problem in found:
        print(f"  {problem}")
    if found:
        print(f"{len(found)} observation-ratchet problem(s) found.")
        return 1
    print("Observation patterns match the ratchet ceiling.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
