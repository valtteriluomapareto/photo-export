"""Narrow lexical masking for structural CI guards, not a Swift semantic parser.

Comments (including nested block comments) and string literals are replaced with
spaces while retaining newlines/offsets. String interpolation is not parsed as
Swift code; guards using this helper cannot establish semantic API isolation.
"""

import pathlib
import re
import sys


STRING_START = re.compile(r'(#*)("""|")')


def comment_end(source, index):
    if source.startswith("//", index):
        end = source.find("\n", index)
        return len(source) if end == -1 else end
    depth = 1
    index += 2
    while index < len(source) and depth:
        if source.startswith("/*", index):
            depth += 1
            index += 2
        elif source.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            index += 1
    if depth:
        raise ValueError("unterminated block comment")
    return index


def string_end(source, literal):
    hashes, quote = literal.groups()
    closing = quote + hashes
    escape = "\\" + hashes
    index = literal.end()
    while index < len(source):
        if source.startswith(closing, index):
            return index + len(closing)
        if source.startswith(escape + "(", index):
            index = interpolation_end(source, index + len(escape) + 1)
        elif source.startswith(escape, index):
            index += len(escape) + 1
        else:
            index += 1
    raise ValueError("unterminated string literal")


def interpolation_end(source, index):
    # Only balance delimiters so quotes/comments inside an interpolation cannot
    # corrupt the outer string boundary. The interpolation body stays masked.
    depth = 1
    while index < len(source):
        literal = STRING_START.match(source, index)
        if source.startswith(("//", "/*"), index):
            index = comment_end(source, index)
        elif literal:
            index = string_end(source, literal)
        else:
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
                if not depth:
                    return index + 1
            index += 1
    raise ValueError("unterminated string interpolation")


def code_only(source):
    output = list(source)
    index = 0
    while index < len(source):
        start = index
        if source.startswith(("//", "/*"), index):
            index = comment_end(source, index)
        else:
            literal = STRING_START.match(source, index)
            if literal is None:
                index += 1
                continue
            index = string_end(source, literal)
        output[start:index] = ["\n" if char == "\n" else " " for char in source[start:index]]
    return "".join(output)


if __name__ == "__main__":
    try:
        print(code_only(pathlib.Path(sys.argv[1]).read_text()), end="")
    except (OSError, UnicodeError, ValueError) as error:
        sys.exit(f"Swift source input error: {error}")
