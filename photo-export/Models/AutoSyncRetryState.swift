import Foundation

/// Identifies the scope or placement a retry entry is scoped to. Timeline failures share
/// one bucket; Favorites failures share one bucket; each album has its own bucket keyed
/// by placement id. The plan requires this segmentation so a failure in one album does
/// not suppress retries for the same asset in another album, in Favorites, or in
/// Timeline.
enum AutoSyncRetryScopeKey: Equatable, Hashable, Sendable {
  case timeline
  case favorites
  case album(placementId: String)

  /// String form used as the persisted dictionary key. The `album:` prefix lets callers
  /// recognize album-scoped entries when iterating the raw map for diagnostics.
  var rawValue: String {
    switch self {
    case .timeline: return "timeline"
    case .favorites: return "favorites"
    case .album(let placementId): return "album:\(placementId)"
    }
  }

  /// Recovers a typed key from a stored raw string. Returns `nil` for unrecognized
  /// formats so callers can skip and log unknown buckets without crashing.
  init?(rawValue: String) {
    switch rawValue {
    case "timeline": self = .timeline
    case "favorites": self = .favorites
    default:
      let prefix = "album:"
      guard rawValue.hasPrefix(prefix) else { return nil }
      let placementId = String(rawValue.dropFirst(prefix.count))
      guard !placementId.isEmpty else { return nil }
      self = .album(placementId: placementId)
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
    if let existing, existing.errorSignature == errorSignature {
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
