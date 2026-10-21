#!/usr/bin/env python3
"""Require current reasons instead of development-phase references in app comments.

This is lexical, not semantic: reuse the shared Swift comment/string boundaries.
String interpolation stays masked with its containing string, as in the other guards.
"""
import pathlib
import re
import sys

from swift_source import STRING_START, comment_end, string_end

REFERENCE = re.compile(r'\bphase[\s-]*\d+[a-z]?\b|\bplan\s*§|\bitem\s+\d+\b', re.IGNORECASE)
DELIMITERS = re.compile(r'//+|/\*|\*/')
REGEX_START = re.compile(r'(#+)/')


def regex_end(source, literal):
    closing = '/' + literal.group(1)
    index = literal.end()
    while index < len(source):
        if source.startswith(closing, index):
            return index + len(closing)
        # Escaped pattern characters cannot begin the closing delimiter.
        index += 2 if source[index] == '\\' else 1
    raise ValueError('unterminated extended regex literal')


def comments_only(source):
    # NULs prevent a reference from joining comments across executable code.
    output = ['\n' if char == '\n' else (' ' if char.isspace() else '\0') for char in source]
    index = 0
    while index < len(source):
        if source.startswith(('//', '/*'), index):
            end = comment_end(source, index)
            comment = DELIMITERS.sub(lambda match: ' ' * len(match.group()), source[index:end])
            output[index:end] = comment
            index = end
        else:
            regex = REGEX_START.match(source, index)
            literal = STRING_START.match(source, index)
            if regex:
                index = regex_end(source, regex)
            else:
                index = string_end(source, literal) if literal else index + 1
    return ''.join(output)


def problems(root):
    app = root / 'photo-export'
    files = sorted(app.rglob('*.swift')) if app.is_dir() else []
    if not files:
        raise ValueError(f'no Swift sources under {app}')
    found = []
    for path in files:
        try:
            source = comments_only(path.read_text())
        except (OSError, UnicodeError, ValueError) as error:
            raise ValueError(f'{path.relative_to(root)}: {error}') from error
        for match in REFERENCE.finditer(source):
            line = source.count('\n', 0, match.start()) + 1
            found.append(f'{path.relative_to(root)}:{line}: development-plan reference; '
                         'describe the current reason and link a maintained reference')
    return found


def main():
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path('.')
    print(f'Checking development-plan references in {root / "photo-export"} ...')
    try:
        found = problems(root)
    except (OSError, UnicodeError, ValueError) as error:
        print(f'Swift comment input error: {error}', file=sys.stderr)
        return 2
    for problem in found:
        print(problem)
    if found:
        print(f'{len(found)} prohibited comment reference(s) found.')
        return 1
    print('App comments use current reasons without plan/phase/item references.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
