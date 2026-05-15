import Foundation

/// Identifies the scope or placement a retry entry is scoped to. Timeline failures share
/// one bucket; Favorites failures share one bucket; each album has its own bucket keyed
/// by placement id; shared albums get their own typed case so the rendered UI label and
/// any future per-kind retry tuning can branch cleanly without inspecting the embedded
/// placement-id prefix. The plan requires this segmentation so a failure in one album
/// does not suppress retries for the same asset in another album, in Favorites, in
/// Timeline, or in a shared album.
enum AutoSyncRetryScopeKey: Equatable, Hashable, Sendable {
  case timeline
  case favorites
  case album(placementId: String)
  case sharedAlbum(placementId: String)

  /// String form used as the persisted dictionary key. The `album:` and
  /// `shared-album:` prefixes let callers recognize album-scoped entries when
  /// iterating the raw map for diagnostics. The shared-album prefix is intentionally
  /// distinct so the `init?(rawValue:)` parser can disambiguate the two.
  var rawValue: String {
    switch self {
    case .timeline: return "timeline"
    case .favorites: return "favorites"
    case .album(let placementId): return "album:\(placementId)"
    case .sharedAlbum(let placementId): return "shared-album:\(placementId)"
    }
  }

  /// Recovers a typed key from a stored raw string. Returns `nil` for unrecognized
  /// formats so callers can skip and log unknown buckets without crashing.
  ///
  /// `shared-album:` is checked **before** `album:` because the longer prefix is a
  /// superset of the shorter — `hasPrefix("album:")` happens to be false for
  /// `"shared-album:foo"` (different first character) but the explicit ordering
  /// documents the precedence and survives future prefix renames.
  init?(rawValue: String) {
    switch rawValue {
    case "timeline": self = .timeline
    case "favorites": self = .favorites
    default:
      let sharedPrefix = "shared-album:"
      let albumPrefix = "album:"
      if rawValue.hasPrefix(sharedPrefix) {
        let placementId = String(rawValue.dropFirst(sharedPrefix.count))
        guard !placementId.isEmpty else { return nil }
        self = .sharedAlbum(placementId: placementId)
      } else if rawValue.hasPrefix(albumPrefix) {
        let placementId = String(rawValue.dropFirst(albumPrefix.count))
        guard !placementId.isEmpty else { return nil }
        self = .album(placementId: placementId)
      } else {
        return nil
      }
    }
  }
}

/// Per-failure retry bookkeeping. `errorSignature` is a stable string representation of
/// the error (typically `domain:code` or similar) that the retry policy uses to decide
/// whether a fresh failure is the same problem (increment attempt count) or a different
/// one (reset attempt count to 1).
struct RetryEntry: Codable, Equatable, Sendable {
  let category: AutoSyncFailureCategory
  let errorSignature: String
  let attemptCount: Int
  let firstFailedAt: Date
  let lastFailedAt: Date
  let nextEligibleAt: Date?
}

/// Per-destination retry state. The nested dictionary is `[scopeKey: [assetId: [variant: entry]]]`
/// so retries are scoped to scope/placement + assetId + variant, matching the plan's
/// "retry counts are scoped to scope/placement + assetId + variant + category + errorSignature"
/// rule. (`category` and `errorSignature` live on the entry; the dictionary key triple
/// names the *position* a failure occupies.)
struct AutoSyncRetryState: Codable, Equatable, Sendable {
  /// Outer key: `AutoSyncRetryScopeKey.rawValue`.
  /// Middle key: `assetId` (PhotoKit local identifier).
  /// Inner key: `ExportVariant.rawValue`.
  var entriesByPlacement: [String: [String: [String: RetryEntry]]]

  init(entriesByPlacement: [String: [String: [String: RetryEntry]]] = [:]) {
    self.entriesByPlacement = entriesByPlacement
  }

  static let empty = AutoSyncRetryState()

  var isEmpty: Bool { entriesByPlacement.isEmpty }

  /// Looks up the entry for a (scope, asset, variant) tuple. Returns `nil` when no
  /// failure has been recorded yet.
  func entry(
    scope: AutoSyncRetryScopeKey,
    assetId: String,
    variant: ExportVariant
  ) -> RetryEntry? {
    entriesByPlacement[scope.rawValue]?[assetId]?[variant.rawValue]
  }

  /// Records a failure for a (scope, asset, variant) tuple. If an existing entry has the
  /// same `errorSignature` the attempt count increments; if the signature differs the
  /// entry is reset to attempt 1 (a materially different error is not a continuation of
  /// the previous failure, per plan §"Retry and Failure Policy").
  mutating func recordFailure(
    scope: AutoSyncRetryScopeKey,
    assetId: String,
    variant: ExportVariant,
    category: AutoSyncFailureCategory,
    errorSignature: String,
    at date: Date,
    nextEligibleAt: Date?
  ) {
    var scopeBucket = entriesByPlacement[scope.rawValue] ?? [:]
    var assetBucket = scopeBucket[assetId] ?? [:]
    let existing = assetBucket[variant.rawValue]

    let attemptCount: Int
    let firstFailedAt: Date
    // Plan §"Retry and Failure Policy": retry counts are scoped to scope/placement +
    // assetId + variant + category + errorSignature. A change in *either* category or
    // signature means the previous backoff sequence does not apply — reset to attempt 1.
    if let existing, existing.errorSignature == errorSignature, existing.category == category {
      attemptCount = existing.attemptCount + 1
      firstFailedAt = existing.firstFailedAt
    } else {
      attemptCount = 1
      firstFailedAt = date
    }

    assetBucket[variant.rawValue] = RetryEntry(
      category: category,
      errorSignature: errorSignature,
      attemptCount: attemptCount,
      firstFailedAt: firstFailedAt,
      lastFailedAt: date,
      nextEligibleAt: nextEligibleAt
    )
    scopeBucket[assetId] = assetBucket
    entriesByPlacement[scope.rawValue] = scopeBucket
  }

  /// Removes the entry for a (scope, asset, variant) tuple after a successful retry.
  /// Empties bubble up: empty asset buckets and empty scope buckets are removed so the
  /// persisted shape stays sparse.
  mutating func removeEntry(
    scope: AutoSyncRetryScopeKey,
    assetId: String,
    variant: ExportVariant
  ) {
    guard var scopeBucket = entriesByPlacement[scope.rawValue],
      var assetBucket = scopeBucket[assetId]
    else { return }

    assetBucket.removeValue(forKey: variant.rawValue)
    if assetBucket.isEmpty {
      scopeBucket.removeValue(forKey: assetId)
    } else {
      scopeBucket[assetId] = assetBucket
    }

    if scopeBucket.isEmpty {
      entriesByPlacement.removeValue(forKey: scope.rawValue)
    } else {
      entriesByPlacement[scope.rawValue] = scopeBucket
    }
  }
}
