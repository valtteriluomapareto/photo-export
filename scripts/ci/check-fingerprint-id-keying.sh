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
# Comment lines (`//`, `///`, `*`, `/*`) are ignored so docstrings can mention the old pattern.

set -euo pipefail

cd "$(dirname "$0")/../.."

echo "Checking for fingerprint-id keying outside the fingerprint module..."

matches=$(
  grep -rn --include='*.swift' -E '\bfingerprint\??\.id\b' photo-export \
    | grep -v '/Models/DestinationFingerprint.swift:' \
    | grep -v 'keying-id-ok' \
    | awk -F: '{
        content = $0
        sub(/^[^:]*:[^:]*:/, "", content)         # strip the  path:lineno:  prefix
        gsub(/^[[:space:]]+/, "", content)         # trim leading whitespace
        if (content !~ /^\/\// && content !~ /^\*/ && content !~ /^\/\*/) print
      }' \
    || true
)

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
