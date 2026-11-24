#!/usr/bin/env python3
"""Keep the project on explicit executor isolation while checking all concurrency."""
import pathlib
import re
import sys

FORBIDDEN = re.compile(
    r'SWIFT_APPROACHABLE_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION|'
    r'Nonisolated_?Nonsending_?By_?Default', re.IGNORECASE)


def main():
    project = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
        pathlib.Path(__file__).resolve().parents[2] / 'photo-export.xcodeproj/project.pbxproj')
    source = project.read_text()
    # Retain line positions while ignoring explanations in project comments.
    source = re.sub(r'/\*.*?\*/|//[^\n]*',
                    lambda match: ''.join('\n' if char == '\n' else ' ' for char in match[0]),
                    source, flags=re.DOTALL)
    matches = list(FORBIDDEN.finditer(source))
    for match in matches:
        line = source.count('\n', 0, match.start()) + 1
        print(f'{project}:{line}: forbidden executor-changing setting: {match[0]}', file=sys.stderr)
    return int(bool(matches))


if __name__ == '__main__':
    sys.exit(main())
