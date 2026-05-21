import Foundation

/// Which concrete file is being written or recorded for a given Photos asset.
enum ExportVariant: String, Codable, CaseIterable, Hashable, Sendable {
  case original
  case edited
  /// Live Photo motion file paired with `.original`. Lands at `<stem>.mov` (single mode)
  /// or `<stem>_orig.mov` when paired with `.edited` so it tracks its companion still.
  case originalPairedVideo
  /// Live Photo motion file paired with `.edited`. Lands at `<stem>.mov`.
  case editedPairedVideo

  /// True when this variant is the Live Photo motion file (paired video). Image-side
  /// variants (`.original`, `.edited`) return false. Centralised here so call sites
  /// don't pattern-match the raw enum.
  var isPairedVideo: Bool {
    switch self {
    case .originalPairedVideo, .editedPairedVideo: return true
    case .original, .edited: return false
    }
  }
}

/// User-facing selection that drives which variants are required per asset.
enum ExportVersionSelection: String, Codable, CaseIterable, Sendable {
  /// One file per asset: edited bytes if Photos has an edit, original bytes otherwise.
  /// The user sees what they see in Photos.app.
  case edited
  /// `edited` plus a `_orig` companion for any asset that has Photos edits. Lets the user
  /// keep RAW or pre-edit backups alongside the user-visible rendering.
  case editedWithOriginals
}

/// How `requiredVariants(...)` should interpret a `(asset, selection)` pair. Derived
/// from `ExportPlacement.Kind` — see `ExportPlacement.Kind.variantPolicy`. Lives as
/// its own type rather than a `Bool` so a future third mode (e.g. video-thumbnails-
/// only, RAW-then-edited) can be added without changing every call site again.
enum VariantPolicy: Sendable {
  /// Honor the user's `ExportVersionSelection` and the asset's `hasAdjustments`.
  case standard
  /// Force `[.original]` regardless of selection or adjustments. Used when Photos
  /// exposes a single byte source per asset (iCloud shared albums — one downscaled
  /// JPEG, no separate edited/original resources). Naturally makes "Include
  /// originals" a no-op.
  case singleResource
}

/// Required variants for an asset under the active selection and placement policy.
///
/// The `policy` parameter is **required** so a call site cannot accidentally default
/// to `.standard` and silently bypass the single-resource clamp for a shared-album
/// placement. Timeline and collection-side paths pass it explicitly; both ergonomic
/// (`.standard` is a one-token literal) and safe.
///
/// `convertHEICToJPEG` (issue #47) widens the `.edited` requirement to include
/// HEIC-original assets. When the toggle is on, an unedited HEIC counts as
/// "requires `.edited`" because the export pipeline synthesizes a JPEG via
/// `EditedProducer.convertHEIC`. Default `false` keeps every existing caller's
/// behavior unchanged.
///
/// `livePhotosPaired` (issue #49): when true, Live Photo assets get a paired-video
/// variant alongside each image variant. When false (today's default), Live Photos
/// behave like any other still — only the image-side variants are emitted, byte-
/// identical to the pre-issue-#49 behaviour. The flag is opt-in via Settings.
func requiredVariants(
  for asset: AssetDescriptor,
  selection: ExportVersionSelection,
  policy: VariantPolicy,
  convertHEICToJPEG: Bool = false,
  livePhotosPaired: Bool = false
) -> Set<ExportVariant> {
  switch policy {
  case .singleResource:
    // Shared-album placements expose a single downscaled byte source per asset
    // (already a JPEG), so the HEIC→JPEG toggle has nothing to act on.
    return [.original]
  case .standard:
    // HEIC + toggle ⇒ behave as if adjusted: `.edited` is the JPEG synthesis,
    // `.editedWithOriginals` additionally keeps the HEIC `.original`.
    let effectivelyAdjusted = asset.hasAdjustments || (convertHEICToJPEG && asset.isHEICOriginal)
    var variants: Set<ExportVariant>
    switch selection {
    case .edited:
      variants = effectivelyAdjusted ? [.edited] : [.original]
    case .editedWithOriginals:
      variants = effectivelyAdjusted ? [.original, .edited] : [.original]
    }
    if asset.isLivePhoto, livePhotosPaired {
      if variants.contains(.original) { variants.insert(.originalPairedVideo) }
      if variants.contains(.edited) { variants.insert(.editedPairedVideo) }
    }
    return variants
  }
}
