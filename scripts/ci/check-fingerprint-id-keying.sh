#!/usr/bin/env bash
#
# Structural guard for the destination-identity contract
# (docs/reference/architecture-conventions.md §Destination identity).
#
# Per-destination state (record stores, AutoSync state, current-run journal, safety
# confirmation) MUST be keyed on the **stable logical id** (`identity.stableId` /
# `snapshot.id` / `snapshot.stableId`), never on `fingerprint?.id`. The fingerprint id is
# advisory (identity-confidence) and drifts when a network share remounts under a new path —
# keying on it is the root cause of the duplicate re-export in #127.
#
# A behavioral test can only cover the paths it exercises; it cannot prove the *absence* of a
# future consumer that re-derives the key from the fingerprint. This grep does.
#
# The pattern is `\bfingerprint\??\.id` — it catches both member reads (`snapshot.fingerprint?.id`)
# AND bare local/parameter reads (`let key = fingerprint?.id`), since the latter is the most
# likely way a future consumer re-derives the key from the fingerprint.
#
# Allowed exceptions:
#   - photo-export/Models/DestinationFingerprint.swift — the module that owns the derivation.
#   - any line tagged with the marker  keying-id-ok  (the seed site that turns a freshly computed
#     fingerprint into the *seed* for a brand-new stable id, and the no-drift convenience inits
#     that intentionally track the fingerprint id).
# Lines whose first non-space character begins a comment (`//`, `*`, `/*`) are ignored so
# docstrings can mention the old pattern. (Note: a *trailing* inline comment mentioning the
# pattern on an otherwise-code line would still match — keep such mentions on their own
# comment line.)
#
# Run with `--self-test` to verify the guard itself catches a bad input and passes a good one.

set -euo pipefail

cd "$(dirname "$0")/../.."

# Emits the forbidden keying lines found under <dir>, after applying the exceptions above.
scan() {
  local dir="$1"
  grep -rn --include='*.swift' -E '\bfingerprint\??\.id\b' "$dir" \
    | grep -v '/Models/DestinationFingerprint.swift:' \
    | grep -v 'keying-id-ok' \
    | awk -F: '{
        content = $0
        sub(/^[^:]*:[^:]*:/, "", content)         # strip the  path:lineno:  prefix
        gsub(/^[[:space:]]+/, "", content)         # trim leading whitespace
        if (content !~ /^\/\// && content !~ /^\*/ && content !~ /^\/\*/) print
      }' \
    || true
}

# Self-test: prove the guard fails on a bad fixture and passes a good one. Run in CI before the
# real scan so a regex/awk regression that silently neuters the guard is caught.
if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  printf 'let key = snapshot.fingerprint?.id\n' > "$tmp/Bad.swift"
  if [[ -z "$(scan "$tmp")" ]]; then
    echo "SELF-TEST FAILED: a bad keying line ('snapshot.fingerprint?.id') was NOT caught."
    exit 1
  fi
  rm "$tmp/Bad.swift"
  printf 'let k = snapshot.fingerprint?.id  // keying-id-ok\n/// doc mentions fingerprint?.id\n' \
    > "$tmp/Good.swift"
  if [[ -n "$(scan "$tmp")" ]]; then
    echo "SELF-TEST FAILED: a good fixture (marked / commented) was flagged:"
    scan "$tmp" | sed 's/^/    /'
    exit 1
  fi
  echo "Guard self-test passed."
  exit 0
fi

echo "Checking for fingerprint-id keying outside the fingerprint module..."

matches="$(scan photo-export)"

if [[ -n "$matches" ]]; then
  echo
  echo "  FORBIDDEN: per-destination keying must use the stable id, not fingerprint?.id."
  echo "$matches" | sed 's/^/    /'
  echo
  echo "  Key on the stable logical id instead (identity.stableId / snapshot.id /"
  echo "  snapshot.stableId). The fingerprint id is advisory and drifts on network-share"
  echo "  remount — keying on it re-exports everything (#127). See"
  echo "  docs/reference/architecture-conventions.md §Destination identity."
  echo "  If this is a legitimate non-keying read (e.g. seeding a fresh stable id), append a"
  echo "  '// keying-id-ok' marker on that line explaining why."
  exit 1
fi

echo "No forbidden fingerprint-id keying found."
