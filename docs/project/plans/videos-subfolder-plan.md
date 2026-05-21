# Videos Subfolder Plan (issue #38)

Date: 2026-05-21
Status: Proposed (not started). Targets `main` post-PR #102 (Live Photos paired export).

## Summary

Issue [#38](https://github.com/valtteriluomapareto/photo-export/issues/38) asks for an option to separate exported videos from photos so a backup doesn't mix `.JPG` and `.MOV` files in the same directory. Ship a single Setting (off by default) that, when on, routes every variant of a **standalone-video asset** into a `videos/` subfolder inside the placement, while leaving Live Photos (still + paired motion) co-located at the base placement path so they remain auto-paired by viewers and re-importers:

- photos: `2026/03/IMG_0001.JPG` (unchanged)
- standalone videos: `2026/03/videos/IMG_0002.MOV`
- Live Photo still: `2026/03/IMG_0003.HEIC` (unchanged)
- Live Photo paired motion: `2026/03/IMG_0003.MOV` (unchanged — stays with its still)
- album equivalents: `Collections/Albums/Trip/videos/IMG_0002.MOV`, etc.

Default `.flat` preserves today's layout for existing installs. The choice persists per file via a new `subfolder: String?` field on `ExportVariantRecord` so reconcile, reuse-source, and mid-life toggle changes all stay correct without recomputing from a global flag.

## Background and design notes

### Why the option exists

A user with a 130k-asset library asked for it; the maintainer's reply on issue #38 endorsed a simple per-month subfolder as the first cut. The full discussion floated three layouts: `<month>/videos/`, `videos/YYYY/MM`, and `YYYY/VIDEOS/MM`. Shipping the `<placement>/videos/` form first keeps the placement identity unchanged (a video at `2026/03/videos/X.MOV` is still in placement `timeline:2026-03`) and leaves room for a future multi-layout picker without schema change.

### Why Live Photo paired motion stays with its still (option 2)

Routing every `.MOV` file to the subfolder is mechanically uniform but breaks Live Photos as a unit on disk: viewers, Photos.app re-import, and any Live-Photo-aware tool recognise a Live Photo by the still and motion sharing a stem **in the same directory**. Splitting `IMG.HEIC` from `IMG.MOV` across two folders would silently de-pair them. The user's request was "don't mix photos and videos" — a Live Photo's motion isn't a video in that mental model, it's the second half of one photo.

Keying the subfolder rule on `descriptor.mediaType == .video` (instead of "any file with a video extension") also keeps the implementation small:

- `destDir` stays one-per-asset (today's invariant); no per-variant directory resolution in `runJob`.
- `ExportDestinationResolver.allocatePairedGroupStem` is untouched; image and paired-video slots still live in one directory, so its single-`destDir` probe stays correct.
- The helper's signature drops `variant` entirely — only `mediaType` and `layout` matter.

### Why a record-schema change is required (not just a runtime helper)

A purely schema-free design — recompute the path from `(placement, mediaType, currentSetting)` at every read — creates a real reconcile bug, not just a perf miss. `ExportRecord.relPath` is shared across an asset's variants and gets overwritten on every write. If a user toggles the setting after exporting a standalone video and re-writes one variant, the record's `relPath` flips while the other variant's file remains where it was; the next `reconcileAgainstFilesystem` would probe the wrong location and silently prune the still-valid `.done` variant.

The fix is one optional field per variant. `nil` means "the bare placement path" (what every existing record decodes to). Reuse-source and reconcile read it directly. The runtime helper still exists, but only for *write-time* path derivation; persisted records become self-describing.

### Why an enum-shaped setting, not a `Bool`

The deferred multi-layout picker (issue #38 commenter mentions `videos/YYYY/MM` and `YYYY/VIDEOS/MM`) would force a UserDefaults key rename if v1 stored a `Bool`. Storing `ExportVideoLayout: "flat" | "subfolder"` from day one lets v2 add cases without migration.

### Coexistence with PR #102 (Live Photos paired export)

PR #102 (merged 2026-05-21) added two new variants — `.originalPairedVideo` and `.editedPairedVideo` — gated by `livePhotosPairedExport`. A Live Photo's *asset* has `mediaType == .image` but its paired-video variant writes a `.MOV` file. Under option 2 the predicate keys on the *asset's* `mediaType`, so paired-video variants of an image asset naturally stay with their still in the base folder.

PR #102 also established the snapshot-at-enqueue pattern for export-shape settings (`ExportJob.livePhotosPaired`); this plan mirrors it for `videoLayout` so a mid-run toggle flip cannot split an in-flight asset's variants across directories.

## Implementation

### 1. New `ExportVideoLayout` enum

**New file:** `photo-export/Models/ExportVideoLayout.swift`

```swift
enum ExportVideoLayout: String, Codable, Sendable, CaseIterable {
  case flat        // photos and videos share the placement folder (today's default)
  case subfolder   // standalone videos go into a `videos/` subfolder inside the placement
}
```

### 2. `videoLayout` setting on `ExportManager`

**Edit:** `photo-export/Export/ExportManager.swift`

Mirror the `livePhotosPairedExport` pattern (lines 128–135, 473):

- Add `@Published var videoLayout: ExportVideoLayout` with a `didSet` that writes `UserDefaults` under `Self.videoLayoutDefaultsKey = "exportVideoLayout"` as `rawValue`. Default `.flat`.
- Initialize in `init` from `userDefaults.string(forKey:)` mapped via `ExportVideoLayout(rawValue:)`, defaulting to `.flat` for missing or unrecognized values.
- No `clearEmptyRunMessage()` and no push into record stores.
- Skip the AutoSync publisher (`livePhotosPairedExportPublisher` at line 195 exists because that toggle widens `requiredVariants`; this one does not). AutoSync-initiated exports honour the setting transitively via the `ExportJob` snapshot.

Add a docstring comment on the property explaining the intentional asymmetry with `convertHEICToJPEG`:

> Unlike `convertHEICToJPEG` — which pushes into both record stores so view-side `isExported` queries stay accurate — `videoLayout` does not widen `requiredVariants` (no asset becomes "incomplete" when toggled). Reconcile correctness instead rides on the per-variant `subfolder` field on `ExportVariantRecord`. Don't add a store push.

### 3. Snapshot `videoLayout` onto `ExportJob`

**Edit:** `photo-export/Export/ExportManager.swift:19-54` and every `ExportJob(...)` construction site

Mirror `livePhotosPaired` (line 35). Add:

```swift
struct ExportJob: Equatable {
  // ...existing fields...
  let livePhotosPaired: Bool
  let videoLayout: ExportVideoLayout    // NEW. Snapshotted at enqueue time.

  init(
    assetLocalIdentifier: String,
    placement: ExportPlacement,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool = false,
    videoLayout: ExportVideoLayout = .flat
  ) { ... }
}
```

Default `.flat` keeps call sites that haven't been threaded yet writing the old layout. Update every enqueue site (~6 — same lines as the `livePhotosPaired` snapshot block: 559, 575, 604, 614, 646, 669, 712, 730, 738, 763, 773) to read `let videoLayout = videoLayout` next to `let livePhotosPaired = livePhotosPairedExport` and pass it through.

Snapshot semantics: a flip *between* two `startExport*` clicks produces two differently-laid-out runs in the same destination (each snapshot is point-in-time). A flip *during* a single bulk-dispatcher's enqueue loop does not — the snapshot reads once before iterating. This matches `livePhotosPaired`; the "applies to new exports only" caption covers it.

### 4. Helper: `ExportPlacementPathPolicy`

**New file:** `photo-export/Export/ExportPlacementPathPolicy.swift`

```swift
enum ExportPlacementPathPolicy {
  /// The subfolder (relative to the placement) where every variant of an
  /// asset should land, given the asset's media type and the user's layout
  /// setting. Returns `nil` to mean "place directly in the placement folder."
  ///
  /// Keying on `descriptor.mediaType == .video` (rather than "the file
  /// being written is a video") means Live Photo paired motion stays with
  /// its still: a Live Photo asset has `mediaType == .image`, so all of its
  /// variants — including `.originalPairedVideo` / `.editedPairedVideo` —
  /// resolve to the bare placement path and remain auto-pairable on disk.
  /// Only `mediaType == .video` (standalone video assets) move to `videos/`.
  static func subfolder(
    for mediaType: PHAssetMediaType,
    layout: ExportVideoLayout
  ) -> String? {
    guard layout == .subfolder, mediaType == .video else { return nil }
    return "videos"
  }

  /// Full relative path used to construct `destDir` and the variant
  /// record's `relPath`. Always ends with `/`.
  static func relativePath(
    placement: ExportPlacement,
    subfolder: String?
  ) -> String {
    guard let subfolder, !subfolder.isEmpty else { return placement.relativePath }
    return placement.relativePath + subfolder + "/"
  }
}
```

`.audio` and `.unknown` fall through to `nil` — bare placement path regardless of layout.

### 5. Add `subfolder` to `ExportVariantRecord`

**Edit:** `photo-export/Models/ExportRecord.swift:13-18`

```swift
struct ExportVariantRecord: Codable, Equatable {
  var filename: String?
  var status: ExportStatus
  var exportDate: Date?
  var lastError: String?
  var subfolder: String?   // NEW. nil ⇒ bare placement path (today's default).
}
```

PR #102 did not modify this struct, so the field is a clean add. Synthesized `Codable` already tolerates missing keys; legacy records decode with `subfolder == nil`. Use `try container.encodeIfPresent(subfolder, forKey: .subfolder)` if the encoder writes nulls so on-disk JSONL stays minimal for the default case.

Add a regression test in `photo-exportTests/ExportRecordStoreTests.swift` AND `photo-exportTests/CollectionExportRecordStoreTests.swift` (both stores embed `ExportVariantRecord` via the same Codable through their respective `RecordBody`-style shapes): legacy snapshot without the field decodes; round-trip with `subfolder = "videos"` preserves the value.

Note: every variant of the same asset shares one `subfolder` value at write time (the helper keys on per-asset `mediaType`, not per-variant). Per-variant storage is still required because a mid-life toggle can produce an asset whose two variants were written under different layouts — e.g. `.original` of a standalone video written `.flat`, then `.edited` of the same video re-written under `.subfolder`. Storing `subfolder` per-variant lets reuse-source and reconcile probe each file's true location.

### 6. `runJob` chokepoint — single per-asset `destDir`

**Edit:** `photo-export/Export/ExportManager.swift:1739-1741`

The current shape is:

```swift
let destDir = try exportDestination.urlForRelativeDirectory(
  job.placement.relativePath, createIfNeeded: true)
let relPath = job.placement.relativePath
```

`destDir` is computed **once** per asset and threaded into every per-variant call (4 variants under PR #102's Live Photos pairing). Under option 2 the same per-asset model holds — image assets stay at base for all variants; standalone-video assets go to `videos/` for all variants. Replace with:

```swift
let subfolder = ExportPlacementPathPolicy.subfolder(
  for: descriptor.mediaType, layout: job.videoLayout)
let effectiveRelPath = ExportPlacementPathPolicy.relativePath(
  placement: job.placement, subfolder: subfolder)
let destDir = try exportDestination.urlForRelativeDirectory(
  effectiveRelPath, createIfNeeded: true)
let relPath = effectiveRelPath
```

Pass `subfolder` (the `String?`) through `exportSingleVariant` and `runEditedFallbackOriginal` so each writes `subfolder` onto its variant record alongside `filename`. The existing `relPath` parameter stays.

`ExportDestinationResolver.allocatePairedGroupStem` (~line 140) is **not** touched — image and paired-video slots for the same asset still share one `destDir`, which is what the allocator already assumes.

#### `existingRecord` synthesizer policy (mid-life toggle)

The synthesizer at ~lines 1758–1766 builds a synthetic `ExportRecord` for `inheritedGroupStem`, which probes the destination to recover a paired stem. Under mid-life toggle the asset's variants can carry different stored `subfolder` values. The policy is explicit:

**Use the subfolder for the *current target* layout** — i.e. `subfolder = ExportPlacementPathPolicy.subfolder(for: descriptor.mediaType, layout: job.videoLayout)`. That's the directory the next write will land in, so it's where stem inheritance matters. A stale-stem mismatch with an other-layout file already on disk is acceptable — that file is still self-describing via its own record's `subfolder`, and any future re-export of that variant will use its own stored subfolder for reuse/reconcile.

Add a regression test: standalone video asset has `.original` record with `subfolder = nil`, toggle now `.subfolder`, run `.edited`. Synthesizer feeds `subfolder = "videos"` to `inheritedGroupStem`; the new file lands in `videos/`; record stores `subfolder = "videos"` on the `.edited` variant; the `.original` record is left untouched at `subfolder = nil`.

### 7. Reuse-source: stored subfolder, not current setting

**Edit:** `photo-export/Records/RecordStoreRouter.swift:122-125` and `:135-164`

Extend `ReuseSource`:

```swift
struct ReuseSource: Equatable {
  let placement: ExportPlacement
  let filename: String
  let subfolder: String?    // NEW. Copied from variantRec.subfolder.
}
```

Populate `subfolder` from `variantRec.subfolder` in both lookup branches (timeline at lines 140–147 and collection at 150–162). Important: read `variantRec.subfolder` for the *specific variant being looked up*, not "the asset's first variant" — under mid-life toggle these can differ.

**Edit:** `photo-export/Export/VariantExporter.swift:200-213`

```swift
let sourceRelPath = ExportPlacementPathPolicy.relativePath(
  placement: reuse.placement, subfolder: reuse.subfolder)
let sourceURL = destinationRoot
  .appendingPathComponent(sourceRelPath, isDirectory: true)
  .appendingPathComponent(reuse.filename)
```

No `Host` protocol change. The mid-life-toggle case is correct: a standalone video written under `.flat` has `subfolder = nil` and is found at the bare path; a video written under `.subfolder` has `subfolder = "videos"` and is found in the subfolder, regardless of the current setting.

### 8. Reconcile: per-variant subfolder

**Edit:** `photo-export/Records/ExportRecordStore.swift` (timeline reconcile) and `photo-export/Records/CollectionExportRecordStore.swift` (collection reconcile at ~lines 408–493)

Where reconcile probes a variant's on-disk file, construct the probe URL via `ExportPlacementPathPolicy.relativePath(placement: <placement>, subfolder: variantRec.subfolder)` instead of using `placement.relativePath` (collection store) or `record.relPath` (timeline store). Each variant's existence check uses that variant's own on-disk location, fixing the shared-`relPath` bug a schema-free design would have caused.

### 9. Settings UI: new `Section("Organization")`

**Edit:** `photo-export/Views/Settings/AdvancedSettingsView.swift`

Current shape (post-PR #102): one `Section("Format")` containing `includeOriginalsRow`, `convertHEICToJPEGRow`, `livePhotosPairedRow`. Add a new section below it:

```swift
Section("Format") {
  includeOriginalsRow
  convertHEICToJPEGRow
  livePhotosPairedRow
}

Section("Organization") {
  videoLayoutRow
}
```

The new row mirrors the existing rows' shape (`Toggle { VStack { Text + caption } }.disabled(hasActiveExportWork)`):

```swift
private var videoLayoutRow: some View {
  Toggle(isOn: Binding(
    get: { exportManager.videoLayout == .subfolder },
    set: { exportManager.videoLayout = $0 ? .subfolder : .flat }
  )) {
    VStack(alignment: .leading, spacing: 4) {
      Text("Separate videos into a subfolder")
      Text(videoLayoutDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
  .disabled(exportManager.hasActiveExportWork)
}

private var videoLayoutDescription: String {
  "Off: photos and videos share each month or album folder.\n\n"
    + "On: videos go into a \"videos\" subfolder next to their photos. "
    + "The paired video of a Live Photo is an exception — it stays next to "
    + "its still so the pair isn't split across folders.\n\n"
    + "Applies to new exports only. Videos already on disk stay where they "
    + "are; turning this on later produces a mixed layout until you re-export."
}
```

No backticks (would render literally in `Text`). The "paired video of a Live Photo" wording reuses the term already established by the existing `livePhotosPairedRow` ("Export Live Photos as paired image + video"), so the Live Photo exemption reads as the same concept rather than new jargon. The single composed string keeps localization simple — do not adapt copy based on the Live Photos toggle's state.

Onboarding is unchanged.

#### `ExportInProgressBanner` copy generalization

The existing banner at ~lines 122–125 reads "Format options are locked while an export is running…". Once the Organization section ships, that's a lie. Generalize:

> Export settings are locked while an export is running. Cancel or wait for the current run to finish to change these.

### 10. BackupScanner: descend into `videos/` subfolders

**Edit:** `photo-export/Export/BackupScanner.swift:84-153`

The month-folder enumeration at ~line 121 is two-levels-deep (`rootURL → yearDir → monthDir → contentsOfDirectory(monthDir)`) and filters to `isRegularFile()`. PR #102 made the *classifier* paired-video-aware (step 5 at lines 555–592) but left enumeration flat.

Extend the inner loop: after enumerating the month folder, also enumerate the immediate `videos` child directory (if present) and emit those files as belonging to the same `(year, month)`. When the scanner synthesizes a record for a discovered file, set `subfolder = "videos"` on the variant if it came from the subfolder, else nil. The variant tag (`.original`, etc.) still comes from the existing classifier; only the enumeration changes.

The paired-video classifier (step 5) matches by stem within `(year, month)`, not within the same directory. That means a Live Photo whose still is at the base and whose paired motion sits in `videos/` (because a prior buggy build misrouted it, or because the user moved files manually) would still be paired by the classifier. Pin that behaviour explicitly in tests so any future "same-directory" tightening can't silently regress it (see §11).

#### Collection-side import — out of scope

Verified: `ImportCoordinator` only calls `BackupScanner.scanBackupFolder` on the timeline `YYYY/MM/` tree. There is **no** collection-side import path — `Collections/Albums/<x>/` and `Collections/Shared Albums/<x>/` files are silently invisible to Import Existing Backup today, regardless of any subfolder layout. `videos/` subfolders inside collection placements will inherit that same invisibility under this feature; that's not a regression. A future "Import collections" feature would need to extend the scanner with the same `videos/` descent.

### 11. Tests

Extend existing test files rather than creating parallels. PR #102 fixtures (`TestAssetFactory.makeAsset(isLivePhoto:)`, the `makeScannedFile` helper in `BackupScannerVariantTests.swift`, the `VariantExporter` harness) are the right seams.

**Important harness fact:** `VariantExporterTests` passes `destDir` directly into `exportSingleVariant`, bypassing the chokepoint computation. Therefore VariantExporter-level tests can only pin behavior that lives *inside* `exportSingleVariant` (reuse-source path construction, filename generation, write mechanics). Any assertion about "video lands in `videos/`" or "Live Photo motion lands at base" must live at `ExportManagerRunExportTests` level, where `runJob` computes `destDir` from the helper. The plan below splits the tests accordingly.

**Precondition — helper extension:** `BackupScannerVariantTests.makeScannedFile(filename:year:month:modDate:)` currently hardcodes `<year>/<month>/<filename>`. Extend it to accept an optional `subdir: String? = nil` so subfolder cases can drop in. This is a real code change to the helper, not just a parameter shuffle.

#### New file: `ExportPlacementPathPolicyTests.swift`

- `subfolder(for:layout:)`:
  - `.image` × `.flat` → nil
  - `.image` × `.subfolder` → nil
  - `.video` × `.flat` → nil
  - `.video` × `.subfolder` → `"videos"`
  - `.audio` × `.subfolder` → nil
  - `.unknown` × `.subfolder` → nil
- `relativePath(placement:subfolder:)` across all four placement kinds (timeline, favorites, album, sharedAlbum).

#### Augment `LivePhotoVariantTests.swift`

- `requiredVariants(..., livePhotosPaired:)` is byte-identical regardless of `videoLayout` (pins the "subfolder does not widen `requiredVariants`" invariant).
- Non-Live-Photo `.image` asset with `.subfolder` resolves to base regardless of `isLivePhoto` flag (regression guard against a future refactor mis-tagging the asset).

#### Augment `VariantExporterTests.swift` — reuse-source path construction only

- Reuse-source with `reuse.subfolder = "videos"`: source URL is `<root>/<placement>/videos/<filename>`.
- Reuse-source with `reuse.subfolder = nil`: source URL is `<root>/<placement>/<filename>` (bare).
- Reuse-source mid-life mismatch: `reuse.subfolder = nil` (source written under `.flat`), `destDir` injected as `<root>/<placement>/videos/`: copy runs from base to subfolder, target file lands at `<root>/<placement>/videos/<filename>`, new record stores `subfolder = "videos"`.

#### Augment `RecordStoreRouterTests.swift` — `findReuseSource` per-variant subfolder

- Asset has `.original` with `subfolder = nil` and `.edited` with `subfolder = "videos"`. `findReuseSource(... variant: .original, ...)` returns `subfolder = nil`. `findReuseSource(... variant: .edited, ...)` returns `subfolder = "videos"`. Pins per-variant correctness against an "asset's first variant" regression.

#### Augment `ExportManagerRunExportTests.swift` — chokepoint and end-to-end

These are the assertions that exercise the `runJob` destDir computation, which `VariantExporterTests` cannot reach:

- End-to-end happy path: mixed-month with `videoLayout = .subfolder`, Live Photos paired on. Photo at `2026/03/X.JPG`, standalone video at `2026/03/videos/X.MOV`, Live Photo still at `2026/03/Y.HEIC`, Live Photo paired motion at `2026/03/Y.MOV` (NOT in `videos/`). Variant records carry the correct `subfolder` values: nil for image-asset variants (including paired motion), `"videos"` for standalone-video variants.
- Standalone video with `.subfolder` writes to `videos/`; variant records carry `subfolder = "videos"`.
- Audio / `.unknown` mediaType with `.subfolder`: bare placement path; variant records carry `subfolder = nil`.
- Live Photo with `.subfolder` + Include Originals + adjustments: all four files (`.HEIC`, `_orig.HEIC`, `.MOV`, `_orig.MOV`) at base; `videos/` is empty (or doesn't exist).
- Edited Live Photo asymmetric resources (still has `hasAdjustments == true` but resource set lacks `.fullSizePairedVideo` so `.editedPairedVideo` falls back to `.pairedVideo`): under `.subfolder`, all variants resolve to base regardless of the asymmetric shape.
- Standalone video edited-fallback (`runEditedFallbackOriginal`) under `.subfolder`: `_orig.MOV` companion lands in `videos/` and persists `subfolder = "videos"`.
- Standalone video edited + original under `.subfolder`: both `<stem>.MOV` and `<stem>_orig.MOV` share the same `videos/` `destDir`; no collision suffix.
- Mid-life same-placement re-run on a standalone video (no relocation, no double-write): export with `.flat`; flip to `.subfolder`; re-run the same month. Asset is already `.done`, `requiredVariants` unchanged → skip. Assert no second file at `2026/03/videos/X.MOV`, record's `subfolder` is unchanged (nil).
- Mid-life synthesizer policy: standalone video has `.original` record with `subfolder = nil`; toggle `.subfolder`; run `.edited`. Assert `.edited` lands in `videos/`, `.edited` record `subfolder = "videos"`, `.original` record untouched at `subfolder = nil`.
- AutoSync standalone video with `.subfolder`: AutoSync-context run writes a standalone video to the subfolder. No publisher wiring needed.
- AutoSync Live Photo with `.subfolder`: AutoSync-context run with Live Photos paired on writes the paired motion at base alongside the still. Pins the Live Photo carve-out under AutoSync.
- Shared album with `.subfolder`: mixed photo + standalone video → photo at `Collections/Shared Albums/<title>/X.HEIC`, video at `Collections/Shared Albums/<title>/videos/X.MOV`.
- Cross-placement reuse: standalone video stored in placement A with `subfolder = "videos"` is copied from `A/videos/X.MOV` to B regardless of B's current `videoLayout` (target subfolder computed from current setting; source subfolder read from record).
- Multi-destination invariance (nice-to-have): two destinations, toggle on, export the same month into both → both layouts identical, both record stores have matching `subfolder` values per variant.

#### Augment `ExportManagerRunExportTests.swift` — reconcile

- Reconcile of a Live Photo asset under `.subfolder`: variant records carry `subfolder = nil` (correct); reconcile probes base for both still and paired motion; both found; nothing pruned. Pins that the per-variant `subfolder` field is consulted correctly across the carve-out.

#### Augment `BackupScannerVariantTests.swift`

- `videos/` subfolder files discovered, attributed to the parent month, emitted with `subfolder = "videos"` on the synthesized variant.
- Cross-directory Live Photo pairing: `IMG.HEIC` at base + `IMG.MOV` in `videos/` (same stem, same month). Classifier pairs them as `.original` + `.originalPairedVideo` (since it matches by stem within the `(year, month)`, not within the same directory); the `.MOV` variant carries `subfolder = "videos"` and the `.HEIC` variant carries `subfolder = nil`. Pinning this behavior prevents silent re-export-as-duplicate under a "toggle on, re-import" flow.
- `videos/` subfolder with non-PhotoKit files (user dropped junk): scanned, no PhotoKit match, no record created.
- A Live Photo's paired motion file that the user *moved* into `videos/` manually: classifier still tags it as `.originalPairedVideo` via the existing paired-video stem rules; record carries `subfolder = "videos"`.

#### Augment `ExportRecordStoreTests.swift` and `CollectionExportRecordStoreTests.swift`

- Legacy snapshot without `subfolder` decodes; `variantRec.subfolder == nil`.
- Round-trip with `subfolder = "videos"` preserves value.
- (Required in both stores — both embed `ExportVariantRecord` via the same Codable.)

#### Augment `ExportDestinationResolverTests.swift`

- (No changes to `allocatePairedGroupStem` API.) Pin one new case: standalone-video edited + original under `.subfolder` — both `<stem>.MOV` and `<stem>_orig.MOV` share the same `videos/` `destDir`, the existing allocator handles them with no new code, no spurious `_2` suffix.

### 12. Documentation

- **`README.md`** — extend the Settings → Advanced section (post-PR #102 has three bullets) with one line for the new option.
- **`website/src/content/docs/features.md`** — add a new subsection alongside Include Originals, Convert HEIC to JPEG, and Live Photos Paired Export (~10–15 lines), including: the "applies to new exports only" caveat, the "Live Photo paired motion stays with its still" detail, and a note that an edited standalone video's `_orig.MOV` companion *also* lands in `videos/` under Include Originals (so the user isn't surprised).
- **`photo-export/Models/ReleaseNotesCatalog.swift`** — add a release-note entry for the new version.

## Out of scope

- Multi-layout picker (`videos/YYYY/MM`, `YYYY/VIDEOS/MM`, etc.). The enum-shaped `ExportVideoLayout` plus per-variant `subfolder` field accommodate it later by adding cases and widening `ExportPlacementPathPolicy`; no further schema change.
- Migrating already-exported videos into the subfolder. By design; matches the HEIC-toggle and Live Photos-toggle precedent.
- AutoSync publisher / reducer event for `videoLayout`. Not needed because the setting does not widen `requiredVariants`; AutoSync runs honour it transitively via the `ExportJob` snapshot.
- Collection-side Import Existing Backup. Pre-existing gap; not a regression.

## Critical files

- `photo-export/Models/ExportVideoLayout.swift` (new)
- `photo-export/Models/ExportRecord.swift` (add `subfolder` to `ExportVariantRecord`)
- `photo-export/Export/ExportPlacementPathPolicy.swift` (new)
- `photo-export/Export/ExportManager.swift` (setting, `ExportJob.videoLayout`, single per-asset `destDir` via helper, synthesizer policy, every enqueue site)
- `photo-export/Export/VariantExporter.swift` (reuse-source uses stored `subfolder`)
- `photo-export/Export/BackupScanner.swift` (descend into `videos/`)
- `photo-export/Records/RecordStoreRouter.swift` (`ReuseSource.subfolder`)
- `photo-export/Records/ExportRecordStore.swift`, `CollectionExportRecordStore.swift` (reconcile per-variant subfolder)
- `photo-export/Views/Settings/AdvancedSettingsView.swift` (new `Section("Organization")` + banner copy generalization)
- `photo-exportTests/ExportPlacementPathPolicyTests.swift` (new)
- `photo-exportTests/LivePhotoVariantTests.swift`, `VariantExporterTests.swift`, `RecordStoreRouterTests.swift`, `ExportDestinationResolverTests.swift`, `BackupScannerVariantTests.swift`, `ExportManagerRunExportTests.swift`, `ExportRecordStoreTests.swift`, `CollectionExportRecordStoreTests.swift` (augment)
- `photo-exportTests/BackupScannerVariantTests.swift` `makeScannedFile` helper (extend with optional `subdir`)
- `README.md`, `website/src/content/docs/features.md`, `photo-export/Models/ReleaseNotesCatalog.swift`

## Verification

1. `swiftlint --strict --cache-path build/swiftlint-cache` — no new violations.
2. `swift-format lint --recursive photo-export` — clean.
3. `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test` — all tests pass.
4. Grep gate: `rg "placement\.relativePath" photo-export/Export photo-export/Records` should show only the helper itself and intentional callers — no remaining direct use in the variant write or reconcile paths.
5. Grep gate (regression-risk audit): `rg -l "videoLayout: \.subfolder" photo-exportTests` to find any test that explicitly opts into the subfolder layout, then spot-check those for hardcoded `destDir` URL strings (e.g. `"2025/07/"`) — confirm none have an implicit `mediaType == .video` asset whose expected path was hand-built against the bare placement.
6. Manual smoke in the running app:
   - Open Settings → Advanced. Confirm `Format` (three rows) and `Organization` (one row) sections render; toggle "Separate videos into a subfolder" on.
   - With Live Photos paired export on, export a month containing standalone photos, standalone videos, and Live Photos. Verify on disk: `<dest>/<YYYY>/<MM>/<photo>.JPG`, `<dest>/<YYYY>/<MM>/videos/<video>.MOV`, `<dest>/<YYYY>/<MM>/<livephoto>.HEIC` **and** `<dest>/<YYYY>/<MM>/<livephoto>.MOV` (same directory — Live Photo motion is NOT in the subfolder).
   - Edited standalone video: pick a month with an edited video where Photos has only original bytes; verify the `_orig.MOV` companion lands in `videos/`.
   - Edited Live Photo with "Include originals" on: verify all four files (`.HEIC`, `_orig.HEIC`, `.MOV`, `_orig.MOV`) live at the base placement path. `ls 2026/03/videos/` should be empty of any `*_orig.MOV` from the Live Photo.
   - Toggle off; re-run the same month. Verify no files were relocated, no duplicates created.
   - Toggle off; export an album containing standalone videos. Verify videos land at `Collections/Albums/<name>/<video>.MOV` (flat, regardless of the just-flipped setting).
   - Mid-life flip: export a standalone video with toggle off, flip to on, run a *different* placement that includes the same asset. Verify the reuse copies from the bare path of the source and writes to the subfolder of the target.
   - Mid-life synthesizer: export `.original` of a standalone video under `.flat`; flip to `.subfolder`; trigger a re-export that includes `.edited`. Verify `.edited` lands in `videos/`, `.original` file stays at base, records reflect the split (`.original.subfolder = nil`, `.edited.subfolder = "videos"`).
   - Import Existing Backup: run an export with toggle ON, then delete the local app's record stores (or run on a fresh install), then run Import Existing Backup against the destination. Verify standalone videos in `videos/` are recognized as already-exported.
7. After the manual smoke, inspect both record stores:
   - **`export-records.jsonl`** (timeline): confirm `subfolder` is present (and equal to `"videos"`) on variant records of standalone-video assets that were written into the subfolder, and absent (or null) on variants of image assets — including Live Photo paired motion.
   - **Collection records** (under the collection-store directory): same audit on a mixed-media album. The collection store's reconcile/reuse paths are the most likely place for a stale-`subfolder` regression to hide.
