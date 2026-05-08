# Phase 0a Simplicity Follow-ups

Date: 2026-05-08
Status: Notes (not actionable yet)

A simplicity review at the end of `auto-sync-phase-0a` (36 commits) flagged that
~50% of the branch is scaffolding for `AutoSyncManager`, which doesn't exist yet.
Verdict was **2/5 — meaningfully over-engineered**.

The decision after the review was **to not cut corners now** — keep the
foundation as-is and accept the over-engineering as a one-time cost, since the
`AutoSyncManager` work that consumes most of these foundations will land soon.
This file records the findings so they can be revisited when that work begins.

## When `AutoSyncManager` lands, reconsider:

### Likely-real simplifications

- **`DestinationFingerprint` is overbuilt ~3x.** Factory methods enforcing
  `.high ↔ UUID` invariants, `schemaVersion`-switched id derivation with
  `idV1` extraction, Codable with custom CodingKeys excluding `id`,
  `preconditionFailure` on unknown schemaVersion. For one user / one developer
  / one schema, a ~50-line struct with `volumeUUIDString: String?`, paths,
  `confidence`, and a computed `id` would suffice. Add schemaVersion the first
  time the format actually breaks.

- **`AppLifecycleCoordinator` could shed ~80 lines.** Drop
  `DestinationIdentitySnapshot` (use `fingerprint?.id` directly), drop the
  defensive `(nil, nil)` branch in the tuple switch, possibly drop the
  `dispatchPrecondition` + `MainActor.assumeIsolated` ceremony if a future
  contributor adds Swift-6-strict isolation. Inject managers directly instead
  of via closures.

- **`runExport(context:)` hook plumbing might be replaceable.** The 5+
  terminal-hook call sites + `ActiveRunBookkeeping` could be replaced with one
  `$hasActiveExportWork` observer + one `@Published var lastTerminalReason`
  set by `cancelAndClear` and `interruptForDestinationUnavailable`. Same
  information, no scattered hooks. Worth measuring before refactoring — the
  scattered hooks have the advantage of carrying per-site context (which catch
  path failed, etc.).

- **Run-scope cases that don't work yet.** `ExportRunScope` has 4 cases that
  immediately resolve as `.failed`: `.timelineAssets`, `.favoritesAssets`,
  `.allAlbumsAssets`, `.autoExport`. Add them when their consumers land.
  `ExportRunVisibility` is derivable from `source` and could collapse to a
  computed property.

### Maybe-cuts (depends on what AutoSyncManager actually needs)

- **`AutoSyncDirtyState` / `AutoSyncRetryState` cluster** — `ScopeDirtyState`,
  `RetryEntry`, `AutoSyncRetryScopeKey`, the corresponding stores (in-memory +
  file-backed). Zero production callers. The reducer's actual call sites will
  tell you the right shape — these may need to be rewritten when wired up.
  Consider: if the reducer wants a different shape, delete these and rewrite
  rather than awkwardly bending the existing types.

- **`PhotoLibraryPersistentChangeEvent`, `PhotoLibraryPersistentChangeFetchError`,
  `PhotoLibraryChangeProviding`, `FakePersistentChangeSource`.** Only
  consumed by tests of the helpers themselves. May need reshaping when the
  real PhotoKit observer adapter is written.

- **`AutoSyncBlockedReason`, `AutoSyncFailureCategory`.** No production
  callers. Less likely to need reshaping (these are pretty mechanical enums)
  but the cases may want adjustment when the real classifier is written.

- **`TestClock` (90 lines + 143 lines of tests for the test helper).**
  Justified the moment any debounce/retry test exists. None do today.
  Defer to first reducer test.

### What's defended (don't simplify)

- **`cancelAndClear` vs `interruptForDestinationUnavailable` split.**
  Legitimate semantic distinction — "user said stop" vs "drive went away" —
  needed so accumulated work can resume on remount. Keep.

- **`runExport(context:)` itself (the awaitable wrapper).** Keep, possibly
  simplified per above.

- **The lifecycle coordinator** (simplified). Bootstrap genuinely shouldn't
  live in a view `.task`.

- **`runExport`'s `precondition(activeRunContext == nil)`.** Single-active-run
  enforcement; don't soften.

## Plan-level revisions to consider

When AutoSyncManager work begins, these plan sections may want revising:

- **§"Stable Destination Identity"**: the `schemaVersion` + `identityConfidence`
  migration paragraphs drove `DestinationFingerprint`'s complexity. For a
  personal app, "add schemaVersion when you break the format" is enough.

- **§"State Reducer"**: pure reducer with `[AutoSyncEffect]` returns and
  serialized dispatch is patterned for scale. With ~5 events and ~3 effects,
  an `if/else` ladder with direct timer/await calls is simpler, equally
  testable if `Clock` and the export-runner are injected.

- **§"Phase 0 Test Infrastructure"**: the plan mandates `TestClock`,
  fault-injection helpers, and persistence stores land "alongside 0a so
  reducer/run-level tests are deterministic from day one." But no reducer
  tests exist in 0a. Build the helpers when their first consuming test lands.

## Decision rule for the next round

When deciding whether to keep, simplify, or delete a Phase 0a foundation
piece during the AutoSyncManager work:

> If the reducer's actual call shape differs from what's already built, prefer
> rewriting to bending. Phase 0a foundations are cheap because they have no
> consumers; the cost of changing them is bounded.
