# Observability Improvement Plan

Goal: when the app dies in a way that doesn't produce a CrashReporter artifact (OS jetsam, watchdog termination, sandbox kill), the existing **Help → Save Diagnostic Report** menu item should produce a `.txt` that tells a maintainer exactly what the app was doing, how much memory it was using, and whether the main thread was hung. Today the report tells us record counts and the last iCloud catch-up summary — it says nothing about what was *running* when the app went away.

This plan is scoped to a class of bug surfaced by issue #112: a long-running background operation (auto-export over a large library) ends in silent termination with no in-app error, no crash dialog, and no `~/Library/Logs/DiagnosticReports/photo-export-*` artifact. The user's only forensic surface is the diagnostic report, and right now that report is post-mortem record counts.

Out of scope (deliberately): real-time crash reporting, a telemetry backend, anything that needs a new entitlement, anything that costs measurable battery or CPU when nothing is wrong. Every task below works under the four existing entitlements (`app-sandbox`, `files.bookmarks.app-scope`, `files.user-selected.read-write`, `personal-information.photos-library`).

---

## Design Principles

1. **The diagnostic report stays the single forensic surface.** Users already know how to trigger it. New artifacts feed *into* the report rather than living elsewhere. The reporting workflow stays "click Save Diagnostic Report, attach the .txt to a GitHub issue."
2. **Crash-survivable means continuously flushed to disk.** In-memory state is gone when the OS sends SIGKILL. Anything we want to read on next launch has to land on disk before the work happens, not after.
3. **Zero cost when healthy.** Steady-state writes are bounded (e.g. one append per real event, one watermark write per 100 MB step change). Idle app does no extra IO.
4. **No PII in artifacts.** Breadcrumb messages carry category + intent + counts. Never asset filenames, never user-chosen paths, never album names. The diagnostic is something a user pastes into a public issue.
5. **Each task is independent.** Land in any order. A partial rollout still improves the report.

---

## Tier 1 — High ROI, Zero Risk

### Task 1.1 — Auto-export run journal

**What:** A small "is a run in flight, and which phase?" file written before any heavy work and deleted after the run's summary is committed. If the file exists on next launch, the previous run was killed mid-flight; the journal says exactly where.

**Where:**

- New file: `photo-export/AutoSync/Stores/FileBackedAutoSyncCurrentRunStore.swift`. Mirrors the shape of `FileBackedAutoSyncRunSummaryStore.swift` but persists a different value type and is destination-keyed the same way.
- New model: `photo-export/Models/AutoSyncRunJournal.swift`. Codable struct: `startedAt: Date`, `trigger: String`, `scopeKind: String`, `phase: Phase` (enum: `planning`, `enqueueing`, `exporting`, `finalizing`).
- Call sites: `photo-export/AutoSync/AutoSyncManager.swift` `startRun` (write `planning`, then transition to `enqueueing` once `runExport` is awaited) and `photo-export/Export/ExportManager.swift` `finalizeActiveRun` (delete the journal file as the very last act of the run, after `lastRunSummary` is persisted).

**On-disk layout:**

```
~/Library/Application Support/com.valtteriluoma.photo-export/
  AutoSync/destinations/<destinationId>/currentRun.json
```

Sibling to `lastRunSummary.json`. Atomic write (`.tmp` + rename, same pattern `JSONLRecordFile.writeSnapshotAndTruncate` uses) so a partial write cannot leave a corrupt journal.

**Reporting integration:** `DiagnosticReporter.makeReport()` gains a `== Auto-Export Run Journal ==` section that prints "(none — no run in flight)" when the file is absent, or the journal contents plus age-since-startedAt when present.

**Definition of done:**

- New `AutoSyncCurrentRunStoreTests` covering: write → read round trip, atomic write semantics, deletion on clean finish, journal survives simulated SIGKILL (delete the process state between save and read).
- `DiagnosticReporterTests` covers both the empty and the populated section.
- An end-to-end test that drives `AutoSyncManager.startRun` through a fake exportRunner, verifies the journal advances `planning` → `enqueueing` → (deleted), and that an abrupt teardown leaves the journal at its last-recorded phase.

**Cost:** ~80 LOC across two new files plus four call-site edits. ~200-byte file write at each phase transition (≤6 per run). No state when healthy because the file is deleted after clean finish.

**Risk:** None. The journal is metadata for diagnostics; nothing reads it to make a decision about export behavior.

---

### Task 1.2 — Breadcrumb ring buffer flushed to disk

**What:** A bounded, append-mostly log of high-level events ("auto-export started", "scanning year 2017", "queue drained", "destination changed") with timestamps. ~512 entries kept in memory, every entry appended to disk synchronously so the tail survives an OS kill.

**Where:**

- New file: `photo-export/App/BreadcrumbStore.swift`. `@MainActor final class` (matches the isolation policy of every other store in `App/`).
- New file: `photo-export/App/BreadcrumbCategory.swift`. Small enum of categories that map 1:1 to the existing `os.Logger` categories already used in the codebase (Export, AutoSync, PhotoLibrary, Lifecycle, etc.).
- Wired from `photo_exportApp.swift` as a `@StateObject` constructed at app init, same shape as `WhatsNewState`.

**API shape:**

```swift
func record(category: BreadcrumbCategory, message: String, fields: [String: String] = [:])
```

Each call:
- Appends to the in-memory ring buffer (drops the oldest entry when at capacity).
- Encodes the entry as a single JSON line and appends to `~/Library/Application Support/com.valtteriluoma.photo-export/breadcrumbs.log` followed by `\n`.
- Triggers a file rotation when the on-disk file exceeds ~1 MB (rename to `breadcrumbs.log.1`, start fresh).

**Adoption — where to wire `record(...)`:** Not every `os.Logger` call should become a breadcrumb. Adopt at coarse-grained, user-visible-event sites only:

- `AutoSyncManager.startRun` start/end and `cancelActiveFanOut`
- `ExportManager.startExport*` entry points (one breadcrumb per call, no per-asset spam)
- `ExportManager.runBulkExportTask` start, completion-with-totals, and catch
- `PhotoLibraryPersistentChangeAdapter.fetchAndEmit` dispatch + `applyCatchUpResult`
- `AppLifecycleCoordinator.apply(destination:)` for destination changes
- `ExportRecordStore.configure(for:)` and `CollectionExportRecordStore.configure(for:)` for store transitions
- `RecordStoreState.failed` transitions (corruption surfaces)

**Privacy:** breadcrumb `message` strings are author-controlled (we choose them at the call site). Categorical labels and counts only — never `filename`, never `asset.localIdentifier`, never `placement.displayName`, never user-chosen paths. A 1-line code-review checklist enforces this; PII review is part of the DoD for each adoption site.

**Reporting integration:** `DiagnosticReporter.makeReport()` gains a `== Recent Breadcrumbs (last 200) ==` section pulling from the on-disk file. Tail-only (not the in-memory buffer) so a freshly-launched diagnostic after a crash still shows the dead session's breadcrumbs.

**Definition of done:**

- New `BreadcrumbStoreTests` covering: ring buffer eviction, file rotation at 1 MB, append survives across instance reload, malformed-line skip on read (same forgiving pattern `JSONLRecordFile.load` uses).
- A PII check test: a fixed table of forbidden substrings (sample asset IDs, sample album titles) asserted absent from any string passed to `record(...)` at the wired call sites. Test fails if a future contributor passes user data.
- Diagnostic report integration test: with 1000 breadcrumbs on disk, report includes exactly the last 200 in correct order.

**Cost:** ~120 LOC for the store + per-site adoption is a 1-2 line addition next to an existing `logger.info(...)` call.

**Risk:** Minimal. One disk write per real event, bounded file size, no impact on hot paths (no breadcrumbs from per-asset writes or per-thumbnail loads).

---

### Task 1.3 — Diagnostic report integration

**What:** Extend `DiagnosticReporter` to embed the artifacts produced by Tasks 1.1 and 1.2. This is the slice that turns the user's existing one-click report into the smoking gun.

**Where:**

- `photo-export/App/DiagnosticReporter.swift` — two new sections in `makeReport()`:
  1. `== Auto-Export Run Journal ==` (consumes `FileBackedAutoSyncCurrentRunStore`)
  2. `== Recent Breadcrumbs (last 200) ==` (reads `breadcrumbs.log` tail)
- `photo-export/App/photo_exportApp.swift` `SaveDiagnosticReportCommand` — pass the new stores to `DiagnosticReporter.init`, same shape it already passes `lastCatchUpSummary`.

**Order in the report:** the new sections go **above** the existing record-store summaries (after the header and the catch-up section) so the maintainer reading top-to-bottom sees "previous run was killed at phase=X" before scrolling past 80,000 record counts.

**Definition of done:**

- `DiagnosticReporterTests` cover: both sections present when artifacts exist, both gracefully say "(none)" when artifacts are absent, no crash when the breadcrumb file is missing/empty/malformed.
- Manual verification: capture a diagnostic during a real auto-export run, confirm the new sections render legibly.

**Cost:** ~30 LOC plus tests. Zero runtime cost — `makeReport()` is only called when the user clicks Save.

**Risk:** Zero. Read-only extension to an existing reporter.

---

## Tier 2 — Cause Disambiguation

These are smaller standalone signals that, combined with Tier 1, let a maintainer distinguish "OS killed it for memory" from "OS killed it for unresponsiveness" without asking the user to run Console.app.

### Task 2.1 — Memory watermark sampler

**What:** A 5-second timer that reads `mach_task_basic_info().resident_size` and records a breadcrumb only when the value crosses a new 100 MB watermark (round-up). Idle apps emit nothing; an app sliding toward jetsam emits a clear staircase.

**Where:**

- New file: `photo-export/App/MemoryWatermarkSampler.swift`. `@MainActor final class`. Uses `task_info` (sandbox-allowed, no entitlement change).
- Wired in `photo_exportApp.swift` `.task` block alongside the existing `lifecycleCoordinator.attach(...)` etc.

**Mechanics:** `DispatchSourceTimer` on a utility queue fires every 5 s. Each tick: read RSS, compare to last-recorded watermark (rounded to the nearest 100 MB *up*), if higher, write a breadcrumb `("Memory", "watermark", ["rss_mb": "1200"])`. Watermark only goes up within a session (so we capture the peak); resets on next launch.

**Definition of done:**

- `MemoryWatermarkSamplerTests` with an injected clock + task-info closure: a sequence of fake RSS readings produces exactly the expected sequence of breadcrumbs at exactly the expected timestamps.
- Documented sandbox safety: `task_info(mach_task_self_, …)` is permitted; no entitlement gate.

**Cost:** ~40 LOC. One syscall per 5 s. Breadcrumb only on threshold crossing — typically a handful per real auto-export run.

**Risk:** Zero. Read-only system call, sandbox-safe, no behavior change.

---

### Task 2.2 — Main-thread heartbeat / stall detector

**What:** A 1 Hz `Timer` on `MainActor`. On each tick, record the timestamp. If the gap since the previous tick exceeds 2 s, record a breadcrumb naming the stall duration. Healthy app records nothing.

**Where:**

- New file: `photo-export/App/MainThreadStallDetector.swift`. `@MainActor final class`.
- Wired in `photo_exportApp.swift` `.task` block.

**Why this complements 2.1:** memory watermarks alone can't distinguish "long stall + memory growth" (typical of issue #112) from "memory growth at idle" (would be a leak, different bug). The heartbeat says "main was blocked for N seconds at T" right before the stack of memory watermarks; the maintainer reads both and knows whether main-thread blocking was happening at the time.

**Definition of done:**

- `MainThreadStallDetectorTests` with an injected clock: a fake "main-thread block" (simulated gap between ticks) produces exactly one breadcrumb naming the gap, no breadcrumb when ticks are healthy.

**Cost:** ~25 LOC. One timer tick per second. Breadcrumb only on stall.

**Risk:** Zero.

---

### Task 2.3 — "Last alive" heartbeat dotfile

**What:** Write `Date.now` to `lastAlive.txt` every 10 s. On next launch, read the file; if `(processStart - lastAlive)` is greater than a few seconds, the previous session terminated abnormally. Record a breadcrumb on this detection and include it in the diagnostic report's header.

**Where:**

- Extend `MainThreadStallDetector` (reuse its 1 Hz timer; every tenth tick also writes the dotfile) rather than introduce a third timer. Same wiring point.
- Path: `~/Library/Application Support/com.valtteriluoma.photo-export/lastAlive.txt`.

**Reporting integration:** at the top of `makeReport()`, after the header, add a line:

```
Previous session: ended cleanly  (or)
Previous session: terminated abnormally at ~<timestamp> (~<duration> after lastAlive)
```

This is the single most user-readable signal: a one-line statement in the saved file that says "yes, the previous launch died abnormally."

**Definition of done:**

- `LastAliveTests` covering: file written/read correctly, abnormal-exit detection with various gap sizes, clean-exit detection when a hook writes "clean" before quit (via `NSApplicationWillTerminate` notification, plumbed at the same wiring site).
- Diagnostic report renders both cases legibly.

**Cost:** ~20 LOC reusing the existing timer.

**Risk:** Zero. One ~30-byte atomic write per 10 s.

---

## Tier 3 — Opportunistic, Optional

### Task 3.1 — `os_signpost` intervals around auto-export phases

**What:** Extend the existing `OSSignposter` pattern already in `PhotoLibraryPersistentChangeAdapter.swift` (~L354) to wrap auto-export phases: `planAutoExport`, `enqueueAutoExport`, per-album fetch, `drainQueue`. A user willing to capture Instruments traces or `log stream` output gets Instruments-grade detail; a normal reporter sees nothing change.

**Why Tier 3, not Tier 1:** signposts are only useful to a reporter who runs `log stream --predicate '...'` or Instruments. The diagnostic report **cannot embed unified-log output**: shelling out to `log show` would require `Process.start`, which is blocked by `app-sandbox` without a `temporary-exception.unix-process` entitlement we don't have and shouldn't add. So this slice is a power-user aid, not part of the one-click forensic loop.

**Reporting integration:** the diagnostic header gains a one-line recipe:

```
For finer-grained timing data, run this in Terminal and re-attach the output:
  log show --predicate 'subsystem == "com.valtteriluoma.photo-export"' --last 1h --info
```

That recipe makes the signposts discoverable without us needing to ship a log-extraction tool.

**Cost:** ~15 LOC plus a printed recipe line.

**Risk:** Zero. Signposts are near-free when not being recorded.

---

## End-User Reporting Workflow (Target State)

After Tier 1 ships, the user flow becomes:

1. User experiences a problem (silent shutdown, hang, slow export, anything).
2. User re-opens Photo Export. They don't need to install Console.app, run Terminal commands, or change settings.
3. User clicks **Help → Save Diagnostic Report** (existing menu item, unchanged location).
4. User attaches the saved `.txt` to a GitHub issue.

The maintainer opens the `.txt` and reads top-to-bottom:

```
photo-export diagnostic report
Generated: 2026-05-23T13:10:51.999Z
App version: 1.6.0 (129)
Destination ID: <hash>
Previous session: terminated abnormally at ~2026-05-23T12:47:12Z (~3min after lastAlive)

== Last iCloud Library Catch-Up ==
[unchanged from today]

== Auto-Export Run Journal ==
startedAt: 2026-05-23T12:44:08Z
trigger:   appLaunch
scopeKind: allAlbumsFull
phase:     enqueueing
[file present on launch → previous run was killed mid-flight at this phase]

== Recent Breadcrumbs (last 200) ==
2026-05-23T12:44:08Z [AutoSync] startRun trigger=appLaunch scope=allAlbumsFull
2026-05-23T12:44:09Z [Memory] watermark rss_mb=600
2026-05-23T12:44:18Z [Export] runBulkExportTask logTag=startExportAllAlbums
2026-05-23T12:44:31Z [Memory] watermark rss_mb=900
2026-05-23T12:45:02Z [Memory] watermark rss_mb=1200
2026-05-23T12:46:14Z [Memory] watermark rss_mb=1800
2026-05-23T12:46:48Z [MainThread] stall duration_ms=4200
2026-05-23T12:47:11Z [Memory] watermark rss_mb=2400
[silence — process killed at ~2026-05-23T12:47:12Z]

== Summary ==
[unchanged from today]
```

Reading the above the maintainer knows in 30 seconds: previous session died mid-album-enqueue, RSS was climbing past 2.4 GB at time of death, main thread had a 4.2 s stall just before — diagnosis is jetsam under memory pressure during the synchronous album fan-out, no further user-action needed.

A version of issue #112 with this report attached would be a triage-in-seconds, not a multi-day investigation.

---

## Privacy and Trust

The diagnostic report is something a user pastes into a public GitHub issue. Every field added by this plan must pass the "would you be comfortable seeing this on a stranger's screen?" test.

What is **safe** to include:
- Category labels (`AutoSync`, `Export`, `Memory`, `MainThread`).
- Counts (asset counts, watermark values in MB, stall durations in ms).
- Enum cases (`phase=enqueueing`, `trigger=appLaunch`, `scopeKind=allAlbumsFull`).
- Hashed destination IDs (already in the report today).

What is **forbidden** in breadcrumb messages, journal fields, and report sections:
- Filenames (asset, album, file paths).
- Album titles or folder names.
- Asset `localIdentifier`s (these are stable per-Photos-library identifiers).
- Any path component the user chose.

The PII regression test in Task 1.2 codifies this list. New breadcrumb adoption sites must add their forbidden-substring fixtures to that test as part of the PR review.

---

## Rollout

Land in tier order. Each tier is independently shippable.

- **Tier 1 (Tasks 1.1 → 1.2 → 1.3)** is the load-bearing slice. After 1.3, the diagnostic answers most "what happened?" questions on its own. **Land this before any further work on issue #112's underlying bug** — that way the next reproduction supplies the missing evidence directly.
- **Tier 2** lands after 1.3. Each task is independent; order doesn't matter.
- **Tier 3** lands opportunistically; not blocking on anything.

Each task ships as its own PR with its own test surface. None of them block on the others; if a contributor only has bandwidth for Task 1.1, that alone is a meaningful improvement.

---

## Non-Goals

For clarity about what this plan explicitly does **not** do:

- **Distinguishing exact OS termination signal.** Jetsam, watchdog, SIGKILL from anywhere — we don't get to see the signal. We infer from breadcrumb tail + memory watermark + main-thread stall. That's enough in practice.
- **In-app crash dialog.** Nothing here surfaces "you crashed last time" as a modal. The diagnostic carries the signal; a banner UI is over-engineering.
- **Live telemetry.** No backend, no opt-in pings, no "phone home." Single-user app, user-driven reports.
- **Replacing `os.Logger`.** The unified log stays the deep-dive channel for power users. Breadcrumbs are the coarse-grained, crash-survivable summary.
- **Per-asset breadcrumb spam.** Breadcrumbs are for run-level and phase-level events. Per-asset logging stays in `os.Logger`. The PII review will flag any breadcrumb that fires per-asset.
