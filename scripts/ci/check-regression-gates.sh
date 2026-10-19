#!/usr/bin/env bash
#
# Verify that the regression-gate tests listed in scripts/ci/regression-gates.txt
# still exist under their listed names, and that the gate lists in
# docs/reference/architecture-conventions.md §Regression gates, AGENTS.md and
# CONTRIBUTING.md name every gate and pin in that file. Fails CI if a rename
# or an edit has rotted either side.
#
# To add or remove a gate: update regression-gates.txt and all three docs in
# the same PR. check-regression-gates-ran.py reads the same file after the
# tests run and fails if a gate was missing or skipped.
#
# The rows come from the gate-list parser in check-regression-gates-ran.py.

set -euo pipefail

cd "$(dirname "$0")/../.."
SOURCE_MASKER="scripts/ci/swift_source.py"
GATE_LIST="scripts/ci/regression-gates.txt"
GATE_PARSER="scripts/ci/check-regression-gates-ran.py"

# Each entry is "<doc>|<heading of the section that holds its gate list>".
DOCS=(
  "docs/reference/architecture-conventions.md|## Regression gates"
  "AGENTS.md|## Cross-Cutting Contracts"
  "CONTRIBUTING.md|## Developing new features"
)

echo "Checking regression-gate test symbols in $GATE_LIST against photo-exportTests/..."

if ! ROWS="$(python3 -B "$GATE_PARSER" --print-rows --gate-list "$GATE_LIST")"; then
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

# The doc's gate section: from its heading to the next "#" or "##" heading.
gate_section() {
  local doc="$1" heading="$2"
  awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^##? / { exit }
    inside { print }
  ' "$doc"
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
  # One direction only: each listed gate and pin must be named in backticks in
  # the section; other names there (unrelated bullets) are not checked.
  section="$(gate_section "$doc" "$heading")"
  doc_ok=1
  while IFS= read -r symbol; do
    [[ -z "$symbol" ]] && continue
    if ! grep -Fq -- "\`$symbol\`" <<< "$section"; then
      echo "  DOC DRIFT: $doc does not list gate '$symbol' under '$heading'"
      doc_ok=0
    fi
  done <<< "$GATE_SYMBOLS"
  while IFS= read -r suite; do
    [[ -z "$suite" ]] && continue
    if ! grep -Eq -- "\`${suite}[.\`]" <<< "$section"; then
      echo "  DOC DRIFT: $doc does not mention pinned suite '$suite' under '$heading'"
      doc_ok=0
    fi
  done <<< "$PINNED_SUITES"
  if [[ $doc_ok -eq 1 ]]; then
    echo "  OK: $doc lists every gate"
  else
    drift=1
  fi
done

if [[ $drift -eq 1 ]]; then
  echo
  echo "A documented regression-gate list is missing gates from $GATE_LIST."
  echo "Name each gate in backticks, as SuiteName or SuiteName.methodName, in:"
  echo "  - docs/reference/architecture-conventions.md §Regression gates (table)"
  echo "  - AGENTS.md §Cross-Cutting Contracts"
  echo "  - CONTRIBUTING.md §Developing new features"
  exit 1
fi

echo "All documented regression-gate lists name every gate."
