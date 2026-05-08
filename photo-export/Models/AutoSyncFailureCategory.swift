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
}
