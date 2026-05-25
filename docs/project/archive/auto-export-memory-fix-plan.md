# Auto-Export Memory Exhaustion Fix Plan - v2 (Archived)

**Status:** Implemented and archived as the issue #112 decision record. The
initial v2 recommendation below is preserved for history, but the code landed
with the documented implementation deltas near the end of this file. Do not use
the original "six concrete changes" section as an active checklist.

Diagnosis was confirmed as memory-watermark termination
(`EXC_RESOURCE` / `RESOURCE_TYPE_MEMORY` corpse). v1's "Fix A" recommendation
was rejected after multi-lens review: it was both too big (new parallel API) and
too small (it did not address sibling memory consumers visible in code reading,
and the cache-references-alone math does not cross a 1+ GB watermark). v2
recommended a tighter cluster of changes with stronger code-reading support and
an explicit uncertainty budget.

**Bug:** [#112](https://github.com/valtteriluomapareto/photo-export/issues/112).

**Companion already merged:** AutoSync run journal (PR #114, commit `6ac73f0`).
**Forward** forensic surface for future bugs of this class — not retroactive
validation for the reporter's prior crashes (their version shipped without the
journal). The journal arrives in the same release as this fix; if the kill
still happens after this PR ships, the journal names the surviving scope.

## What we know (unchanged from v1)

Reporter's `log show` output, three lines in the reproduction window:

```
11:16:01  ReportCrash: PID 57308 exceeded the memory high watermark
12:50:15  ReportCrash: PID 63432 exceeded the memory high watermark
13:00:22  ReportCrash: PID 76599 exceeded the memory high watermark
```

Each preceded by `event condition bump 0 -> 1` and `post-exception thread qos
drop 21 -> 17` — the classic `EXC_RESOURCE` / `RESOURCE_TYPE_MEMORY` signature.
Three separate PIDs in a two-hour window. Termination is via corpse exception,
not kernel jetsam. Process name not in the log line itself (corpse exceptions
log PID only); the `osanalyticshelper: Omitting com.valtteriluoma.photo-export
… stability` line at 13:19 confirms the stability daemon has crash records for
the bundle.

## What we DON'T know yet

The corpse `.ips` from `~/Library/Logs/DiagnosticReports/` would name the
proximate call stack. Requested in
[#112 comment](https://github.com/valtteriluomapareto/photo-export/issues/112#issuecomment-4527469582).
v2 does **not** gate implementation on it — the diagnosis is overdetermined
by code reading. If the `.ips` arrives and redirects, this plan expands.

## Root cause analysis

The auto-export fan-out (`AutoSyncManager.swift:477-595` →
`AutoSyncReducer.swift:179-202`) iterates timeline year/month chunks +
favorites + 282 user albums + shared albums. Across this fan-out, several
distinct memory consumers compound:

### 1. `phAssetCache` accumulates across the fan-out

`PhotoLibraryManager.phAssetCache` at `:58`:

```swift
/// Bounded cache of recently-fetched PHAsset objects keyed by localIdentifier.
/// Populated by fetchAssets so thumbnail and resource lookups avoid re-fetching.
/// Replaced wholesale on each fetch rather than doing per-entry eviction.
private var phAssetCache: [String: PHAsset] = [:]
```

**The doc-comment is aspirational, not regressed-out.** `git log -S phAssetCache`
shows the symbol was introduced in commit `e2a831f` with the additive
`cacheAssets(_:)` from line one. The wholesale-replace behaviour the comment
describes has never existed.

`cacheAssets(_:)` at `:712-716` is additive; every `fetchAssets(in:)` call at
`:265/:269/:275` writes into it; the cache only clears on `invalidateCache()`
(`:731`), called from `photoLibraryDidChange`.

### 2. `cachedOrFetchPHAsset(id:)` re-populates the cache on miss

At `:719-725`:

```swift
private func cachedOrFetchPHAsset(id: String) -> PHAsset? {
  if let cached = phAssetCache[id] { return cached }
  let result = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
  guard let asset = result.firstObject else { return nil }
  cacheAssets([asset])    // <-- refills the long-lived cache
  return asset
}
```

A scope-local cache strategy that doesn't address this would be defeated as
soon as the export path falls through to a per-asset lookup (resource fallback
during export of a Live Photo's edited variant, for example).

### 3. Missing `autoreleasepool` on the album / favorites fetch paths

`fetchPHAssets(year:month:)` at `:1019-1088` wraps its inner loop in
`autoreleasepool { ... }` (around `:1078`) so PhotoKit's per-iteration
autoreleased temporaries drain promptly.

`fetchFavoritesPHAssets` (`:791-804`) and `fetchAlbumPHAssets` (`:806-821`)
do NOT — they call `result.enumerateObjects { asset, _, _ in assets.append(asset) }`
with no pool. Across 282 albums × hundreds of assets each, the autoreleased
pile drains only at the next runloop boundary. This is a co-conspirator the
v1 plan missed entirely.

### 4. `fetchCollectionTree()` walks the full tree per album

`ExportManager.enqueueCollection` (around `:1328`) calls into
`fetchCollectionTree()` *inside* the per-album loop. 282 iterations × full
tree walk is its own memory pulse independent of `phAssetCache`. The result
is cacheable at `:743` (`cachedCollectionTree`) but the per-album work still
runs every iteration.

### 5. The arithmetic

PHAsset is an Obj-C object: ~16B header + ivars (localIdentifier, dates,
dimensions, mediaType, flags, internal handles) ≈ 200–500 bytes resident per
asset. 80k × 500B + Swift dict overhead (~80–100 bytes/entry including the
36-char UUID string) ≈ **50–60 MB**.

A typical sandboxed macOS app high watermark is **>1 GB**. So PHAsset
references in `phAssetCache` alone are not crossing the watermark. Causes
#3 and #4 above, plus PhotoKit's lazy working set retained by each PHAsset
(resource handles, photolibraryd IPC caches, image-export sessions in
progress), plus `PHFetchResult` retention via captured closures across the
fan-out, are the other plausible contributors. Pure cache-size accounting
doesn't close the gap on its own — but the cache is the most easily
addressed lever, and the other levers (autoreleasepools, tree hoist) are in
the same file.

**v2's bet:** the six fixes below address every memory consumer visible in
code reading; if they're not enough collectively, the `.ips` (when it
arrives) names what's left.

## Historical v2 Recommendation - six concrete changes in one PR

### Fix 1: scope-end cache drop *(load-bearing)*

In `AutoSyncManager.startRun`'s fan-out loop (`AutoSyncManager.swift:546-593`),
after each sub-scope's `runExport` completes, call a new narrow entry point
on `PhotoLibraryManager`:

```swift
photos.forgetPHAssetCache()    // drops phAssetCache, leaves cachedCollectionTree alone
```

Implemented in `PhotoLibraryManager` as:

```swift
func forgetPHAssetCache() {
  phAssetCache.removeAll()
}
```

Distinct from `invalidateCache()` (`:731`) — does not touch
`cachedCollectionTree`, does not bump `libraryRevision`, does not trigger
SwiftUI re-fetches in sidebar/grid views. Just drops the dict.

`phAssetCache` is `@MainActor`-isolated (`PhotoLibraryManager` is `@MainActor`
at `:16`); `AutoSyncManager` is `@MainActor` at `:12`; the fan-out Task is
explicitly `Task { @MainActor in ... }` at `:528`. So the clear happens on the
same actor that owns the cache — no race, no Sendable concern.

### Fix 2: `cachedOrFetchPHAsset` doesn't refill the long-lived cache

At `:719-725`, drop the `cacheAssets([asset])` call (or add a `cacheResult:
Bool` parameter with a `false` default — slightly larger diff but preserves
behaviour for the one caller that wants it). Since the fallback is only ever
used for resolver-time `descriptor → PHAsset` bridging, refilling the
long-lived cache from this site is the same accumulation pattern Fix 1 is
draining; without Fix 2, the export path refills what Fix 1 drained.

### Fix 3: `autoreleasepool` around album / favorites enumeration

At `:791-804` (`fetchFavoritesPHAssets`) and `:806-821` (`fetchAlbumPHAssets`),
wrap the `result.enumerateObjects { ... }` body in `autoreleasepool { ... }`.
Matches the pattern `fetchPHAssets(year:month:)` already uses at `:1078`.
Drains PhotoKit's per-iteration autoreleased Obj-C temporaries.

### Fix 4: hoist `fetchCollectionTree()` out of per-album loop

In `ExportManager` (around `:1300-1370`), the call to `fetchCollectionTree()`
inside `enqueueCollection` should be hoisted out to `runBulkEnqueueLoop`'s
caller and threaded through, or memoized for the duration of the fan-out. 282
× tree walk → 1 × tree walk.

### Fix 5: `await Task.yield()` between albums

`ExportManager.runBulkEnqueueLoop` at `:1066-1083` iterates 282+ collections
without yielding. Add `await Task.yield()` between iterations. Lets
WindowServer pings interleave; drops jetsam pressure score; doesn't help
memory but helps the beachball just enough that the user notices.

### Fix 6: timeline batch size 500 → 100

`fetchPHAssets(year:month:)` at `:1074` uses a `batchSize` of 500 between
`Task.sleep(1ms)` yields. Reducing to 100 = 5× more frequent yields during
the heaviest single scope. One-character constant change.

## Sequencing decision

**Single PR:** all six fixes.

Rationale:
- Fixes 1–4 collectively address the memory-pressure cause and are tightly
  coupled (Fix 2 is required for Fix 1 to hold; Fix 3 is in the same file as
  Fix 1; Fix 4 is the same loop as Fix 5).
- Fix 5 and Fix 6 are small UX-perceptibility wins co-located with the
  memory fixes.
- The off-main enumeration refactor v1 called "Fix B" is **deferred** to a
  follow-up PR. Off-main moves of PhotoKit calls (`Task.detached(priority:
  .userInitiated)`) have a wider refactoring footprint — thumbnail-fetch and
  live-photo-detection paths read from the same fetch results — and the
  user's symptom is the *kill*, not the beachball. The beachball can be
  addressed in its own focused PR.

User-facing outcome after this PR: auto-export completes without termination
on large libraries. The UI may still beachball briefly on the heaviest
scopes; the timeline batch shrink (Fix 6) softens it, but doesn't eliminate
it. That's the deferred PR's job.

## Implementation outline

Order of changes within the PR:

1. **Add `forgetPHAssetCache()`** to `PhotoLibraryManager`. Document it.
   Update the misleading doc-comment at `:58` to match reality (something
   like: "Long-lived cache, persists until library change or explicit
   `forgetPHAssetCache()`. Auto-export drops this between scope iterations
   to bound peak memory across the fan-out.").
2. **Call it from `AutoSyncManager.startRun`** after each scope's `runExport`
   (`:546-593`).
3. **Remove the `cacheAssets([asset])` call at `:723`** in
   `cachedOrFetchPHAsset` (or add the `cacheResult: Bool = false` parameter).
4. **Wrap album and favorites enumeration** in `autoreleasepool { ... }`
   (`:791-804`, `:806-821`).
5. **Hoist `fetchCollectionTree()`** out of `enqueueCollection` to the fan-out
   driver.
6. **Add `await Task.yield()`** between iterations in `runBulkEnqueueLoop`.
7. **Change timeline batch size** 500 → 100 at `:1074`.

## Testing strategy

The existing test infrastructure does not expose `phAssetCache` size:
`PhotoLibraryService` (`Protocols/PhotoLibraryService.swift:7-82`) returns
`[AssetDescriptor]` only; `FakePhotoLibraryService` (`TestHelpers/
FakePhotoLibraryService.swift:8`) never touches the cache; and
`PhotoLibraryManagerTests.swift` is 59 lines covering only the live-photo
fallback path. **The plan owns the new test surface as a line item.**

1. **Add a `phAssetCacheCount` test hook** on `PhotoLibraryManager` —
   `internal var phAssetCacheCount: Int { phAssetCache.count }` — gated to
   `#if DEBUG` or behind an `@testable` boundary.
2. **Unit test in `PhotoLibraryManagerTests`** driving the real
   `PhotoLibraryManager` with a fake `PhotoLibraryService` injection that
   returns canned descriptors; assert that after a simulated AutoSync scope
   iteration, `forgetPHAssetCache()` brings `phAssetCacheCount` to 0.
3. **Unit test for `cachedOrFetchPHAsset`** asserting the cache count does
   not grow when called repeatedly after the Fix 2 change.
4. **Integration-ish test in `AutoSyncManagerTests`**: drive a fan-out with
   3 scopes, assert `forgetPHAssetCache()` was called 3 times (record on a
   spy method on the fake). This is the structural-assertion analogue of
   the `RecordingDirectoryFsync` pattern from PR #114.
5. **Manual on real device:** maintainer reproduces against a library
   closest to the reporter's class (80k+ assets, 200+ albums). Exit
   criterion: AutoSync startup fan-out completes; no termination; saved
   diagnostic report shows healthy completion. **This remains the
   load-bearing manual gate** — the unit tests prove behaviour, not
   memory.

**Not committing to:** `XCTMemoryMetric` / `measure(metrics:)` regression
guards. The codebase has zero such usage today; introducing one in this PR
expands review scope significantly. Acceptable follow-up if memory
regressions recur.

## Anti-promises / non-goals

- **UI beachball stays substantially.** Fix 5 (`Task.yield()`) and Fix 6
  (batch shrink) soften it; the structural fix is the deferred off-main
  enumeration PR.
- **No `phAssetCache` redesign for UI paths.** Long-lived cache stays as-is
  for non-AutoSync callers. The `startCachingThumbnails` /
  `stopCachingThumbnails` read sites at `:491` / `:507` continue to read
  from the cache — they're called from the UI for thumbnail prefetch, not
  from the AutoSync export path.
- **No new entitlements, no memory-pressure observer, no in-app status
  surface for memory health.**
- **No PHAsset working-set instrumentation.** If after this PR the kill
  still happens, the journal will name the surviving scope and the next
  PR can dig into PhotoKit-side memory (resource handles, image-export
  sessions). v2 does not promise to address that today.
- **No retroactive fix for users on 1.6.0 (129).** Both this fix and the
  journal ship in the next release. Users on the current version continue
  to need the workaround (turn auto-export off before launch, on after).
- **Off-main enumeration is deferred** to a follow-up PR.

## Open questions

1. **`fetchCollectionTree()` hoist mechanism.** Is the cleanest cut to memoize
   it in `runBulkEnqueueLoop`'s caller and pass through, or to add a
   `runBulkEnqueueLoop(collectionTree: PhotoCollectionTree)` parameter?
   *Decided at implementation time; both are defensible.*
2. **The corpse `.ips`.** If it arrives and the stack points outside the six
   fixes above (e.g. resource buffering during export, image-export sessions,
   thumbnail decode), the plan expands. *Action: revisit after the `.ips`
   arrives or after ~one week without it; ship v2 as-is regardless.*

## What was closed from v1's open questions

- **v1 OQ#1 (doc-comment archaeology).** Resolved: the doc was aspirational
  from inception (`e2a831f`), no wholesale-replace path ever existed.
- **v1 OQ#4 (PR #92 / #107 interaction).** Resolved: catch-up uses targeted
  `PHAsset.fetchAssets(withLocalIdentifiers:)`, not the scope-fetch path.
  No interaction.

## When to act

Archived note: no new implementation should be started from this section. The
fix has already landed with the deltas documented below. Future smoothness work
that builds on this area belongs in the active
[`../plans/ui-smoothness-plan.md`](../plans/ui-smoothness-plan.md) roadmap.

---

## Implementation notes (v2 plan → v2 implementation deltas)

The implementation differs from this plan in three documented ways, all
discovered during code reading and multi-lens review of the first
implementation attempt:

### Cache-drop site moved one layer down

This plan placed the cache-drop in `AutoSyncManager.startRun` (between
scope iterations). Architect-lens review on the first attempt found that
each scope's bulk path (`ExportManager.runBulkEnqueueLoop`) iterates
internally — timeline across years, albums across 282 collections — and
the cache accumulates *within* a single AutoSync scope without an
intra-loop drop. For an 80k library across 20 years, the timeline scope
alone would still accumulate ~80k entries before reaching the
between-scope drop.

The cache-drop therefore moved to the top of each iteration in
`ExportManager.runBulkEnqueueLoop`. This bounds peak cache footprint by
the max single-iteration fetch size (~one year of timeline or one album)
rather than the cumulative fan-out. The next bulk loop's first iteration
also drops the previous scope's last-iter residue, so the
between-scope drop in `AutoSyncManager` is no longer needed and was
removed. `PHAssetCacheControlling` is injected into `ExportManager`
rather than `AutoSyncEnvironment`.

### Fix 4 (collection-tree hoist) skipped

This plan's Fix 4 ("hoist `fetchCollectionTree()` out of
`enqueueCollection`'s 282-iteration loop") was based on the assumption
that each per-album call walked the tree. Code reading at
`PhotoLibraryManager.swift:843-846` shows `cachedCollectionTree`
already memoizes the walk: the first call constructs the tree, the
remaining 281 calls return the cached array. Hoisting would not change
the memory profile and was dropped.

### `autoreleasepool` placement rewrite

This plan called for adding `autoreleasepool` to `fetchFavoritesPHAssets`
and `fetchAlbumPHAssets`. The first attempt wrapped only the pure-Swift
`assets.append(asset)` call inside the `enumerateObjects` closure body —
which drains nothing PhotoKit-side, because PhotoKit's autoreleased
temporaries are minted by the `enumerateObjects` callback machinery
*before* the user's closure runs. Multi-lens review caught this.

The implementation converts both sites to index-based `for index in
0..<result.count { autoreleasepool { assets.append(result.object(at:
index)) } }` matching the proven pattern at `fetchPHAssets(year:month:)`.
The pool now wraps the `result.object(at:)` call — that's the PhotoKit
call that mints the autoreleased object.

### Other deltas from this plan

- The `phAssetCacheCount` test hook proposed in §"Testing strategy" was
  added in the first attempt and then dropped: it's only useful if a
  unit test can populate the cache, and `PHAsset` can't be constructed
  in unit tests without PhotoKit authorisation. The structural assertion
  via the `RecordingPHAssetCacheControl` spy in `ExportAllAlbumsTests`
  is the load-bearing test.
- The weak `PhotoLibraryManagerTests.forgetPHAssetCacheLeavesEmptyCacheUntouched`
  proposed in §"Testing strategy" was added and then dropped for the
  same reason — it pinned method existence (a compile-time concern) and
  nothing else.
- `PHAssetCacheControlling` is marked `Sendable` (in addition to its
  `@MainActor` constraint) to future-proof against detached-task capture.
  A `NoOpPHAssetCacheControl` default is provided for `ExportManager`
  test sites that don't care about cache-drop behaviour.
