# Auto-Export Memory Exhaustion Fix Plan

**Status:** Draft v1. Diagnosis confirmed via the reporter's Console log (three
`ReportCrash: PID … exceeded the memory high watermark` events in the
reproduction window). Pending: `.ips` stack trace from
`~/Library/Logs/DiagnosticReports/` for stack-level confirmation, requested
in [#112 comment](https://github.com/valtteriluomapareto/photo-export/issues/112#issuecomment-4527469582).

**Bug:** [#112](https://github.com/valtteriluomapareto/photo-export/issues/112) —
photo-export silently terminates during startup auto-export on a large library
(80k+ assets, 282 albums + shared albums, auto-export covering timeline +
favorites + all albums + shared albums).

**Companion shipped:** AutoSync run journal (PR #114, merged as `6ac73f0`).
Doesn't fix the kill, but in the next release will leave a `currentRun.json`
naming which scope was in flight when the kill happened. Forensic surface for
the next-time-this-class-of-bug-happens triage.

## What we know

From the reporter's `log show` output:

```
11:16:01  ReportCrash: PID 57308 exceeded the memory high watermark
12:50:15  ReportCrash: PID 63432 exceeded the memory high watermark
13:00:22  ReportCrash: PID 76599 exceeded the memory high watermark
```

Each preceded by `event condition bump 0 -> 1` and
`post-exception thread qos drop 21 -> 17` — the classic `EXC_RESOURCE` /
`RESOURCE_TYPE_MEMORY` signature. Three separate PIDs in a two-hour window
= three separate launches all hitting the same limit. Process name isn't
in the log line itself (corpse exceptions log PID only), but the
`osanalyticshelper: Omitting com.valtteriluoma.photo-export … stability`
line at 13:19 confirms the stability daemon has accumulated records for
the bundle. Causation is virtually certain.

**This is not kernel jetsam.** It's the sandboxed-app **high-watermark**
mechanism — `EXC_RESOURCE` is delivered, `ReportCrash` writes a corpse
report (`.ips` / `.memexec`), the process is terminated. From the app's
perspective: indistinguishable from SIGKILL. From the user's perspective:
no crash dialog, just a disappearing app.

## Root cause analysis

`PhotoLibraryManager.phAssetCache` at `PhotoLibraryManager.swift:58`:

```swift
/// Bounded cache of recently-fetched PHAsset objects keyed by localIdentifier.
/// Populated by fetchAssets so thumbnail and resource lookups avoid re-fetching.
/// Replaced wholesale on each fetch rather than doing per-entry eviction.
private var phAssetCache: [String: PHAsset] = [:]
```

**The doc-comment is wrong.** `cacheAssets(_:)` at `:712-716`:

```swift
private func cacheAssets(_ assets: [PHAsset]) {
  for asset in assets {
    phAssetCache[asset.localIdentifier] = asset
  }
}
```

The implementation is **additive**, not wholesale-replace. Every
`fetchAssets(in:)` call inserts entries; the cache only clears on
`invalidateCache()` (`:731`), called only from `photoLibraryDidChange`.

The auto-export fan-out (`AutoSyncManager.swift:477-519` →
`AutoSyncReducer.swift:179-202`) iterates:

1. Timeline split into year/month chunks (`fetchPHAssets(year:month:)`).
   For an 80k library spanning many years, that's tens of fetches, each
   adding ~thousands of entries.
2. Favorites once (`fetchFavoritesPHAssets`).
3. **282 user albums** (`fetchAlbumPHAssets` once per album).
4. Shared albums (same path as user albums, different subtype).

Across all four scopes, **every PHAsset reference the fan-out touched
remains pinned in `phAssetCache` until app exit (or library change).**
The dict deduplicates by `localIdentifier`, so an asset present in
timeline + favorites + 3 albums occupies one entry — but each unique
asset is one entry, and at this library size that's ~80k+ entries plus
their underlying PhotoKit working-set (lazy resource handles, etc).

Read sites for `phAssetCache`:

- `:491`, `:507` — `descriptor → PHAsset` bridge in resource-export paths.
- `:720` — `cachedOrFetchPHAsset(id:)` falls back to a fresh `PHAsset.fetchAssets(withLocalIdentifiers:)` if missing.

**The cache is an optimisation, not a correctness requirement.** Dropping
entries between scopes is safe; the fallback re-fetch path already exists.

## Three candidate fixes

### Fix A — scope-local PHAsset cache *(load-bearing)*

Change the cache lifecycle from "lives until library change" to "lives
until the scope iteration's caller is done with the result." The smallest
defensible refactor:

- **Option A1 (minimal diff):** add a sibling API
  `fetchAssetsWithPHAssets(in:mediaType:) -> (descriptors:, phAssets: [String: PHAsset])`
  that returns the scope-local dict alongside the descriptors. Auto-export
  uses it; the dict is released when the scope iteration completes. The
  long-lived `phAssetCache` shrinks to "stuff the UI fetched recently"
  (which is what the doc-comment originally promised).
- **Option A2 (cleaner, larger diff):** drop `phAssetCache` entirely from
  the auto-export path. All `descriptor → PHAsset` lookups go through
  `cachedOrFetchPHAsset(id:)`, which re-fetches via
  `PHAsset.fetchAssets(withLocalIdentifiers:)`. Cost: extra PhotoKit
  lookup per asset on the export hot path; saves: zero accumulated
  references.
- **Option A3 (bounded cache):** keep the long-lived cache, cap at N
  entries with LRU. Cost: depends on access patterns for cross-scope
  lookups that we'd need to characterise first.

**Recommendation: A1.** Preserves the within-scope lookup hot path
(thumbnails, sequential resource writes), drops the cross-scope
accumulation that's killing us, doesn't change behaviour for non-auto-export
callers. Read sites at `:491`, `:507` continue working because they're
within the same scope as the cache population.

### Fix B — off-main PHAsset enumeration *(beachball)*

`fetchFavoritesPHAssets` (`:791-804`) and `fetchAlbumPHAssets`
(`:806-821`) call `result.enumerateObjects { … }` synchronously on the
main actor. `fetchPHAssets(year:month:)` (`:1019-1088`) iterates
`fetchResult.object(at: index)` with a `Task.sleep(1ms)` yield every 500
items — which still leaves the main thread blocked for the rest of each
500-item batch.

The pattern at `:286-306, :347-380` already exists: `Task.detached(priority: .userInitiated)`
wrapping the `PHFetchResult` work. Apply the same shape to the three
fetch sites.

PHFetchResult and PHAsset reads are documented thread-safe; the
cross-actor hand-off happens at the existing `await` boundaries that
already cross actors.

**Fix B does NOT fix the kill on its own.** Moving the work off-main
doesn't reduce its memory footprint — the same PHAssets accumulate in
`phAssetCache`. B addresses the *symptom* (UI beachball) but not the
*termination*.

### Fix C — yield between albums *(cheap responsiveness)*

`ExportManager.runBulkEnqueueLoop` (`:1066-1083`) iterates 282+
collections back-to-back without yielding. Even with Fix B moving each
fetch off-main, the dispatch-and-await pattern in this loop keeps the
main actor busy across iterations.

Add `await Task.yield()` between iterations. Lets WindowServer pings
interleave, drops jetsam pressure score, and is a one-line change.

## Sequencing decision

**Single PR:** Fix A + Fix C.

Rationale:
- **Fix A is necessary and sufficient for the kill.** Without it, B's
  off-main move keeps the memory pinned in the same dict on a different
  thread.
- **Fix C is one line.** Folds in naturally.
- **Fix B is deferred.** Off-main moves of PhotoKit enumeration have a
  wider refactoring footprint (thumbnail-fetch / live-photo-detection
  paths read from the same fetch results) and beachball-only impact.
  Better in its own PR with its own test surface.

The user-facing outcome after this PR: auto-export completes without
termination on large libraries. The UI may still beachball briefly during
the heavy scopes — that's Fix B's job in a follow-up.

## Implementation outline (Fix A + C)

1. **Add `fetchAssetsWithPHAssets(in:mediaType:)`** in `PhotoLibraryManager`.
   Returns `(descriptors: [AssetDescriptor], phAssets: [String: PHAsset])`.
   Internally calls the existing `fetchPHAssets` / `fetchFavoritesPHAssets`
   / `fetchAlbumPHAssets` and constructs the dict locally without touching
   `self.phAssetCache`.
2. **Update auto-export callers** (`ExportManager.enqueueCollection` at
   `:1311-1367`, the timeline path, favorites path) to use the new API
   and pass the scope-local dict to whichever downstream stage needs
   `descriptor → PHAsset` resolution. Or, if the downstream only needs
   descriptors, just discard the dict.
3. **Leave `phAssetCache` and the existing `fetchAssets(in:)` for UI
   callers.** They're not the failure mode and changing them would
   expand the blast radius unnecessarily.
4. **Fix the doc-comment** on `phAssetCache:58`. It currently lies; honest
   doc is "Long-lived cache; entries persist until the next library
   change. Auto-export uses `fetchAssetsWithPHAssets` to avoid contributing
   to this cache."
5. **Add `await Task.yield()`** between iterations in
   `runBulkEnqueueLoop` (`:1066-1083`).

## Testing strategy

- **Unit:** new `PhotoLibraryManagerScopeLocalCacheTests` — drive 5
  successive `fetchAssetsWithPHAssets` calls with a fake `PHFetchResult`
  shim; assert `phAssetCache` (the long-lived one on the manager) does
  NOT grow.
- **Unit:** assert the existing `fetchAssets(in:)` UI API still populates
  `phAssetCache` (no behaviour change for UI paths).
- **Integration:** drive a fake `AutoSyncManager` fan-out with 50
  album-scope iterations and assert peak `phAssetCache.count` remains <
  the per-scope worst case. Doesn't need real PhotoKit; can use the
  existing `PhotoLibraryService` injection point.
- **Manual on real device:** maintainer reproduces against a library
  closest to the reporter's class (80k+ assets, 200+ albums). Exit
  criterion: AutoSync startup fan-out completes; no termination; saved
  diagnostic report shows healthy completion.
- **Forensic backstop:** the recently-merged journal — once shipped, any
  residual termination leaves a `currentRun.json` naming the surviving
  failure scope. Tells us which fix to land next if this one is partial.

## Anti-promises / non-goals

- **UI beachball stays.** Fix A drops memory; Fix B addresses
  responsiveness. Beachball is explicitly Fix B's territory and not part
  of this PR.
- **No `phAssetCache` redesign for UI paths.** Long-lived UI cache stays
  as-is. Smaller scope, smaller diff, smaller review.
- **No throttling work-in-flight.** If the corpse `.ips` (when it
  arrives) points at a different memory consumer than `phAssetCache`
  (e.g. resource buffering during export, or PhotoKit's own working
  set), the plan expands. Today's plan addresses the strongest signal
  visible in code reading.
- **No new entitlements, no memory-pressure observer, no in-app status
  surface for memory health.**
- **No retroactive fix for users on 1.6.0 (129).** The fix ships in the
  next release. The journal also ships in the next release. Users on
  the current version continue to need the workaround (turn auto-export
  off before launch, on after) until they update.

## Open questions

1. **The `phAssetCache` doc-comment.** "Replaced wholesale on each fetch"
   contradicts the implementation. Was the cache ever wholesale-replaced
   and quietly changed without updating the doc, or has the doc always
   been aspirational? *Action: git-blame the comment vs. `cacheAssets(_:)`
   before refactoring — if there's a removed wholesale-replace code path
   in history, it documents the intended design.*
2. **`.ips` confirmation.** The reporter may attach the corpse report.
   If the stack points at `phAssetCache` accumulation or `cacheAssets(_:)`,
   the plan is unchanged. If it points at resource-write buffering,
   thumbnail caching, or PhotoKit's working set, the plan expands.
   *Action: wait for the issue follow-up; revise this document if the
   stack redirects.*
3. **Fix B's necessity timing.** Even after Fix A, with a 282-album
   fan-out the main thread is busy enough to beachball noticeably. Is
   this the same PR's problem or a follow-up? *Recommendation: follow-up
   PR. The user reported "beachballing while doing the sync" and "closes
   without an error" as two symptoms; A fixes the closes-without-error.
   The beachball needs its own PR to keep the diff reviewable.*
4. **PR #92 / #107 interaction.** The catch-up coalesce work landed
   recently. Does the new scope-local cache API need to participate in
   the coalesce path, or is it auto-export-only? *Assessment: catch-up
   uses targeted-by-id fetches via `PHAsset.fetchAssets(withLocalIdentifiers:)`,
   not the scope-fetch path. No interaction.*

## When to act

After the `.ips` arrives (or after some time without it — say a week —
acting on the strongest available signal). The diagnosis is strong
enough today to start implementation; the `.ips` would either confirm or
expand the scope.
