import Foundation

/// How a single export failure should be treated by the retry policy. Transient
/// categories retry with exponential backoff, hard categories require explicit user
/// action, and `destinationUnavailable` has no timer: it is retried by the next Auto
/// Export run, which only starts while the destination is available.
enum AutoSyncFailureCategory: String, Codable, Equatable, CaseIterable, Sendable {
  /// The destination can't be reached: a network errno (ENOTCONN, ETIMEDOUT, ESTALE,
  /// EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH), ENXIO, or a destination that is not
  /// available. A missing file (ENOENT, Cocoa 4/260) and EIO are `.unknown`, because they
  /// don't prove the destination went away.
  case destinationUnavailable
  case destinationPermission
  case destinationNoSpace
  case destinationCollision
  case assetMissing
  case resourceMissing
  case photoKitTransient
  case iCloudTransient
  case unknown

  /// Further writes in this run would hit the same destination-wide failure.
  var stopsCurrentExportRun: Bool {
    self == .destinationNoSpace || self == .destinationPermission
      || self == .destinationUnavailable
  }

  /// Whether the retry policy schedules an automatic retry for this category. Hard
  /// failures (`destinationPermission`, `destinationNoSpace`, `destinationCollision`, `assetMissing`, stable
  /// `resourceMissing`) require explicit user action. `destinationUnavailable` has no
  /// timer either, so it returns `false` here; `RetryEntry.isEligibleForAutoSync` lets the
  /// next Auto Export run try it again.
  var isAutomaticallyRetryable: Bool {
    switch self {
    case .photoKitTransient, .iCloudTransient, .unknown:
      return true
    case .destinationUnavailable, .destinationPermission, .destinationNoSpace,
      .destinationCollision,
      .assetMissing, .resourceMissing:
      return false
    }
  }

  /// Exponential backoff for auto-retryable categories. Returns the
  /// wall-clock instant at which the retry policy considers a fresh
  /// attempt eligible, or `nil` for non-auto-retryable categories — those
  /// require user action (`destinationPermission`, `destinationNoSpace`,
  /// `destinationCollision`, `assetMissing`, `resourceMissing`) or the next Auto Export
  /// run (`destinationUnavailable`).
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
