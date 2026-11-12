import Combine
@testable import Photo_Export

extension AutoSyncManager {
  /// `$lastRunSummary` for subscribers outside this type: synchronous, delivered before the
  /// value is stored, and replaying the current value (pinned by `PublisherParityTests`).
  /// Test-only accessor for synchronous delivery characterization.
  var lastRunSummaryPublisher: AnyPublisher<ExportRunSummary?, Never> {
    $lastRunSummary.eraseToAnyPublisher()
  }

}

extension AppLifecycleCoordinator {
  /// `$currentDestination` for subscribers outside this type: synchronous, delivered before the
  /// value is stored, and replaying the current value (pinned by `PublisherParityTests`).
  /// Test-only accessor for synchronous delivery characterization.
  var currentDestinationPublisher: AnyPublisher<DestinationIdentitySnapshot, Never> {
    $currentDestination.eraseToAnyPublisher()
  }
  /// Convenience accessor for the id of the most recently configured destination. Equals
  /// `currentDestination.id`.
  var lastConfiguredDestinationId: String? { currentDestination.id }

}
