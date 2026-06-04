# Destination Identity Simplification Plan

Date: 2026-06-04
Status: Proposed (not started). Fixes the root cause behind
[issue #127](https://github.com/valtteriluomapareto/photo-export/issues/127)
(duplicate re-export on a network-share backup drive).

## Summary

Export records live in **App Support**, keyed by a `DestinationFingerprint`
hashed into a per-destination directory name
(`<App Support>/<bundleId>/ExportRecords/<destinationId>/`). The same id keys
AutoSync state (`AutoSync/destinations/<destinationId>/`), the current-run
journal, and the safety-confirmation store. That id must be a permanently
stable key, but on network shares there is no volume UUID, so it degrades to a
path-based digest that drifts across remount → the app opens an empty record
directory → re-exports everything → duplicates.

**The fix is to stop deriving the keying id from volume properties that drift.**
Introduce a **stable logical destination id**, persisted next to the
security-scoped bookmark, seeded on upgrade from the current fingerprint id, and
reused for as long as the stored bookmark resolves to the same folder. It is
refreshed only when the user explicitly selects a *new* destination.
`DestinationFingerprint` stays — but only as the identity-*confidence* signal for
the AutoSync safety gate.

There is **no single two-line seam** for this. The id is re-derived from the
fingerprint across several independent sites (four keying reads plus two
`removeDuplicates` filters), so the stable id must be threaded through the
identity snapshot the manager publishes and every site re-pointed at it — a
bounded but multi-file change, specified below. The slot/scan/dotfile redesign
remains [deferred](#deferred-optional-persistence-model-simplification).

## Root cause

- `DestinationFingerprint.id` (`photo-export/Models/DestinationFingerprint.swift`)
  is `SHA-256(volumeUUID ‖ U+0000 ‖ relativePath)` for `.high` confidence drives,
  and `SHA-256("" ‖ U+0000 ‖ standardizedPath)` for `.low` confidence drives (no
  volume UUID — network shares, exFAT). Network shares have no volume UUID and
  unstable mount paths, so `id` drifts across remount.
- That id keys **four** subsystems, and — critically — each one **re-derives it
  from the fingerprint independently**; they do *not* funnel through one symbol:
  1. **Record dirs** — `AppLifecycleCoordinator` subscribes to the fingerprint
     publisher and builds `DestinationIdentitySnapshot(fingerprint:)` whose
     `id == fingerprint?.id` (`AppLifecycleCoordinator.swift:43`), then passes
     `destination.id` to `configureRecordStores`. It never reads
     `ExportDestinationManager.destinationId`.
  2. **AutoSync** dirty state / per-destination tokens / retry state / run
     summaries — `AutoSyncManager.handleDestinationSnapshot` reads
     `snapshot.fingerprint?.id` directly (`AutoSyncManager.swift:207`).
  3. **Current-run journal** — keys on the reducer's `destination.id`, which is
     `DestinationSnapshot.id == fingerprint?.id`
     (`DestinationSnapshot.swift:20`).
  4. **Safety-confirmation store** — `DestinationSafetyMonitor` computes
     `currentFingerprint?.id` (`DestinationSafetyMonitor.swift:123/141/146/176`).
- So the real coupling point is `DestinationFingerprint.id`, recomputed in four
  call sites. A network-share remount drifts it and simultaneously (a) re-keys
  the record store to an empty dir → duplicates, and (b) orphans pending AutoSync
  dirty work, retry state, diagnostics, and the user's safety confirmation. A fix
  must re-key **all four**, not just the record store.

## Phase 0 — Stable logical destination id (the #127 fix)

### The seam: one atomic identity snapshot

Today `ExportDestinationManager` pair-writes two `@Published` fields
(`destinationFingerprint` then `destinationId`) via `setIdentity`
(`ExportDestinationManager.swift:428-431`), and a documented contract tells
subscribers to read `fingerprint?.id` to avoid the mid-emission gap. Once the
stable id diverges from `fingerprint.id`, that contract **inverts** — the field
the docs say is safe (`fingerprint?.id`) becomes the wrong, drift-prone value,
and a subscriber could observe a new fingerprint with the old stable id.

Fix the seam, don't paper over it:

- Replace the pair-write with a **single published identity value** carrying both
  the stable id and the fingerprint together — e.g. a
  `DestinationIdentity { stableId: String?, fingerprint: DestinationFingerprint? }`
  emitted atomically. `destinationId` becomes a read-through of `stableId`.
- Add an explicit `stableId` to `DestinationIdentitySnapshot`
  (`AppLifecycleCoordinator.swift` — relax the current "no separate id" init ban)
  and to `DestinationSnapshot`, and have `DestinationSnapshotAdapter` carry it.
- Re-point every id-keying read at the stable id. Six sites, not four — two are
  `removeDuplicates` filters that derive identity from `fingerprint.id` and would
  otherwise slip a grep guard that only looks at keying reads:
  1. Record-store configure path (`DestinationIdentitySnapshot.id`,
     `AppLifecycleCoordinator.swift:43`).
  2. `AutoSyncManager.handleDestinationSnapshot:207`.
  3. The reducer's `destination.id` source (`DestinationSnapshot.id`).
  4. `DestinationSafetyMonitor` confirmation/evaluate calls (`:123/141/146/176`).
  5. **Dedup filter** in `DestinationSafetyMonitor.attach`
     (`:112`, `removeDuplicates(by: { $0?.id == $1?.id })`) — must compare
     `stableId`, else a drifted remount re-fires evaluation.
  6. **Same-id branch** in `AppLifecycleCoordinator.apply` (`:146/159`,
     `removeDuplicates()` + `destination.id == currentDestination.id`) — must
     compare `stableId`, else a stable-id remount with a drifted fingerprint is
     misclassified as a destination change and triggers `cancelActiveWork()` /
     reconfigure.
- A seventh, read-through, site: `SaveDiagnosticReportCommand` reads
  `destinationManager.destinationId` for `currentRunStore.load(destinationId:)`
  (`photo_exportApp.swift:582`). Keep `destinationId` a read-through of `stableId`
  and this stays correct with no edit; just don't break the read-through.
- Add a build-phase lint/grep guard forbidding `.fingerprint?.id` /
  `.fingerprint.id` keying outside the fingerprint module. This is a structural
  invariant a behavioral test can't prove (it can only cover the paths it
  exercises, not the absence of a future eighth consumer).
- Keep `DestinationFingerprint` exactly as-is; consumers that need
  `identityConfidence` (the safety gate) keep reading it from the same snapshot.
  The snapshot's `Equatable` deliberately still carries the drifting fingerprint
  fields, so the reducer/adapter `Equatable` filters do **not** dedup a remount —
  that is intentional (metadata refresh flows through); `stableId` equality, not
  struct equality, is the no-re-key line of defense. Don't "fix" it by excluding
  the fingerprint from `Equatable`.

This is a multi-file re-point, each site covered by a test — not two symbol edits.
Adding `stableId` to `DestinationSnapshot` is source-breaking for the ~30
positional `DestinationSnapshot(fingerprint:…)` constructions in
`AutoSyncReducerTests`; budget for the mechanical churn.

### Stable-id lifecycle

- Add a persisted `ExportDestinationStableId` (`UserDefaults`, beside
  `ExportDestinationBookmark`).
- **Restore (launch):** after the stored bookmark resolves and `validate(url:)`
  confirms availability:
  - Absent stable id (upgrading user): seed it with the currently computed
    `DestinationFingerprint.id` and persist. (See [Migration](#migration) for why
    this is *usually* but not always a zero-move adoption.)
  - Present: **reuse verbatim**, ignoring recomputed-fingerprint drift. This is
    the line that fixes #127.
  - Never seed from a `nil` fingerprint (drive unmounted at first launch); defer
    seeding to the first successful validate. While deferred, the id is `nil` and
    all keyed stores must no-op cleanly (verify).
- **Unavailable destination invariant:** distinguish the *persisted* stable id
  (private, kept across launches for reuse) from the *published active* stable id
  (what the identity snapshot emits). When the destination is unavailable
  (`fingerprint == nil` / `isAvailable == false`), the published active id must be
  `nil` — exactly as `setIdentity(nil)` clears identity today. Publishing the
  persisted id while unavailable would make `AppLifecycleCoordinator.apply` see an
  unchanged id and skip `interruptForDestinationUnavailable`, breaking
  cancellation/unconfigure on unplug.
- **Explicit new-destination selection:** the stable id is refreshed **only** when
  the user deliberately chooses a different destination. Do **not** mint a new id
  on canonical-path difference (see [the re-selection trap](#the-re-selection-trap)).

### The re-selection trap (do not use path as the signal)

A network share's canonical path is *exactly* the drift-prone signal. So
"mint a new id when the path differs" would re-introduce #127 through the picker:
a user who re-grants access to the **same** backup folder after a stale-bookmark
prompt (a normal recovery flow) would get a new id, fork the record directory, and
the next export duplicates into the same folder. Rules:

- While the stored bookmark resolves, **keep the persisted id** regardless of path
  drift.
- On an explicit `selectFolder()` pick, key same-vs-different on **bookmark
  equivalence**, not path: resolve the *stored* bookmark (as
  `restoreBookmarkIfAvailable` already does, capturing
  `stashedLegacyDestinationId`) and compare the resolved folder against the freshly
  picked one **before** overwriting the bookmark or clearing
  `stashedLegacyDestinationId`. Same folder → keep the stable id and the stashed
  legacy id; only a confirmed different folder mints a new id and clears legacy
  state. `clearSelection` always drops the id.
- When the evidence is genuinely ambiguous (e.g. the stored bookmark won't
  resolve), surface a confirmation rather than silently forking.

Operationally this means `setSelectedFolder` must do its same-vs-new decision up
front. The decision needs the stored-bookmark resolution as an input, so the
test seam must cover more than `fingerprintProvider` — see
[Testability](#testability-seam-prerequisite).

### Testability seam (prerequisite)

The #127 guarantee is unprovable today: `DestinationFingerprint.compute(for:)` is
a *static* function that reads live `URLResourceValues` off a real `URL`, called
from `ExportDestinationManager.validate(url:)` via the static
`computeDestinationFingerprint(for:)`. There is no closure or protocol to stub.
Add an injectable fingerprint source on the manager —
`fingerprintProvider: (URL) -> DestinationFingerprint?` defaulting to
`DestinationFingerprint.compute(for:)?.fingerprint` — threaded through
`validate(url:)` **and** the selection path (the re-selection rule lives in
`setSelectedFolder`, which has no seam today). With it, the network-share repro
becomes a pure unit/integration test, no real share needed:

1. Select folder, export N files, land N records under stable id S.
2. Feed a *drifted* low-confidence fingerprint for the **same** folder.
3. Assert: `stableId` still S; the emitted identity snapshot carries S; the record
   store is unchanged; `dirtyStateByDestination[S]` survives; the safety
   confirmation does not re-prompt; a subsequent export adds **zero** duplicates.

Note steps asserting the snapshot/AutoSync/safety id are only writable once
`DestinationSnapshot`/`DestinationIdentitySnapshot` carry an explicit `stableId`
(the seam work above) — they cannot be written against the fingerprint-derived id.
A low-confidence drift fixture must vary `standardizedPath` (the field the id
hashes), not just `volumeRootPath`, or the "drift" is a no-op.

Two more seams the listed tests need, beyond `fingerprintProvider`:

- **Seed/migrate/freeze ordering** currently lives in the *static*
  `PhotoExportApp.configureRecordStores`, entangled with `ExportDestinationManager`
  and the coordinator. To assert "seed equals the id the coordinator targets, and
  the `ExportRecords` rename fires *before* the id freezes," extract that sequence
  into an injectable unit taking `(fingerprintProvider, coordinator, persist)`.
  Without it the test degrades to the existing coordinator-rename test, which does
  not prove the freeze ordering.
- **Re-selection evidence:** `setSelectedFolder` is `private` and round-trips a
  real bookmark on a real URL, so the same-vs-new decision isn't unit-testable as
  shaped. Introduce a stubbable same-folder-evidence input (a closure/protocol
  taking the stored-bookmark resolution), so the "same folder keeps id / different
  refreshes" test can run without filesystem access.

The end-to-end #127 regression is a **hand-wired integration test** (manager →
adapter → lifecycle coordinator → AutoSync manager + safety monitor), not a true
end-to-end — `PhotoExportApp` isn't constructible in a test. Scope it to "after
drift, the record-store / dirty-state / safety keys all resolve to S"; the
literal "zero duplicate files" leg is covered transitively by record-store-state
being unchanged (use a stub exporter rather than a real export).

### Migration

"Seed = current fingerprint id" adopts the existing on-disk directories **only
when that fingerprint id still matches the id the dirs were last written under**:

- **High-confidence drives:** id derivation is unchanged, so the seed matches and
  adoption is a pure label — no files move.
- **Low-confidence upgraders (the #127 population):** the record dir may be named
  under a pre-V2 id (`preV2LowConfidenceId`) that
  `ExportRecordsDirectoryCoordinator` renames to the current fingerprint id
  lazily, in `configureRecordStores`, **before** either store configures. Two
  consequences the plan must honor:
  1. The record dir survives only because the coordinator rename still fires — so
     "the coordinator becomes harmless/never invoked again" is wrong on the very
     first post-upgrade launch. Seed *from the same fingerprint id the coordinator
     targets*, and let the rename run before the id freezes.
  2. The coordinator migrates **only `ExportRecords`** — there is no equivalent for
     `AutoSync/destinations/<id>/` (dirty/token/retry/summary/journal) or
     `safetyRecord.json`. Those dirs are whatever id the running build last wrote;
     if the id drifted before this upgrade, that state is already orphaned and the
     seed cannot recover it.
- **Decision (chosen): option (b).** Scope the lossless claim to record-store
  data; accept that already-drifted AutoSync/safety state may reset once on
  upgrade. Rationale: dirty state recomputes from a photos-changed pass and a
  safety re-confirmation is a single prompt — neither duplicates files, which is
  the only thing #127 actually punishes. Option (a) means writing migration code
  for `AutoSync/destinations/<id>/` + `safetyRecord.json`, which have no
  coordinator today — net-new migration surface for a one-time cosmetic reset, not
  worth it. (No AutoSync/safety adoption test is writable under (b); there is
  nothing to migrate.)
- **Residual record-store tail:** even for record data, "never duplicates" is not
  absolute. A low-confidence user whose path-derived id **already drifted before
  this upgrade** has a record dir under an id the coordinator can't find (it only
  knows the bookmark-hash and `preV2LowConfidenceId` forms), so the seed computes a
  fresh id → empty dir. This is not a regression and not a silent re-export: it is
  exactly the orphaned-progress state the **#131 recovery already handles**
  (`DestinationRecordRecoveryView` / `DestinationSafetyMonitor` — empty records +
  files present → offer rebuild from disk). State the claim as "no *new*
  duplicates; pre-existing drift surfaces the existing recovery prompt," not
  "lossless."

### What this deliberately does *not* touch

- No change to `ExportRecordStore` / `CollectionExportRecordStore` on-disk layout
  or `configure(for:)` signature — they still take a single id, now stable.
- `ExportRecordsDirectoryCoordinator` and the legacy-id plumbing stay (load-bearing
  for the low-confidence rename above and for the two-store create race).
- No `BackupScanner` involvement, so the collection-rebuild gap (the scanner only
  walks timeline `YYYY/MM` and never reconstructs `Collections/…` records) cannot
  bite, because nothing is cleared and rebuilt.

## Testing (Phase 0)

- Stable-id reuse across simulated remount drift (via the fingerprint seam) —
  asserts the id, the emitted snapshot, AutoSync key, and safety confirmation all
  hold. *(Requires the snapshot `stableId` field.)*
- Explicit re-selection of the **same** folder keeps the id (the re-selection
  trap); a genuinely different destination refreshes it.
- Upgrade seeding: high-confidence absent-id seeds to the current fingerprint id;
  low-confidence absent-id with a pre-V2 record dir still triggers the coordinator
  rename **before** freeze; unmounted-at-seed defers and persists nothing.
- AutoSync remount reducer test: feed `(stableId: S, fingerprint: drifted)`,
  assert `next.destination.id == S` and `dirtyStateByDestination[S]` preserved.
  *(Not writable until `DestinationSnapshot` carries `stableId`.)*
- Safety: confirmation persists across remount (no re-prompt) — only meaningful
  once the safety store is re-keyed to the stable id.
- `testPerDestinationIsolation` stays as a store-level multi-slot test; it does not
  cover identity derivation. Add the above as the identity-stability tests; the two
  concerns are now separate.

## Goals

- A remount or re-bookmark of the **same** destination never re-exports and never
  orphans AutoSync / journal / safety state.
- Selecting a genuinely **different** destination gets a fresh identity.
- Existing high-confidence users upgrade with zero data movement; low-confidence
  users upgrade with at most a one-time AutoSync/safety recompute (option b).
  No *new* duplicates; any pre-existing drift surfaces the #131 recovery prompt
  rather than re-exporting.
- `DestinationFingerprint` is reduced to its honest job: identity confidence.

## Non-Goals

- Fixed slot / records-in-folder redesign (see [deferred](#deferred-optional-persistence-model-simplification)).
- Scan-on-switch (not needed once the id is stable).
- Retiring `ExportRecordsDirectoryCoordinator`.
- Any user-facing multi-destination manager.

## Risks & Mitigations (Phase 0)

- **Re-selecting the same remounted folder via the picker forks the id** → the
  re-selection trap above; key on bookmark identity, confirm when ambiguous.
- **Non-atomic identity emission** → publish stable id + fingerprint as one value;
  retire the two-`@Published` pair-write and the inverted mid-emission contract.
- **Low-confidence upgrade ordering** → seed from the coordinator's target id and
  let the `ExportRecords` rename run before freeze. AutoSync/safety adoption is
  option (b): one-time recompute, no migration.
- **Switching destinations without an explicit reset** could adopt the wrong id →
  resolved by the explicit-selection-refreshes rule plus the ambiguity
  confirmation.
- **A keying read or dedup filter left on `fingerprint.id`** → the six-site
  re-point list plus the build-phase lint guard.

## Deferred (optional) persistence-model simplification

The "single fixed records slot" and "records in a hidden dotfile inside the
destination folder" ideas remain attractive but are **not required for #127** once
Phase 0 lands, and carry unsolved preconditions:

1. **Collection rebuild.** `BackupScanner` only scans timeline `YYYY/MM[/videos]`;
   both stores' `reconcileAgainstFilesystem` only *prune*. Any clear-then-rebuild
   must first add a scan/import path that reconstructs `Collections/…` placements
   and records, or it will duplicate collection exports.
2. **Transactional switch.** Clear-then-reconcile is unsafe (`resetToEmpty()` only
   acts on `.failed`; a mid-switch scan failure leaves an empty slot + a full
   folder). Scan into a staging slot, swap atomically on success.
3. **One identity policy.** Reuse the Phase 0 stable id as the single source for
   all internal destination state.

If pursued, the dotfile variant is most robust but trades in network-share write
reliability, sync tools stripping/duplicating dotfiles, and cross-device
contention. Decide dotfile-vs-slot only when scheduled.

## Documentation impact (mandatory in the same PR)

`docs/reference/persistence-store.md` (the persistence contract),
`docs/reference/architecture-conventions.md` (identity/lifecycle contract +
the retired pair-write rule), `AGENTS.md` (currently describes per-destination
records keyed by the fingerprint), the website architecture page, and the
affected code docstrings (`ExportDestinationManager` identity contract,
`DestinationIdentitySnapshot`'s init ban).

## Open questions

1. Whether to ever schedule the deferred slot/dotfile redesign, given Phase 0
   already delivers the "fingerprint is advisory" end-state without moving data.

Resolved during planning: re-selection keys on **bookmark equivalence**, not path
(confirmation only for the genuinely ambiguous unresolvable-bookmark case);
already-drifted state uses **option (b)** — record data is not migrated for
AutoSync/safety, which recompute once, and a pre-existing orphaned record dir
surfaces the #131 recovery.
