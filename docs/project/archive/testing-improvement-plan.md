# Testing Improvement Plan

Status: Steps 1-7 shipped. Steps 8 (UI tests + CI) and 9 (fixtures/helpers) were never started and have been folded back into [`implementation-tasks.md`](../implementation-tasks.md) under a new Testing section — re-spec before picking up. The "~167 tests in 18 suites" baseline below is the count at the time of Step 7's completion and was not maintained afterward; treat it as historical. Kept as a decision record for the protocol-seam strategy and the gap analysis it produced.

Current state: **~167 tests in 18 suites.** Protocol seams are in place (Step 2 done). Export pipeline, record store recovery, backup-scanner matching, edited-mode export, and ExportDestinationManager validation/persistence all have coverage. Remaining gaps are MonthViewModel async loading, full ExportDestinationManager integration (volume unmount, security-scope pairing), and UI tests.

> Re-count by running `xcodebuild ... test` and reading the test summary; this header is hand-maintained and may lag the suite by a few tests at any point in time.

---

## Current Coverage Summary

| Component | Coverage | Tests | Verdict |
|-----------|----------|-------|---------|
| ExportRecordStore | High | 11 | Solid — persistence, replay, corruption, isolation, coalescing |
| ExportRecordStore recovery | High | 8 | Compaction, crash recovery, snapshot+log overlay |
| BackupScanner (parsing) | Good | 17 | Scanning and parsing covered |
| BackupScanner (matching) | Good | 11 | Matching algorithm now covered |
| ExportManager helpers | Partial | 10 | `splitFilename`, `uniqueFileURL`, queue counters |
| ExportManager pipeline | Partial | 13 | Happy path, failures, cancellation via protocol seams |
| ContinuationResume pattern | Complete | 4 | Concurrent lock safety verified |
| Authorization mapping | Complete | 5 | All `PHAuthorizationStatus` values |
| MonthFormatting | Complete | 2 | Edge cases included |
| AssetResourceWriter | Partial | 3 | Production implementation tested |
| ExportDestinationManager | Partial | 8 | Validation guards + bookmark save/restore/destinationId persistence |
| PhotoLibraryManager | Low | 0 | Only auth mapping, no asset logic |
| MonthViewModel | 0% | 0 | All async loading untested |
| All Views | 0% | 0 | UI tests are template stubs |

---

## Step 1: Fix Low-Signal Existing Tests — DONE

Fixed: ExportDestinationValidationTests split into proper groups, TempFileCleanupTests replaced with pipeline integration tests, MonthFormattingTests locale-pinned.

---

## Step 2: App-Owned Abstractions and Protocol Seams — DONE

Implemented:
- `AssetDescriptor` and `ResourceDescriptor` value types replace `PHAsset`/`PHAssetResource` at all non-framework boundaries
- `PhotoLibraryService` protocol — `PhotoLibraryManager` conforms
- `AssetResourceWriter` protocol — production implementation wraps `PHAssetResourceManager`
- `FileSystemService` protocol — `FileIOService` conforms
- `ExportDestination` protocol — `ExportDestinationManager` conforms

All protocols live in `photo-export/Protocols/`. Tests inject fakes for all four seams.

---

## Step 3: Test the Export Pipeline — DONE

`ExportPipelineTests.swift` covers the export pipeline via protocol fakes: happy path, write failures, move failures, cancellation, queue draining, duplicate skipping.

---

## Step 4: Test BackupScanner Matching — DONE

`BackupScannerMatchingTests.swift` covers the matching algorithm: exact date match, ambiguous dates, filename refinement, unmatched files, adjacent-month rollover, multiple candidates.

---

## Step 5: Test ExportRecordStore Recovery Paths — DONE

`ExportRecordStoreRecoveryTests.swift` covers: compaction trigger, crash recovery, snapshot+log overlay, corrupted snapshot fallback, empty snapshot with populated log, permission errors.

---

## Step 6: Test MonthViewModel (Medium Priority)

**Target:** `MonthViewModel.swift` — 0% coverage, complex async state.

Requires `PhotoLibraryService` fake from Step 2.

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **loadAssets happy path** | Assets fetched → thumbnails loaded → first asset selected |
| **Thumbnail failure** | Load fails → asset added to `failedThumbnailIds` → retry works |
| **HQ upgrade** | Background task upgrades thumbnails after initial load |
| **HQ skipped during export** | Network access blocked while `isExporting` is true |
| **Month change cancellation** | Changing month cancels previous load task |
| **Empty month** | No assets → empty state, no errors |

---

## Step 7: Test ExportDestinationManager (Medium Priority)

### Test cases needed:

| Scenario | What it validates |
|----------|-------------------|
| **Bookmark round-trip** | Save bookmark → restore → URL matches |
| **Stale bookmark** | Bookmark data resolves with `isStale` flag → re-saved |
| **validate() cascade** | URL unreachable → not directory → not writable → correct error at each stage |
| **Volume unmount** | Destination volume ejected → validation updates, error message shown |
| **Path length limit** | Path exceeding 1000 UTF-8 bytes → rejected |
| **Security-scoped access pairing** | begin/end always paired, even on error |

---

## Step 8: Add UI Tests and Run in CI (Lower Priority)

Current UI test target has only template stubs. The shared scheme and CI pipeline skip the UI bundle entirely.

### 8a. Add deterministic UI test mode

Before adding CI XCUI coverage, make the app launch into a predictable fake-data mode.

Add a small composition root for UI tests:
- Launch argument or environment variable (for example `UI_TEST_MODE=1`)
- `photo_exportApp` checks for that flag at startup
- App injects fake `PhotoLibraryService`, fake `ExportDestination`, fake `ExportRecordStore` seed data, and a no-op folder picker/resource writer
- UI tests never depend on the real Photos library, `NSOpenPanel`, or local machine state

Without this harness, the flows below will be brittle and unsuitable for CI.

### 8b. Implement real XCUI test flows:

| Flow | Key assertions |
|------|----------------|
| **First launch / onboarding** | Onboarding view appears, folder picker works, export-all toggle |
| **Browse library** | Sidebar shows years/months, selecting month loads thumbnails |
| **Select asset** | Clicking thumbnail shows detail view with metadata |
| **Export month** | Start export → progress shown → completion state |
| **Pause / resume / cancel** | Toolbar buttons toggle state correctly |
| **Import existing backup** | Import sheet opens, stages progress, results shown |

### 8c. Enable in CI:

- Add UI test bundle to the shared scheme's test action
- Add a separate CI job (or step) that runs UI tests — they're slower and may need a different `destination`
- Consider running UI tests only on PR merges (not every push) to keep CI fast

---

## Step 9: Add Test Infrastructure (Supporting)

### 9a. Test fixtures directory

Create `photo-exportTests/Fixtures/` for small test assets:
- Tiny JPEG (1x1) for image metadata tests
- Tiny MP4 for video duration tests
- Sample export-records snapshot JSON for recovery tests

### 9b. Shared test helpers

Extract common patterns into `photo-exportTests/TestHelpers/`:
- `makeTempDir()` / `cleanup()` (currently duplicated across test files)
- `FakePhotoLibraryService`, `FakeFileSystem`, `FakeExportDestination`, `FakeAssetResourceWriter` (from Step 2)
- Builder helpers for creating `ExportRecord` instances

### 9c. Test plan (optional)

Consider adding an `.xctestplan` file if tests grow complex enough to need selective runs or environment variable configuration.

---

## Suggested Execution Order

```
Step 1  Fix low-signal tests           ✅ DONE
Step 2  Protocol seams                 ✅ DONE
Step 3  Export pipeline tests          ✅ DONE
Step 4  BackupScanner matching tests   ✅ DONE
Step 5  ExportRecordStore recovery     ✅ DONE
Step 6  MonthViewModel tests           ← next priority
Step 7  ExportDestinationManager tests partial — bookmark + validation done, integration cases (unmount, scope pairing) outstanding
Step 8  UI tests + CI integration      (valuable but highest effort)
Step 9  Test infrastructure            (do incrementally alongside Steps 6-8)
```

Steps 6 and 7 can be tackled in any order — all protocol seams are in place.
