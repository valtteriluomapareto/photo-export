# Import Existing Backup Plan

## Summary

The current app can resume only when its local Application Support state survives. That fails for the real user problem:

- user already has a partially completed backup folder
- app is freshly installed on this Mac
- user wants to continue from that backup without creating duplicates

This plan adds a manual feature called **Import Existing Backup…**.

The design is intentionally small:

- solve existing backups first
- keep the feature non-destructive
- avoid new abstraction layers unless they are clearly necessary
- do not depend on iCloud-only identifiers

---

## Product Decision

### User-facing name

Use **Import Existing Backup…** in the UI.

Rationale:

- it is accurate on a fresh install
- it is still understandable on the same machine
- it does not imply the app has already scanned the folder before

`Rescan Backup Folder` is still a reasonable internal description, but `Import Existing Backup…` is the better user-facing label.

### Entry point

Add a manual toolbar/menu action:

- `Import Existing Backup…`

Do not add clever auto-detection for old backup folders in v1.

Exception:

- if the app finds its own sidecar folder (`.photo-export`) in the selected destination, it can offer a prompt because that signal is explicit and low-risk

---

## Scope

### Goals

- Let a fresh install continue from an existing backup folder.
- Rebuild local export state without modifying existing backup files.
- Prevent obvious duplicate re-exports after import.
- Make future imports faster and more reliable.

### Non-goals

- Renaming, moving, or deleting backup files.
- Perfect reconstruction for every historical backup.
- Auto-importing ambiguous matches.
- Building a generalized "portable asset identity" framework.

---

## Keep It Small

This feature should not double the number of manager/service types in the app.

Target implementation shape:

- `BackupSidecarStore`
  - reads/writes the backup-root sidecar
- `BackupScanner`
  - enumerates files and performs matching
- `ExportManager`
  - owns orchestration, progress, and cancellation

Do not add a separate coordinator, identity resolver, manifest store, and scan manager unless real implementation pressure proves they are needed.

---

## Core Technical Decisions

### 1. Solve existing backups first

The first shipped version must help users who already have a backup folder.

That means the first implementation phase is:

- manual import of a legacy backup folder
- conservative matching
- rebuild local export records

Future sidecar writing should be added in the same work, but it is not a prerequisite for the first user-visible win.

### 2. Do not use a large JSON manifest

Do not use a single rewritten `manifest.json`.

Reason:

- export happens per asset
- large libraries will grow the file quickly
- rewriting a large JSON blob on every export is the wrong shape for this app

Use the same persistence pattern the app already uses locally:

- append-only JSONL log
- periodic compacted snapshot
- atomic snapshot replacement

Recommended files under the backup root:

- `<backup-root>/.photo-export/backup-records.jsonl`
- `<backup-root>/.photo-export/backup-records.snapshot.json`

This is simpler than introducing SQLite in v1 and matches patterns already present in the codebase.

### 3. Do not depend on `PHCloudIdentifier` in v1

`PHCloudIdentifier` is not a safe foundation for this feature:

- it depends on iCloud Photos being available
- it adds async resolution complexity
- it does not help users whose libraries are local-only

v1 should work without it.

If it later proves useful as an optional hint, it can be added after the import flow is working.

### 4. Treat matching as a practical import problem

Do not build a new "portable identity" abstraction in v1.

Use the information we actually have:

- folder path
- filename
- asset creation date
- media type
- file timestamps
- image dimensions or video duration when needed for disambiguation

`localIdentifier` is still worth storing in the sidecar as a same-library hint, but it is not the cross-machine strategy.

---

## Sidecar Design

The sidecar is an implementation detail. Users do not need to know it exists.

### Minimal v1 record

Each sidecar record should contain only data we actually need:

- schema version
- `localIdentifier`
  - hint only; useful for same-library reinstalls
- original filename
- exported filename
- relative export path
- media type
- creation date
- export date
- optional file size

Do not store pixel dimensions, video duration, app version, or extra identity abstractions in v1.

If dimensions or duration are needed for matching, compute them during scan only for the specific ambiguous files being examined.

### Write policy

Write sidecar entries only for files exported by this app version going forward.

Do not automatically write sidecar entries from heuristic legacy matches in v1.

Reason:

- a wrong heuristic match should not become permanent "truth"

If we later want to persist imported legacy matches, that should be a separate follow-up with an explicit confidence and review story.

### Size management

The sidecar cannot grow forever without compaction.

Use the same basic strategy as `ExportRecordStore`:

- append mutations to JSONL
- compact periodically into a snapshot
- truncate the JSONL log after successful compaction

---

## Import Modes

## Mode A: Sidecar-backed import

Used when `.photo-export/` exists and contains readable sidecar files.

Flow:

1. Read snapshot if present
2. Replay JSONL mutations
3. Verify referenced files still exist on disk
4. Rebuild local `ExportRecordStore`
5. Report missing or stale sidecar entries

Matching order:

1. resolve by stored `localIdentifier` when it still exists
2. if that fails, fall back to metadata matching

This mode is faster and more reliable, but it is not required for v1 to be useful.

## Mode B: Legacy folder import

Used when there is no sidecar and the user manually invokes `Import Existing Backup…`.

Flow:

1. Enumerate the backup folder
2. Identify files in the app's expected `YYYY/MM/` layout
3. Build backup-side metadata candidates
4. Enumerate Photos assets
5. Match conservatively
6. Rebuild local `ExportRecordStore`
7. Show summary report

This mode directly solves the current user pain point.

---

## Matching Rules

The rules need to be explicit. If the app cannot match confidently, it must skip and report.

### Files eligible for legacy import

Only consider files that are inside:

- `<root>/<4-digit-year>/<2-digit-month>/`

and where month is `01` through `12`.

Ignore unrelated files elsewhere in the destination.

### Auto-match: two-stage logic

**Stage 1 — Filter candidates:**

For each backup file, build a candidate set of Photos assets where:

- year/month folder matches the asset creation date year/month
- media type matches
- filename matches exactly, or matches after removing the app's collision suffix pattern ` (N)` before the extension

**Stage 2 — Discriminate:**

From the candidate set, require at least one strong discriminator to pick a winner:

- file modification date matches asset creation date within 1 second (prefer modification date over creation date because it survives file copies more reliably)
- image dimensions match exactly
- video duration matches within 1 second

Auto-import only when exactly one candidate survives both stages.

### Known limitation: collision-suffixed files

Files like `IMG_0001 (2).jpg` exist because multiple assets shared the original filename `IMG_0001.jpg` in the same month. After stripping the suffix, multiple Photos assets will match the base filename, and the "exactly one candidate" rule will reject all of them.

This is intentional — guessing which collision variant maps to which asset is unreliable. In practice, backups with many collision-suffixed files will have lower match rates. This is an acceptable trade-off for v1: false negatives are safe, false positives are not.

### Ambiguous cases

Mark as ambiguous and do not auto-import when:

- more than one Photos asset fits equally well after both stages
- filename is the only matching signal (no strong discriminator available)
- creation date is missing from the Photos asset
- strong discriminators cannot be read from the file
- the file appears to have been renamed manually and no exact filename match exists

### Notes

- Use exact filename comparison first, then relaxed (suffix-stripped) comparison.
- Prefer false negatives over false positives.
- File size may be used as an extra discriminator when available, but it is not required for v1 matching.

---

## Local State Rebuild

Import rebuilds only local app state.

It should:

- repopulate `ExportRecordStore`
- restore month/year completion state
- allow future exports to skip imported assets

It should not:

- mutate existing backup files
- rewrite folder names
- backfill sidecar records for legacy heuristic matches

---

## Concurrency and Lifecycle Rules

The plan needs explicit rules here.

### Rescan vs export

Do not allow import while an export is actively running.

v1 rule:

- if export queue is not empty or an export is in progress, disable `Import Existing Backup…`
- or require the user to cancel/clear the export first

This is simpler and safer than trying to merge import and export concurrency in the first version.

### Sidecar access

All sidecar reads and writes must happen under security-scoped access to the selected destination.

Use the existing `ExportDestinationManager` access pattern.

### Serialization

Sidecar writes should use a dedicated serial queue, following the same basic pattern as `ExportRecordStore`.

---

## Corruption and Consistency Strategy

### Crash during write

Use:

- append-only JSONL for mutations
- atomic replace for snapshots

This keeps writes recoverable after interruption.

### Corrupt sidecar data

On import:

- if snapshot is corrupt, ignore it and continue from JSONL if possible
- if a JSONL line is corrupt, skip the line and report it
- if both are unusable, fail the sidecar import and offer legacy import instead

### Missing files

If the sidecar references files that no longer exist:

- do not import those entries as completed
- report them as stale sidecar entries

### Newer schema

If the sidecar major schema version is newer than the app understands:

- refuse sidecar import
- show a clear error message
- do not guess

### Read-only destination

Import should still work on a read-only destination if it only needs to scan.

If sidecar compaction or sidecar writing cannot happen:

- complete the import if possible
- warn that sidecar updates could not be written

---

## UX Flow

### Manual flow

1. User selects destination
2. User triggers `Import Existing Backup…`
3. App explains:
   - it will scan the selected backup folder
   - it will rebuild app state only
   - it will not delete or rename files
4. App runs the import with progress stages:
   - scanning backup folder
   - reading Photos library
   - matching assets
   - rebuilding local state
5. App shows a report

Phase 1 must show at minimum a progress view with the current stage label. Scanning a large backup folder and enumerating a large Photos library can take tens of seconds — without progress feedback, users will assume the app froze.

### Result report

Report (as implemented in Phase 1):

- imported matches (matched count)
- ambiguous files skipped (ambiguous count)
- files on disk with no matching Photos asset (unmatched count)
- total files scanned

Not yet implemented:

- "Photos assets still not backed up" count (requires cross-referencing all library assets against import results — deferred)
- stale sidecar entries (Phase 2)

Current UI offers `Close` and `Export Remaining` (calls `startExportAll()`).

---

## Phase Plan

## Phase 1: Manual legacy import MVP — DONE

Implemented. `BackupScanner` handles folder enumeration and conservative matching. `ImportView` provides the UI flow with progress stages and a result report. Import is blocked while export is active.

What shipped:

- `Import Existing Backup…` action in the UI
- scans `YYYY/MM/` backup folders
- conservative two-stage matching (filename + date/metadata discriminators)
- rebuilds local export records
- shows import summary with matched/skipped/unmatched counts
- blocks import while export is active

## Phase 2: Sidecar write/read for future reliability — NOT STARTED

Scope:

- write sidecar entries for new exports
- import from sidecar when available
- fall back to metadata matching when sidecar `localIdentifier` no longer resolves
- compact sidecar over time

Acceptance criteria:

- same-library reinstall imports quickly from sidecar
- sidecar-backed import is faster than full legacy scan

## Phase 3: UX polish

Scope:

- prompt only when explicit app-owned sidecar is detected
- improve progress UI
- better error messages for stale or corrupt sidecar data

Acceptance criteria:

- users with sidecar-backed backups are guided toward import
- users without sidecar still have the manual action available

---

## File Impact

Phase 1 (done):
- `photo-export/Managers/BackupScanner.swift` — folder enumeration and matching
- `photo-export/Managers/ImportCoordinator.swift` — import flow orchestration (extracted from ExportManager in Phase 5)
- `photo-export/Records/ExportRecordStore.swift` — import/rebuild API (moved to `Records/` in Phase 7)
- `photo-export/Views/Export/ImportView.swift` — import UI with progress and results (moved to `Views/Export/` in Phase 7)

Phase 2 (future):
- new: `photo-export/Managers/BackupSidecarStore.swift` — sidecar read/write
- `photo-export/Managers/ExportDestinationManager.swift` — sidecar root helpers under security scope

---

## Testing Plan

The tests need to be specific.

### Unit tests

- legacy match with exact filename/date/month/media type
- legacy match with app-added collision suffix ` (1)`
- ambiguous filename/date duplicates are skipped
- asset with missing `creationDate` is skipped
- sidecar snapshot load + JSONL replay
- corrupt JSONL line is skipped
- corrupt snapshot falls back to JSONL
- sidecar references missing file on disk
- sidecar with newer unsupported major schema

### Integration tests

- fresh install + legacy backup folder + partial backup
- fresh install + sidecar-backed backup folder
- backup folder on read-only volume
- import blocked while export queue is active
- exported file renamed by user after export
- exported file deleted by user after export
- two Photos assets with same filename and close timestamps
- two different libraries with overlapping filenames/dates

### Manual QA

- same-machine reinstall
- new machine with copied backup folder
- destination on external drive
- destination temporarily unavailable
- very large library and large backup tree

---

## Deferred Work

These are explicitly not in v1:

- `PHCloudIdentifier` integration
- persisting heuristic legacy matches back into the sidecar
- automatic cleanup of duplicate backup files
- background import while export is running
- auto-detecting arbitrary "backup-looking" folders without an app-owned sidecar

---

## Success Criteria

- Users with an existing backup folder can continue exporting after a fresh install.
- The first shipped version solves that without overbuilding the architecture.
- Future exports gradually improve the reliability and speed of later imports via the sidecar.
