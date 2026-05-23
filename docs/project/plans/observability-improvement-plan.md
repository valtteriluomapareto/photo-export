# Observability Improvement Plan

Goal: when the app dies in a way that doesn't produce a CrashReporter artifact (OS jetsam, watchdog termination, sandbox kill), the existing **Help → Save Diagnostic Report** menu item should tell a maintainer *whether the previous session died mid-export* and *which AutoSync scope was in flight when it did*. Today the saved report carries post-mortem record counts and the last iCloud catch-up summary — it says nothing about what was *running* when the app went away.

Scope: a single new collaborator (a small per-destination "run journal" file), one small `DiagnosticReporter` extension to render it, plus tests and a website-docs touch-up. AutoSync-driven runs only — manual exports are out of scope. No new entitlements, no telemetry backend, no in-app UI.

This is the minimum useful slice surfaced by reviews of an earlier multi-tier draft. A future bug we *can't* crack with the journal will justify the next layer (memory watermarks, main-thread stall detection, structured event breadcrumbs). For now, the journal alone is sufficient for the class of bug in issue #112 and ships as one PR.

---

## Design Principles

1. **The diagnostic report stays the single forensic surface.** Users already know how to trigger it; the new artifact feeds *into* the report rather than living elsewhere. Workflow remains "click Save Diagnostic Report, attach the .txt to a GitHub issue."
2. **Crash-survivable means written to disk before the work, not after.** In-memory state is gone when the OS sends SIGKILL. The journal lands on disk before any per-scope work begins.
3. **Zero PII risk by construction.** The journal's fields are categorical: scope kind, trigger reason, ISO timestamps. No filenames, no album titles, no asset identifiers, no user-chosen paths. The substring-fixture / lint-rule discipline an earlier draft proposed is unnecessary because the type signature itself cannot carry user data.
4. **No state when healthy.** The journal file is deleted on clean fan-out completion. A user running normally has nothing on disk except a `lastRunSummary.json` exactly as today.
5. **Boring is the goal.** Mirror `FileBackedAutoSyncRunSummaryStore` shape, reuse `JSONLRecordFile`'s fsync discipline, no new architectural patterns.

---

## Task 1 — AutoSync run journal

### What

A small per-destination file written when a fan-out task starts, updated when each per-scope sub-run begins, and deleted when the fan-out completes cleanly. If the file exists on the next launch's diagnostic, the previous fan-out was killed mid-flight and the file says which scope was current.

### Where

- **New file:** `photo-export/AutoSync/Stores/FileBackedAutoSyncCurrentRunStore.swift`. `@MainActor final class`. Mirrors the shape of `FileBackedAutoSyncRunSummaryStore.swift` (init takes `baseDirectoryURL`; per-destination subdirectory; load / save / clear methods).
- **New model:** `photo-export/Models/AutoSyncRunJournal.swift`. Codable value type:
  ```
  struct AutoSyncRunJournal: Codable, Sendable, Equatable {
      let startedAt: Date
      let trigger: String       // raw value of AutoSyncReason
      let scopes: [String]      // raw values of AutoExportLibraryScope (the fan-out plan)
      var currentScope: String? // raw value of the currently-in-flight scope, nil before the first sub-run starts
      var currentScopeStartedAt: Date?
  }
  ```
- **Call sites:** the existing fan-out loop in `AutoSyncManager.startRun(spec:)` (`AutoSyncManager.swift:477–519`). Two writes per fan-out plus one delete:
  1. Right after `activeRunFanOutTask = Task { … }` enters its loop, before the first `await`, write `AutoSyncRunJournal(startedAt: now, trigger: spec.reason.rawValue, scopes: runScopes.map(\.rawValue), currentScope: nil, currentScopeStartedAt: nil)`.
  2. At the top of each `for runScope in runScopes` iteration (before `await runExport(context:)`), update `currentScope` and `currentScopeStartedAt`.
  3. After the `for` loop completes (clean path) **and** in the cancellation/break path on a non-`.completed` summary, delete the file.

### On-disk layout

```
~/Library/Application Support/com.valtteriluoma.photo-export/
  AutoSync/destinations/<destinationId>/currentRun.json
```

Sibling to the existing `lastRunSummary.json`. Atomic via `.tmp` + rename + **parent-directory fsync** — the latter matters specifically because the journal exists to survive SIGKILL, and `Data.write(to:options:.atomic)` fsyncs the file but not the parent dir. Either delegate to `JSONLRecordFile.writeSnapshotAndTruncate`'s helpers (`Records/JSONLRecordFile.swift:357–382`, which already implement this correctly) or duplicate the small `fsync(open(parentDir, O_RDONLY))` shape and document why. The plan recommends the former: extract the parent-dir-fsync helper as a small `static` on `JSONLRecordFile` and reuse it here.

### Write discipline

Each journal mutation is one atomic write (≤300 bytes). These writes happen at fan-out boundaries — at most once per few minutes during a real run, **not** per asset, per album, or per fetch. Cost on main is one write per sub-scope transition; even on a slow disk this is sub-10ms and fires ≤5 times in a worst-case fan-out across all four AutoExport scopes.

Synchronous on the main actor is fine at this rate. Hopping to a serial io queue (as `JSONLRecordFile` does for per-record append) is over-engineered for ≤5 writes per run; the bookkeeping required to flush the io queue before the fan-out task exits would cost more than the writes themselves.

### Why this scope, not finer

An earlier draft proposed a four-phase enum (`planning → enqueueing → exporting → finalizing`). That granularity does not live at the `AutoSyncManager.startRun` layer — the phases are internal to `ExportManager.runExport(context:)` and its dispatched `startExport*` paths. Honestly writing a four-phase journal would require threading the journal into `ExportManager`, which would also force handling fire-and-forget manual exports (which `runExport` doesn't gate — see `ExportManager.swift:1663`'s `activeRunBookkeeping` guard).

Fan-out-granularity is the *honest* level for this slice: it says "AutoSync was in the middle of running `allAlbumsFull`" and stops there. For issue #112 that is sufficient — the failure happens *inside* an AutoSync sub-run, and naming which sub-run already points the maintainer at the right code path.

A future bug that requires within-`runExport` phase tracking can move the journal writes into `ExportManager` then. Until then, the fan-out level is the right tradeoff.

### Manual exports — explicitly out of scope

Manual `startExport*` paths don't go through `AutoSyncManager.startRun` and don't write to this journal. A manually-initiated export that crashes leaves no journal artifact. That's acceptable: manual runs are user-initiated and short, and the user can re-trigger immediately; AutoSync runs are background and large, and that's where the silent-shutdown class of bug lives.

### Reporting integration

`DiagnosticReporter` (`photo-export/App/DiagnosticReporter.swift`) gains one new section, emitted near the top of the report (after the header line, before `== Last iCloud Library Catch-Up ==`) so a maintainer reading top-to-bottom sees the abnormal-exit signal before scrolling past 80,000 record counts:

```
== Previous Auto-Export Run ==
(absent → omit the section entirely, no "(none)" placeholder)

(present → render as:)
Started:        2026-05-23T12:44:08Z
Trigger:        appLaunch
Planned scopes: timelineFullLibrary, favoritesFull, allAlbumsFull, allSharedAlbumsFull
Current scope:  allAlbumsFull (since 2026-05-23T12:45:11Z)
Status:         in-flight on launch (previous session did not finish cleanly)
```

The section is omitted entirely when the file is absent. This keeps existing diagnostic reports byte-identical for users not hitting the bug — there's no "(none recorded)" placeholder that bloats every healthy report.

`DiagnosticReporter.init` gains one new dependency: the load result of `FileBackedAutoSyncCurrentRunStore.load(destinationId:)` for the active destination. The `SaveDiagnosticReportCommand` wiring (`photo-export/App/photo_exportApp.swift:521–586`) reads the store once at panel-open time and passes the optional `AutoSyncRunJournal` into `DiagnosticReporter.init`.

### Definition of done

- New `FileBackedAutoSyncCurrentRunStoreTests` covering:
  - Write → read round trip preserves all fields.
  - `clear(destinationId:)` removes the file.
  - Atomic-write semantics: a simulated power-loss between `.tmp` write and rename leaves either the previous file intact or no file, never a partial one.
  - Parent-dir fsync helper is invoked (assertable by injecting a `FileSystem` seam, or by structural test).
- New `AutoSyncManagerJournalTests` (or extension of existing tests) covering the three call-site behaviors:
  - Fan-out start writes the journal with `currentScope == nil`.
  - Each sub-scope iteration updates `currentScope` before the await.
  - Clean fan-out completion deletes the file.
  - Cancelled / failed fan-out also deletes the file.
- `DiagnosticReporterTests` covers both the "section present" and "section absent" cases; the absent case asserts byte-equal output to today's report.
- Integration test: drive a fake `exportRunner` through `AutoSyncManager.startRun`, snapshot the file at each phase, kill the fan-out task mid-second-scope (don't await its cancellation), reload from disk, verify the journal reflects `currentScope` at the kill point. This is the "smoking gun" test.

### Cost and risk

- ~130 LOC total across the two new files plus the `DiagnosticReporter` extension and `SaveDiagnosticReportCommand` wiring update. Single PR.
- One ~300-byte atomic file write at AutoSync fan-out boundaries (≤5 per run, fires once per few minutes typical). Negligible IO and zero CPU when healthy.
- Risk: minimal. Journal is purely diagnostic metadata; no code path reads it to make a decision about export behavior. A bug that corrupts the journal cannot affect export correctness.

---

## Documentation Updates

Per `docs/README.md`'s "what to update when behavior changes" table, the diagnostic report's contents are user-visible — anyone who's saved a diagnostic before will see a new section appear. Three website pages mention what the diagnostic report contains:

- `website/src/content/docs/export-icloud-photos.md`
- `website/src/content/docs/getting-started.md`
- `website/src/content/docs/features.md`

Each gets a one-line addition (or a clarifying sentence on existing diagnostic-report copy) noting that the report now includes the previous-run journal when applicable. No README changes needed. No `AGENTS.md` change needed — this slice doesn't change architectural conventions.

---

## End-User Reporting Workflow

After this lands the user flow remains:

1. User experiences a problem (silent shutdown, hang, slow export).
2. User re-opens Photo Export. They don't need to install Console.app or run Terminal commands.
3. User clicks **Help → Save Diagnostic Report**.
4. User attaches the `.txt` to a GitHub issue.

The maintainer opens the `.txt` and reads top-to-bottom. For an issue-#112-class bug, the new `== Previous Auto-Export Run ==` section near the top says exactly which AutoSync scope was in flight when the previous session died. Combined with the existing record-count summary lower in the file, that's actionable triage without a second round-trip.

---

## What This Plan Does NOT Address

The journal alone cannot distinguish:

- **Memory-pressure kill vs main-thread watchdog kill.** Both produce the same "fan-out was in flight, didn't finish" signal. Distinguishing them needs a memory watermark sampler or main-thread stall detector — defer until a future bug actually needs the distinction.
- **Which specific album / asset was being processed within a sub-run.** The journal stops at "`currentScope = allAlbumsFull`." A bug that needs "which of the 282 albums" requires either richer journal granularity inside `ExportManager.runExport` or a separate breadcrumb log — defer.
- **Clean-exit vs unrelated session.** The presence of a journal file means "AutoSync was running"; absence means "AutoSync wasn't running" (or finished cleanly). It does not say "the app exited via Cmd-Q." If we ever need to disambiguate, a single `lastAlive.txt` updated on a heartbeat would do it — defer.

These limits are deliberate. The class of bug surfaced by issue #112 — silent shutdown during the AutoSync fan-out on a large library — is fully addressed by the fan-out-granularity signal. Wider observability is justified when a wider class of bug shows up.
