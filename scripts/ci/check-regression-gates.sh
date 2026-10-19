#!/usr/bin/env bash
#
# Verify that the regression-gate tests listed in scripts/ci/regression-gates.txt
# still exist under their listed names, and that the gate lists in
# docs/reference/architecture-conventions.md §Regression gates, AGENTS.md and
# CONTRIBUTING.md match that file. Fails CI if a rename or an edit has rotted
# either side.
#
# To add or remove a gate: update regression-gates.txt and all three docs in
# the same PR. check-regression-gates-ran.py reads the same file after the
# tests run and fails if a gate was missing or skipped.
#
# Usage: check-regression-gates.sh [--print-gates [LIST]]
#   --print-gates prints the parsed rows as <file>|<kind>|<declaration> and
#   exits; the self-tests compare it with the Python reader.

set -euo pipefail

cd "$(dirname "$0")/../.."
SOURCE_MASKER="scripts/ci/swift_source.py"
GATE_LIST="scripts/ci/regression-gates.txt"

# Each entry is "<doc>|<heading of the section that holds its gate list>".
DOCS=(
  "docs/reference/architecture-conventions.md|## Regression gates"
  "AGENTS.md|## Cross-Cutting Contracts"
  "CONTRIBUTING.md|## Developing new features"
)

STRUCT_DECLARATION='^struct [A-Za-z_][A-Za-z0-9_]*$'
FUNC_DECLARATION='^func [A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$'

trim() {
  if [[ "$1" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Print each row of the gate list as "<file>|<kind>|<declaration>". Text from
# "#" to the end of a line is a comment; blank lines are ignored; fields are
# trimmed. Malformed rows are reported on stderr and make the function fail.
# check-regression-gates-ran.py implements the same rules.
parse_gate_list() {
  local list="$1" line pipes file kind declaration number=0 rows=0 invalid=0
  if [[ ! -f "$list" ]]; then
    echo "  MISSING GATE LIST: $list" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    line="${line%$'\r'}"
    line="$(trim "${line%%#*}")"
    [[ -z "$line" ]] && continue
    pipes="${line//[^|]/}"
    if [[ ${#pipes} -ne 2 ]]; then
      echo "  INVALID ROW: $list:$number: expected <file>|<gate|pin>|<declaration>: $line" >&2
      invalid=1
      continue
    fi
    file="$(trim "${line%%|*}")"
    kind="${line#*|}"
    kind="$(trim "${kind%%|*}")"
    declaration="$(trim "${line##*|}")"
    if [[ -z "$file" ]]; then
      echo "  INVALID ROW: $list:$number: empty test file: $line" >&2
      invalid=1
    elif [[ "$kind" != "gate" && "$kind" != "pin" ]]; then
      echo "  INVALID ROW: $list:$number: kind must be 'gate' or 'pin', not '$kind'" >&2
      invalid=1
    elif [[ "$kind" == "pin" ]] && ! [[ "$declaration" =~ $STRUCT_DECLARATION ]]; then
      echo "  INVALID ROW: $list:$number: a pin must be 'struct SuiteName', not '$declaration'" >&2
      invalid=1
    elif ! [[ "$declaration" =~ $STRUCT_DECLARATION || "$declaration" =~ $FUNC_DECLARATION ]]; then
      echo "  INVALID ROW: $list:$number: declaration must be 'struct SuiteName' or 'func SuiteName.methodName', not '$declaration'" >&2
      invalid=1
    else
      printf '%s|%s|%s\n' "$file" "$kind" "$declaration"
      rows=$((rows + 1))
    fi
  done < "$list"
  if [[ $invalid -eq 0 && $rows -eq 0 ]]; then
    echo "  EMPTY GATE LIST: $list has no rows" >&2
    invalid=1
  fi
  [[ $invalid -eq 0 ]]
}

if [[ "${1:-}" == "--print-gates" ]]; then
  parse_gate_list "${2:-$GATE_LIST}"
  exit
fi

echo "Checking regression-gate test symbols in $GATE_LIST against photo-exportTests/..."

if ! ROWS="$(parse_gate_list "$GATE_LIST")"; then
  echo
  echo "Fix $GATE_LIST before checking gate symbols."
  exit 1
fi

# Report whether a lexically masked Swift source declares the given symbol.
declares() {
  local kind="$1" symbol="$2" code="$3" pattern
  # Mask comments/string literals and require a complete identifier, so a
  # commented-out declaration or NameExtra cannot keep a deleted gate green.
  if [[ "$kind" == "func" ]]; then
    pattern="(^|[[:space:]])func[[:space:]]+${symbol}[[:space:]]*\\("
  else
    pattern="(^|[[:space:]])struct[[:space:]]+${symbol}([[:space:]]|[:{])"
  fi
  grep -Eq -- "$pattern" <<< "$code"
}

failed=0
GATE_SYMBOLS=""
PINNED_SUITES=""
while IFS='|' read -r file kind needle; do
  symbol="${needle#* }"
  if [[ "$kind" == "gate" ]]; then
    GATE_SYMBOLS+="$symbol"$'\n'
  else
    PINNED_SUITES+="$symbol"$'\n'
  fi
  if [[ ! -f "$file" ]]; then
    echo "  MISSING FILE: $file (looking for: $needle)"
    failed=1
    continue
  fi
  code="$(python3 "$SOURCE_MASKER" "$file" < /dev/null)"
  if [[ "$needle" == func\ * ]]; then
    suite="${symbol%%.*}"
    method="${symbol#*.}"
    if ! declares func "$method" "$code"; then
      echo "  MISSING SYMBOL: 'func $method' not found in $file"
      failed=1
      continue
    fi
    if ! declares struct "$suite" "$code"; then
      echo "  MISSING SYMBOL: 'struct $suite' (suite of '$needle') not found in $file"
      failed=1
      continue
    fi
  elif ! declares struct "$symbol" "$code"; then
    echo "  MISSING SYMBOL: '$needle' not found in $file"
    failed=1
    continue
  fi
  echo "  OK: $kind $needle in $file"
done <<< "$ROWS"

if [[ $failed -eq 1 ]]; then
  echo
  echo "One or more regression-gate symbols are missing from the codebase."
  echo "If a regression-gate test was intentionally renamed or moved, update:"
  echo "  - $GATE_LIST"
  echo "  - docs/reference/architecture-conventions.md §Regression gates"
  echo "  - the gate lists in AGENTS.md and CONTRIBUTING.md"
  exit 1
fi

echo "All regression-gate symbols present."
echo
echo "Checking the documented gate lists against $GATE_LIST..."

# The first backticked name of a table row or bullet in the doc's gate section.
listed_gates() {
  local doc="$1" heading="$2"
  awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^##? / { exit }
    inside { print }
  ' "$doc" | sed -nE 's/^[[:space:]]*[|-][[:space:]]*\[?`([^`]+)`.*/\1/p'
}

drift=0
for entry in "${DOCS[@]}"; do
  doc="${entry%%|*}"
  heading="${entry#*|}"
  if [[ ! -f "$doc" ]]; then
    echo "  DOC DRIFT: $doc is missing"
    drift=1
    continue
  fi
  if ! grep -Fxq -- "$heading" "$doc"; then
    echo "  DOC DRIFT: $doc has no '$heading' section"
    drift=1
    continue
  fi
  listed="$(listed_gates "$doc" "$heading")"
  doc_ok=1
  while IFS= read -r symbol; do
    [[ -z "$symbol" ]] && continue
    if ! grep -Fxq -- "$symbol" <<< "$listed"; then
      echo "  DOC DRIFT: $doc does not list gate '$symbol' under '$heading'"
      doc_ok=0
    fi
  done <<< "$GATE_SYMBOLS"
  while IFS= read -r suite; do
    [[ -z "$suite" ]] && continue
    if ! grep -Eq -- "^${suite}\\." <<< "$listed"; then
      echo "  DOC DRIFT: $doc does not mention pinned suite '$suite' under '$heading'"
      doc_ok=0
    fi
  done <<< "$PINNED_SUITES"
  while IFS= read -r symbol; do
    [[ -z "$symbol" ]] && continue
    if ! grep -Fxq -- "$symbol" <<< "$GATE_SYMBOLS"; then
      echo "  DOC DRIFT: $doc lists '$symbol' under '$heading', but it is not a gate in $GATE_LIST"
      doc_ok=0
    fi
  done <<< "$listed"
  if [[ $doc_ok -eq 1 ]]; then
    echo "  OK: $doc lists every gate"
  else
    drift=1
  fi
done

if [[ $drift -eq 1 ]]; then
  echo
  echo "The documented regression-gate lists differ from $GATE_LIST."
  echo "Keep these in step with the list file, naming each gate as SuiteName or"
  echo "SuiteName.methodName in backticks at the start of its row or bullet:"
  echo "  - docs/reference/architecture-conventions.md §Regression gates (table)"
  echo "  - AGENTS.md §Cross-Cutting Contracts"
  echo "  - CONTRIBUTING.md §Developing new features"
  exit 1
fi

echo "All documented regression-gate lists match."
