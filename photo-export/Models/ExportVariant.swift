import Foundation

/// Which concrete file is being written or recorded for a given Photos asset.
enum ExportVariant: String, Codable, CaseIterable, Hashable, Sendable {
  case original
  case edited
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
func requiredVariants(
  for asset: AssetDescriptor,
  selection: ExportVersionSelection,
  policy: VariantPolicy
) -> Set<ExportVariant> {
  switch policy {
  case .singleResource:
    return [.original]
  case .standard:
    switch selection {
    case .edited:
      return asset.hasAdjustments ? [.edited] : [.original]
    case .editedWithOriginals:
      return asset.hasAdjustments ? [.original, .edited] : [.original]
    }
  }
}
