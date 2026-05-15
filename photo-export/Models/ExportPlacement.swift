import Foundation

/// A single export "slot" — a `(kind, id, relativePath)` triple that records, queue jobs, and
/// destination directories all key by.
///
/// Four kinds:
/// - `.timeline`: per-month folders like `2025/02/`. Synthesized at the boundary from
///   `(year, month)`; never persisted as a placement metadata entry on disk (the timeline store
///   keeps its existing asset-keyed shape).
/// - `.favorites`: a single fixed folder `Collections/Favorites/`.
/// - `.album`: per-album folders under `Collections/Albums/...` with sibling-collision
///   disambiguation (`_2`, `_3` suffixes) and rename-detection via `displayPathHash8`.
/// - `.sharedAlbum`: per-album folders under `Collections/Shared Albums/<title>/`.
///   Shared albums never nest in folders, so the placement has no parent path
///   component. Same collision-suffix rules apply for two shared albums with identical
///   sanitized titles.
///
/// Identity is `id` only. Manual `Hashable`/`Equatable` over `id` (not synthesized over all
/// fields) so two `ExportPlacement` values with the same `id` but different `createdAt`
/// timestamps compare equal — `createdAt` is diagnostic, not part of identity. Without manual
/// conformance a freshly-constructed lookup placement (with `createdAt = Date()`) would fail
/// to match the persisted version (with the original timestamp).
struct ExportPlacement: Codable, Sendable {
  enum Kind: String, Codable, Hashable, Sendable {
    case timeline
    case favorites
    case album
    case sharedAlbum

    /// Variant-selection policy for this placement kind. Centralises the
    /// "Photos returns one resource here" branch: shared albums get
    /// `.singleResource` so `requiredVariants(...)` collapses to `[.original]`
    /// and "Include originals" is naturally suppressed. Owned-library paths
    /// (timeline, favorites, user albums) stay on `.standard` and honour the
    /// user's selection.
    var variantPolicy: VariantPolicy {
      switch self {
      case .sharedAlbum: return .singleResource
      case .timeline, .favorites, .album: return .standard
      }
    }
  }

  let kind: Kind
  /// Stable string id; used as the placement-section key on disk for the collection store and
  /// as the queue-counts dict key in `ExportManager`.
  let id: String
  /// Human-readable label shown in diagnostic logs (and any future rename dialog).
  /// `relativePath` is sanitized and `id` is opaque, so neither is suitable.
  let displayName: String
  /// `PHAssetCollection.localIdentifier` for `.album` and `.sharedAlbum` placements.
  /// `nil` for `.timeline` (no PhotoKit collection) and `.favorites` (synthetic; backed
  /// by a `favorite == YES` predicate, not a real `PHAssetCollection`).
  let collectionLocalIdentifier: String?
  /// Frozen at placement creation. Never recomputed. Used to construct destination URLs and
  /// to read the on-disk record subdirectory for each placement.
  let relativePath: String
  /// Diagnostic; set when the placement is first persisted. Not part of identity.
  let createdAt: Date
}

extension ExportPlacement: Hashable {
  static func == (lhs: ExportPlacement, rhs: ExportPlacement) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension ExportPlacement {
  /// Synthetic timeline placement for `(year, month)`. Constructed at the queue/store
  /// boundary; never persisted in the timeline store's records (which stay asset-keyed).
  ///
  /// Format: `id = "timeline:<YYYY>-<MM>"`, `relativePath = "<YYYY>/<MM>/"`.
  static func timeline(year: Int, month: Int, createdAt: Date = Date()) -> ExportPlacement {
    let monthString = String(format: "%02d", month)
    let yearString = String(format: "%04d", year)
    return ExportPlacement(
      kind: .timeline,
      id: "timeline:\(year)-\(monthString)",
      displayName: "\(year)/\(monthString)",
      collectionLocalIdentifier: nil,
      relativePath: "\(yearString)/\(monthString)/",
      createdAt: createdAt
    )
  }

  /// Synthetic favorites placement. There is exactly one of these per destination; the
  /// collection store keys it under `id == "collections:favorites"`.
  static func favorites(createdAt: Date = Date()) -> ExportPlacement {
    ExportPlacement(
      kind: .favorites,
      id: "collections:favorites",
      displayName: "Favorites",
      collectionLocalIdentifier: nil,
      relativePath: "Collections/Favorites/",
      createdAt: createdAt
    )
  }

  /// For a `.timeline` placement, extracts `(year, month)` from its id (`timeline:YYYY-MM`).
  /// Returns `nil` for any other kind. Used by `ExportManager` and the existing timeline
  /// store API to derive `(year, month)` parameters from a job's placement.
  var timelineYearMonth: (year: Int, month: Int)? {
    guard kind == .timeline else { return nil }
    let prefix = "timeline:"
    guard id.hasPrefix(prefix) else { return nil }
    let body = id.dropFirst(prefix.count)
    let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else {
      return nil
    }
    return (year, month)
  }
}

/// In-memory ergonomic key for record lookups: `(placementId, assetId)`. Not persisted —
/// records on disk are nested by placement id (outer dict) and asset id (inner dict).
struct ExportRecordKey: Hashable, Sendable {
  let placementId: String
  let assetId: String
}

/// Scope for `CollectionExportRecordStore.recordCount(in:)`. Mirrors the kinds the collection
/// store accepts (`.favorites`, `.album`, `.sharedAlbum`); excludes `.timeline` because the
/// collection store rejects timeline placements at the API boundary.
enum CollectionPlacementScope: Hashable, Sendable {
  case favorites
  case album(collectionLocalId: String)
  case sharedAlbum(collectionLocalId: String)
  case any  // favorites + albums + shared albums
}

/// In-memory shape callers use to read and upsert collection records. Joins the on-disk
/// `(placementId, assetId)` key with the variants dictionary and the placement object so
/// callers don't have to look up the placement separately.
///
/// On disk, placement metadata lives in the top-level `placements` map and each record body
/// is just its variants dictionary; this struct is the in-memory "joined view" that
/// `CollectionExportRecordStore.exportInfo(assetId:placement:)` returns.
struct ScopedExportRecord: Sendable, Equatable {
  let placement: ExportPlacement
  let assetId: String
  var variants: [ExportVariant: ExportVariantRecord]
}

/// Summary of one placement's records. Mirrors `MonthStatusSummary` (which exists for the
/// timeline store) but keys by placement id rather than year/month.
struct PlacementSummary: Sendable, Equatable {
  let placementId: String
  /// Distinct assets under this placement that have at least one variant in `.done`.
  let exportedCount: Int
  /// Distinct assets under this placement that have any record at all.
  let totalCount: Int
  /// `notExported` / `partial` / `complete`, computed from `(exportedCount, totalCount)`.
  let status: MonthExportStatus
}
