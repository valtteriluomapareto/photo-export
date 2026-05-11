import Foundation

/// How a single export failure should be treated by the retry policy. Plan §"Retry and
/// Failure Policy" defines the routing: transient categories retry with exponential
/// backoff, hard categories require explicit user action, and `destinationUnavailable`
/// only retries on an availability transition.
enum AutoSyncFailureCategory: String, Codable, Equatable, CaseIterable, Sendable {
  case destinationUnavailable
  case destinationPermission
  case destinationNoSpace
  case assetMissing
  case resourceMissing
  case photoKitTransient
  case iCloudTransient
  case unknown

  /// Whether the retry policy schedules an automatic retry for this category. Hard
  /// failures (`destinationPermission`, `destinationNoSpace`, `assetMissing`, stable
  /// `resourceMissing`) require explicit user action. `destinationUnavailable` is
  /// retry-on-state-change rather than retry-on-timer, so it returns `false` here even
  /// though it can resolve.
  var isAutomaticallyRetryable: Bool {
    switch self {
    case .photoKitTransient, .iCloudTransient, .unknown:
      return true
    case .destinationUnavailable, .destinationPermission, .destinationNoSpace,
      .assetMissing, .resourceMissing:
      return false
    }
  }

  /// Exponential backoff for auto-retryable categories. Returns the
  /// wall-clock instant at which the retry policy considers a fresh
  /// attempt eligible, or `nil` for non-auto-retryable categories — those
  /// require user action (`destinationPermission`, `destinationNoSpace`,
  /// `assetMissing`, `resourceMissing`) or a state change
  /// (`destinationUnavailable` waits for the drive to come back).
  ///
  /// Per `(category, signature)` group, attempts back off:
  ///   1 → 30 s, 2 → 2 m, 3 → 10 m, 4 → 1 h, 5+ → 6 h (cap)
  /// Conservative — tuned to be polite to iCloud / PhotoKit rate limits
  /// rather than to recover instantly.
  func nextEligibleAt(attemptCount: Int, from failedAt: Date) -> Date? {
    guard isAutomaticallyRetryable else { return nil }
    let delay: TimeInterval
    switch attemptCount {
    case ..<1, 1: delay = 30
    case 2: delay = 120
    case 3: delay = 600
    case 4: delay = 3600
    default: delay = 21_600  // 6 hours
    }
    return failedAt.addingTimeInterval(delay)
  }
}
