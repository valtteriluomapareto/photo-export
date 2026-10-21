# Support Edited Photo Exports

Status: Superseded by the shipped
[two-mode redesign](edited-photos-modes-redesign-plan.md). Archived as the original
three-mode design record; its filenames, UI modes and “current behavior” sections
describe the pre-redesign app.

Date: 2026-04-24
Issue: https://github.com/valtteriluomapareto/photo-export/issues/13

## Goal

Support exporting Photos assets as originals, edited/current versions, or both.

Filename contract:

- Original exports keep the Photos original filename unchanged: `IMG_0001.JPG`.
- Edited/current exports use the original resource basename plus `_edited`, but the extension comes
  from the edited resource bytes: `IMG_0001_edited.JPG`.
- If the original is HEIC and Photos renders the edited resource as JPEG, export
  `IMG_0001_edited.JPG`, not `IMG_0001_edited.HEIC`.

Backup import must recognize original and edited files and rebuild per-variant export state.

## Current Behavior

The export pipeline currently writes one resource per `PHAsset.localIdentifier`.

- `ExportManager` asks `PhotoLibraryService.resources(for:)` for `ResourceDescriptor` values.
- `selectPrimaryResource(from:)` prefers `.photo` and `.video` before `.fullSizePhoto`.
- `ProductionAssetResourceWriter` resolves the descriptor back to `PHAssetResource` and writes it with
  `PHAssetResourceManager.writeData`.
- `ExportRecordStore` stores one `ExportRecord` per Photos asset id, with a single `filename` and
  `status`.

This means the app currently treats "asset exported" as one completed file.

## PhotoKit Decisions

PhotoKit normally exposes one current edited/rendered version plus the original. It does not expose a
history of multiple edited snapshots for a single `PHAsset`.

The canonical edited gate for this feature is `PHAsset.hasAdjustments`.

- Add `hasAdjustments: Bool` to `AssetDescriptor`.
- Set it from `PHAsset.hasAdjustments` in `PhotoLibraryManager.descriptor(from:)`.
- Test fakes and factories must include it.
- Do not infer edited availability from `.fullSizePhoto` or `.fullSizeVideo` alone.

Resource presence is still needed to choose what bytes to write, but it is not sufficient to decide
whether an asset should produce an `_edited` export.

Edited export rules:

- If `asset.hasAdjustments == false`, edited export is not applicable.
- If `asset.hasAdjustments == true` but no edited resource can be selected, record the edited variant
  as failed with a clear "Edited resource unavailable" error. Do not fall back to original bytes.
- For videos, the first implementation uses `.fullSizeVideo` through the existing resource writer.
  `requestExportSession` remains a possible future refinement if resource export proves insufficient.

Relevant resource categories:

- `.photo` / `.video`: original media data.
- `.fullSizePhoto` / `.fullSizeVideo`: current rendered media data.
- `.adjustmentData`: edit instructions, not an export target for this issue.
- `.adjustmentBasePhoto` / `.adjustmentBaseVideo`: base data used to reconstruct edits, not an export
  target for this issue.
- Live Photo paired video and RAW/JPEG policy stay out of scope unless current behavior would regress.

## Terminology

Use `variant` in code and persistence. Use `version` only in user-facing copy if it reads better.

```swift
enum ExportVariant: String, Codable, CaseIterable, Hashable, Sendable {
  case original
  case edited
}

enum ExportVersionSelection: String, Codable, CaseIterable, Sendable {
  case originalOnly
  case editedOnly
  case originalAndEdited
}
```

Required variants are asset-dependent because edited export is only applicable when
`hasAdjustments == true`.

```swift
func requiredVariants(for asset: AssetDescriptor, selection: ExportVersionSelection)
  -> Set<ExportVariant>
{
  switch selection {
  case .originalOnly:
    return [.original]
  case .editedOnly:
    return asset.hasAdjustments ? [.edited] : []
  case .originalAndEdited:
    return asset.hasAdjustments ? [.original, .edited] : [.original]
  }
}
```

Default selection is `originalOnly` to preserve current behavior.

## Export Status

Do not add a `skipped` status in the first implementation.

Not-applicable variants are represented by eligibility, not persistence:

- If `asset.hasAdjustments == false`, the edited variant is not required.
- In `editedOnly`, unedited assets are filtered out and do not create records.
- In `originalAndEdited`, unedited assets require only the original variant.

Completion rules:

- `.done` satisfies a required variant.
- `.failed`, `.pending`, and `.inProgress` do not satisfy export completion.
- If an asset later gains edits in Photos, `requiredVariants(for:selection:)` starts requiring
  `.edited`; there is no stale skipped record to invalidate.

## Export Records

The current `ExportRecord` shape is too narrow for "both" because it has only one `filename` and one
`status`.

Use one record per Photos asset id, with variant state keyed by `ExportVariant`. A dictionary prevents
duplicate state for the same variant.

```swift
struct ExportVariantRecord: Codable, Equatable {
  var filename: String?
  var status: ExportStatus
  var exportDate: Date?
  var lastError: String?
}

struct ExportRecord: Codable, Equatable {
  let id: String
  var year: Int
  var month: Int
  var relPath: String

  // Canonical state. Custom Codable encodes keys as "original" / "edited".
  var variants: [ExportVariant: ExportVariantRecord] = [:]
}
```

Implement custom `Codable` for `ExportRecord`:

- Decode `variants` when present.
- If `variants` is missing or empty, synthesize an `.original` variant from legacy `filename`,
  `status`, `exportDate`, and `lastError` fields.
- Decode legacy snapshots and JSONL mutations without crashing.
- Encode only the new schema. Legacy fields are dropped on the next write/compaction.

Legacy migration details:

- Legacy `.done` becomes `.original` done.
- Legacy `.failed` becomes `.original` failed.
- Legacy `.pending` becomes `.original` pending.
- Legacy `.inProgress` becomes `.original` failed with an "Interrupted before completion" style
  message. It remains eligible for a later export retry because only `.done` satisfies completion.
- For both legacy and new-schema records, any variant loaded as `.inProgress` must be converted to
  `.failed` with the same interrupted message during load. No in-progress state survives app restart.
- `.pending` on load is preserved as-is. It does not satisfy completion (line above) and enqueue
  treats any non-`.done` required variant as incomplete, so a surviving `.pending` will be retried on
  the next export run without an explicit reset.

Variant mutation APIs:

- `markVariantInProgress(assetId:variant:year:month:relPath:filename:)`
- `markVariantExported(assetId:variant:year:month:relPath:filename:exportedAt:)`
- `markVariantFailed(assetId:variant:error:at:)`
- `removeVariant(assetId:variant:)`

If `removeVariant` leaves a record with no variants, remove the asset record.

Read-side API:

- Keep `exportInfo(assetId:) -> ExportRecord?` as the main read API.
- Callers inspect `record.variants[.original]` and `record.variants[.edited]` for variant-specific
  UI state rather than adding duplicate read methods.

Keep compatibility wrappers only where call sites still need them during migration, and route those
wrappers to `.original`.

Invariant for future cache optimizations: any variant count cache must update on every variant
upsert and subtract on `removeVariant`. The first implementation avoids this risk by recomputing
summaries on demand.

## Summary and Cache Semantics

Current `doneCountByYearMonth` is not sufficient because completion depends on the active selection
and `AssetDescriptor.hasAdjustments`.

Replace the single done-count cache with summary recomputation over `recordsById` for the requested
month/year. Add per-variant caches later only if profiling shows a real bottleneck; they must not be
the source of truth.

Correctness must come from a completion evaluator that receives current asset eligibility:

```swift
func isExported(asset: AssetDescriptor, selection: ExportVersionSelection) -> Bool
func monthSummary(assets: [AssetDescriptor], selection: ExportVersionSelection) -> MonthStatusSummary
```

Sidebar rows that do not already hold month assets need an eligibility source. `PHAsset.hasAdjustments`
is not a Photos fetch predicate, so adjusted counts are not cheap server-side counts. Add lazy cached
adjusted-count methods to `PhotoLibraryService`; they fetch and iterate assets once per year/month and
cache the result.

- `countAdjustedAssets(year:month:)`
- `countAdjustedAssets(year:)`

Cache invalidation:

- Clear adjusted-count caches in `PhotoLibraryManager.photoLibraryDidChange`.
- Clear them when authorization state changes.
- Month rows may show a neutral/loading state until their adjusted count is available.
- `photoLibraryDidChange` is the single source of truth for mid-session Photos edit changes. Destination
  changes do not invalidate adjusted counts because they do not change library metadata.

For selected month content, use the loaded `[AssetDescriptor]` from `MonthViewModel`.

Summary behavior:

- `originalOnly`: total is all assets.
- `editedOnly`: total is adjusted assets only. Unedited assets do not appear as missing work.
- `originalAndEdited`: total is all assets. For adjusted assets, both variants are required. For
  unedited assets, original is enough.

`MonthStatusSummary` keeps its existing shape. `exportedCount` is the number of assets whose
`requiredVariants(for:selection:)` are all `.done`; `totalCount` follows the rules above. Both are
asset-counts, not file-counts, consistent with the asset-based progress tradeoff in the UX section.

## Export Pipeline

Keep `ExportJob` asset-based for the first implementation. The job exports all variants required by
the active selection for that asset.

The enqueue step should filter with current asset eligibility:

- Do not enqueue unedited assets in `editedOnly`.
- In `originalAndEdited`, enqueue an asset if any required variant is incomplete.
- If an asset gains edits after a previous original-only export, `hasAdjustments == true` makes the
  edited variant newly required when the active selection includes edited output.

This keeps queue counts closer to user-visible work and avoids filling the queue with unedited assets
in edited-only mode.

Resource selection helpers:

```swift
func selectOriginalResource(from resources: [ResourceDescriptor], mediaType: PHAssetMediaType)
  -> ResourceDescriptor?

func selectEditedResource(from resources: [ResourceDescriptor], mediaType: PHAssetMediaType)
  -> ResourceDescriptor?
```

Original selection must preserve current behavior unless a case is intentionally changed:

- Prefer `.photo`.
- Prefer `.video`.
- Preserve `.alternatePhoto` fallback.
- Preserve existing last-resort fallback where needed for current exports, but do not let edited
  resource types take priority over original resource types for original export.

Edited selection:

- Gate first on `asset.hasAdjustments`.
- Image: prefer `.fullSizePhoto`.
- Video: prefer `.fullSizeVideo`.
- Do not fall back to `.photo`, `.video`, or `.alternatePhoto`.

For each selected variant:

- Resolve the resource.
- Generate the final filename through `ExportFilenamePolicy`.
- Write to a variant-specific `.tmp` file.
- Move atomically to the final location.
- Apply timestamps from the asset creation date.
- Mark only that variant as exported.
- On export start, remove stale `.tmp` sibling files for the target variant filename. This covers
  crash leftovers that the normal in-task defer cannot clean up.

Failure behavior:

- If original succeeds and edited fails, original remains done and edited becomes failed.
- A failed edited variant does not roll back a completed original variant.
- Missing edited resource on an adjusted asset is a failed edited variant, not skipped.

Cancellation behavior:

- Track `inProgressVariant` in addition to `currentJobAssetId`.
- On cancellation, remove/reset only the in-progress variant for the current generation.
- Never call `exportRecordStore.remove(assetId:)` for a multi-variant cancellation after any variant
  may have completed.
- If original completed and edited is cancelled, the original variant remains done.
- Clean up only the active variant temp file in the active variant defer.

## Filename Policy

Create one shared helper used by export and backup import.

```swift
struct ParsedEditedFilename: Equatable {
  var groupStem: String
  var canonicalOriginalStem: String
  var fileCollisionSuffix: Int?
  var fileExtension: String
}

enum ExportFilenameClassification: Equatable {
  case original(filename: String, fileCollisionSuffix: Int?)
  case edited(ParsedEditedFilename)
}

enum ExportFilenamePolicy {
  static let editedSuffix = "_edited"

  static func originalFilename(for originalResourceFilename: String) -> String

  static func editedFilename(
    originalGroupStem: String,
    editedResourceFilename: String
  ) -> String

  static func parseEditedCandidate(filename: String) -> ParsedEditedFilename?
}
```

Definitions:

- `canonicalOriginalStem`: original resource stem without app-added collision suffixes.
- `groupStem`: the stem used to tie variants for one exported asset together. It may include an
  app-added collision suffix, for example `IMG_0001 (1)`.
- `fileCollisionSuffix`: a final suffix added because the exact variant filename already existed,
  for example `IMG_0001_edited (1).JPG`.

Output rules:

- Original filename starts from the original resource filename.
- Edited basename starts from the selected `groupStem`, not from the edited resource filename.
- Edited extension comes from the edited resource filename, because it describes the bytes being
  written.
- Extension casing follows the selected resource filename for that variant.

Examples:

```text
Original resource: IMG_0001.HEIC
Edited resource:   IMG_E0001.JPG
Original export:   IMG_0001.HEIC
Edited export:     IMG_0001_edited.JPG
```

```text
First asset original: IMG_0001.JPG
First asset edited:   IMG_0001_edited.JPG
Second asset original collision: IMG_0001 (1).JPG
Second asset edited companion:   IMG_0001 (1)_edited.JPG
```

```text
Edited companion already exists:
IMG_0001_edited.JPG
IMG_0001_edited (1).JPG
```

Collision algorithm:

0. If the asset already has a `.done` original variant record, its recorded filename stem is the
   group stem. Reuse it for edited export in every mode. This preserves pairing after a prior
   original-only run.
1. If the asset has no done original record but does have a `.done` edited variant record, parse the
   edited filename and use its recorded `groupStem` for later original export. The original filename
   becomes `groupStem + originalResourceExtension`. If that exact original path now exists on disk,
   fail the original variant with a clear error rather than silently splitting the pair across
   unrelated stems or overwriting another asset's file.
2. Resolve a variant group stem at export start, immediately before writing the asset's variants. The
   current pipeline is sequential, so the filesystem already reflects prior jobs in the same batch.
3. For `originalOnly` and `originalAndEdited`, when no done variant record supplies a group stem, the
   group stem is the final original filename stem after original collision resolution.
4. For `editedOnly`, when no done variant record supplies a group stem, allocate a group stem from the
   original resource stem using the same collision sequence, considering both existing original files
   and existing edited files with the same group stem.
5. Build the edited filename from `groupStem + "_edited" + editedResourceExtension`.
6. Apply final per-file collision resolution to the edited filename if that exact edited file already
   exists.

No in-memory group-stem reservation set is needed while exports remain sequential. If concurrent
export is added later, group-stem allocation must become reservation-backed or otherwise atomic.

Export should emit `IMG_0001 (1)_edited.JPG` as the companion for an original that exported as
`IMG_0001 (1).JPG`. The scanner must recognize that form.

## User Experience

Add a compact export version picker in the toolbar near the export actions.

Options:

- Originals
- Edited versions
- Originals + edited versions

Default:

- Originals

Persistence:

- Store the selection globally in app settings, likely `@AppStorage`. It is intentionally not scoped
  per destination for this issue; changing that later would be a separate product decision.

Toolbar behavior:

- Keep the primary export buttons simple.
- Help text should mention the active export mode.
- Progress should remain asset-based in the first implementation, with current filename showing the
  active file being written.
- Tradeoff: in `originalAndEdited`, `3/10` means three assets completed even though up to six files may
  have been written. This is acceptable for now because sidebar state is asset-based. Revisit if users
  find it confusing.

Asset detail view:

- Show edit availability using `AssetDescriptor.hasAdjustments`.
- Wording:
  - `Edited version: Available`
  - `Edited version: No edits`
- If an adjusted asset fails because no edited resource can be selected, show that export failure in
  the existing export status area.

Missing edited version:

- Unedited assets are filtered out of `editedOnly` work.
- In `originalAndEdited`, unedited assets require only the original variant.
- The app must not create `_edited` duplicates from original bytes.

## Backup Import / Library Scan

Extend scanner output to include the matched variant.

```swift
struct MatchResult {
  var matched: [MatchedExportFile] = []
  var ambiguous: [ScannedFile] = []
  var unmatched: [ScannedFile] = []
}

struct MatchedExportFile {
  var file: ScannedFile
  var asset: AssetDescriptor
  var variant: ExportVariant
  var filenameClassification: ExportFilenameClassification
}
```

Update `AssetFingerprint`:

- Include `hasAdjustments`.
- Split original-resource filenames from edited-resource filenames.
- Keep original resource stems for cross-extension edited matching.
- Keep edited resource extensions when available for stronger matching.
- Build the split using the same resource classification helpers as export. Extract shared
  predicates/classifiers under the resource-selection helpers so backup matching and export cannot
  disagree about original-side vs edited-side resources.

Migrate `MatchResult.matched` from the current tuple shape
`[(file: ScannedFile, asset: AssetDescriptor)]` to `[MatchedExportFile]`. Import code must consume
the variant from `MatchedExportFile`.

Filename matching responsibility:

- `ExportFilenamePolicy.parseEditedCandidate(filename:)` is pure filename parsing only. It strips a
  final file collision suffix, detects `_edited`, derives `groupStem`, derives
  `canonicalOriginalStem`, and returns nil if the filename is not an edited-form candidate.
- `BackupScanner` owns candidate-aware classification because it has the fingerprint data.

Scanner classification order:

1. If the file exactly matches a known original resource filename, classify it as original.
2. If the file with a final collision suffix stripped matches a known original resource filename,
   classify it as original.
3. Otherwise, call `ExportFilenamePolicy.parseEditedCandidate(filename:)`.
4. Classify as edited only if `canonicalOriginalStem` matches a known original resource stem for the
   candidate asset. This prevents arbitrary original filenames containing `_edited` from being
   misclassified.

Edited matching:

- Candidate assets must have `hasAdjustments == true`.
- Match edited files by original resource stem, not by edited resource basename. This supports
  `IMG_0001.HEIC` original plus `IMG_0001_edited.JPG` edited export.
- The edited file extension may differ from the original extension.
- If edited resource extensions are available, use them as a strong filter. If extension data is not
  available or is inconclusive, fall back to date/dimension/duration discriminators.

Pairing:

- The scanner does not rely on pairing original and edited files before matching. Each file must match
  exactly one asset on its own.
- When both files match the same asset, import marks both variants done.
- If duplicate original filenames make an edited file ambiguous, leave it ambiguous. Do not guess from
  filename alone.

Import merge rules:

- `bulkImportRecords` must merge per variant.
- Importing edited for an asset whose original is already done adds the edited variant.
- Importing original for an asset whose edited is already done adds the original variant.
- Existing `.done` for the same asset and variant wins; skip that variant.
- Existing `.failed`, `.pending`, or `.inProgress` may be replaced by an imported `.done` variant.
- Import matched counts remain asset-based for the high-level report. Optional detail counts may show
  original files and edited files separately.

## Call-Site Inventory

Update every current asset-level exported check.

- `ExportManager.enqueueMonth`: use `isExported(asset:selection:)` and `requiredVariants`.
- `ExportManager.enqueueYear`: same as month.
- `ExportManager.cancelAndClear`: remove only current in-progress variant.
- `ExportManager.export(job:)`: write all missing required variants, not one selected resource.
- `ExportRecordStore.bulkImportRecords`: merge by variant instead of skipping whole asset records.
- `MonthContentView` thumbnails: use selection-aware exported state.
- `MonthContentView` summary: pass loaded assets and current selection.
- `ContentView.YearRow` / `MonthRow`: use selection-aware summaries and adjusted counts.
- `AssetDetailView`: display variant-aware export state.
- Tests and fakes: include `hasAdjustments` and variant records.

## Documentation

Update user-visible and maintainer docs as part of implementation.

Root README:

- Mention originals, edited versions, and both.
- Document `_edited` filename convention.
- Mention that edited export only applies to assets with Photos edits.

Website docs:

- `website/src/content/docs/features.md`
  - Add export mode support.
  - Note `_edited` naming.
- `website/src/content/docs/export-icloud-photos.md`
  - Clarify original exports keep original filenames.
  - Clarify edited exports produce current Photos edits with `_edited` suffix.
  - Mention that edited output extension may differ when Photos renders the edit in another format.
- `website/src/content/docs/getting-started.md`
  - Mention the toolbar export version picker.
- `website/src/content/docs/architecture.md`
  - Update export record and scanner descriptions for variant-aware state.
- `website/src/content/docs/roadmap.md`
  - Remove or adjust any roadmap item that duplicates this shipped feature.

Maintainer/reference docs:

- `docs/reference/persistence-store.md`
  - Document per-variant export state and legacy migration.
- `docs/reference/swift-swiftui-best-practices.md`
  - Update export guidance if resource selection changes.

## Testing Plan

### Export Pipeline Tests

Add or update tests in `ExportPipelineTests`.

- Original-only preserves current behavior and filename.
- Edited-only writes `_edited` filename for `hasAdjustments == true`.
- Edited-only does not enqueue unedited assets.
- Assets that gain edits after an original-only export become eligible for edited export.
- Original + edited writes two files for one adjusted asset.
- Original + edited writes only original for one unedited asset.
- HEIC original plus JPEG edited resource exports `_edited.JPG`.
- Duplicate original basenames produce paired group stems:
  - `IMG_0001.JPG`
  - `IMG_0001_edited.JPG`
  - `IMG_0001 (1).JPG`
  - `IMG_0001 (1)_edited.JPG`
- Original succeeds and edited fails: original remains done, edited is failed.
- Cancel during edited variant cleans up temp file and preserves completed original state.
- Switching selection from original-only to original-and-edited enqueues only missing edited variants
  for adjusted assets.
- Pair-preserving re-export after collisions:
  - Asset A exports original as `IMG_0001.JPG`.
  - Asset B exports original as `IMG_0001 (1).JPG`.
  - Switching to original-and-edited exports Asset B's edited companion as
    `IMG_0001 (1)_edited.JPG`, not `IMG_0001_edited (1).JPG`.
- Symmetric pair preservation:
  - Asset B first exports edited-only as `IMG_0001 (1)_edited.JPG`.
  - Switching to original-and-edited exports Asset B's original as `IMG_0001 (1).JPG`.
- Step-1 fail-path guard:
  - Asset B exports edited-only as `IMG_0001 (1)_edited.JPG`.
  - Asset C separately exports original as `IMG_0001 (1).JPG`, taking the stem.
  - Switching to original-and-edited for Asset B fails Asset B's original variant with a clear
    error instead of overwriting Asset C's file or re-allocating a new stem that splits the pair.
- Stale `.tmp` cleanup at export start:
  - Seed an `IMG_0001.JPG.tmp` sibling in the destination before export.
  - Run export for that asset and verify the stale tmp is removed before the new write begins.
- Resource selection:
  - Original prefers `.photo` over `.fullSizePhoto`.
  - Original preserves `.alternatePhoto` fallback.
  - Edited prefers `.fullSizePhoto` and does not fall back to `.photo`.
  - Video original prefers `.video`.
  - Video edited prefers `.fullSizeVideo`.

### Export Record Store Tests

Add or update tests in `ExportRecordStoreTests` and recovery tests.

- Legacy `.done` decodes as original done.
- Legacy `.failed` decodes as original failed.
- Legacy `.inProgress` recovers to non-active state.
- New-schema variant stored as `.inProgress` recovers to `.failed` with the interrupted message on
  next load.
- New records encode only variant schema.
- Duplicate variant state cannot be represented.
- Variant-specific mark APIs update only one variant.
- `isExported(asset:selection:)` respects `hasAdjustments`.
- Month summary remains asset-based and selection-aware.
- Snapshot and JSONL recovery preserve variant data.
- Bulk import merges edited into an asset with existing original.
- Bulk import merges original into an asset with existing edited.

### Backup Scanner Tests

Add tests in `BackupScannerTests` / matching tests.

- Detect original file.
- Detect edited file with `_edited`.
- Detect both original and edited for one asset.
- Match `IMG_0001_edited.JPG` to original `IMG_0001.HEIC` when the edited resource is JPEG.
- Do not treat arbitrary `_edited` in a true original filename as edited when it matches an original
  resource filename.
- Preserve collision behavior for `IMG_0001 (1).JPG`.
- Recognize `IMG_0001 (1)_edited.JPG` as edited companion form.
- Recognize `IMG_0001_edited (1).JPG` as a final edited-file collision.
- Keep ambiguous duplicate original filenames ambiguous.
- Import matched original and edited files into separate variants for the same asset.

### UI and Summary Tests

- Edited-only month with mostly unedited assets completes when all adjusted assets are exported.
- Original-and-edited month completes when unedited assets have originals and adjusted assets have both
  variants.
- Year/month rows update when selection changes.
- Thumbnail exported badges are selection-aware.

### Production Writer Tests

Existing production writer tests mostly remain valid because `PHAssetResourceManager` still writes a
resource descriptor. Add tests only if descriptor matching changes.

### Manual Testing

Use a small Photos library with:

- One unedited JPEG.
- One edited JPEG.
- One edited HEIC whose edited resource is JPEG if possible.
- One edited video if available.
- Two assets with the same original filename in the same month if possible.
- One original filename that naturally contains `_edited`.

Verify:

- Original-only exports original filenames.
- Edited-only exports only `_edited` files for adjusted assets.
- Original + edited exports original plus `_edited` for adjusted assets and only original for
  unedited assets.
- Re-running export skips completed selected variants.
- Switching from original-only to original-and-edited exports missing edited variants only.
- Import existing backup restores original and edited states.
- Month/year summaries do not treat unedited assets as missing edited work.

Run before completion:

```bash
xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

If website docs change:

```bash
cd website
npm run format:check
npm run lint
```

## Maintainability Notes

- Keep PhotoKit resource interpretation out of SwiftUI views.
- Keep filename rules in one helper shared by export and backup scanning.
- Keep selection logic explicit by variant; do not revive a broad "primary resource" helper.
- Keep completion logic in one policy/evaluator so export, UI, and import agree.
- Keep the first implementation focused on still photo/video original vs current edited export.
- Do not fold full Live Photo paired-video export or RAW+JPEG policy into this issue unless needed to
  avoid a regression.
- Use decode-time migration plus new-schema writes instead of rewriting old record files in place.
- Keep import matching conservative. Ambiguous edited files should stay ambiguous rather than marking
  the wrong asset as backed up.
