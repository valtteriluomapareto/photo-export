import Combine
import Foundation
import os

/// Process-lifetime owner of bootstrap and destination-change handling for the app.
///
/// Lives in `PhotoExportApp` as a single `@StateObject`, but the wiring is intentionally
/// independent of view scope: `attach(initialDestinationId:destinationIdPublisher:)` is
/// idempotent so multi-window scene recreation re-runs the view's `.task` without
/// re-bootstrapping the app.
///
/// The destination-change path is fingerprint-aware: a same-id change (the current `destinationId`
/// re-asserted with the same value, e.g. from a stale-bookmark refresh that resolved to the same
/// volume) is a no-op rather than a `cancelAndClear()` + reconfigure cycle. Splitting fingerprint
/// awareness from the bootstrap move would leave the app in a state where bookmark refreshes
/// silently interrupt active exports, so the two changes intentionally land together.
@MainActor
final class AppLifecycleCoordinator: ObservableObject {
  private let cancelActiveWork: () -> Void
  private let configureRecordStores: (String?) -> Void
  private let log: Logger

  private(set) var lastConfiguredDestinationId: String?
  private var didAttach = false
  private var destinationIdObservation: AnyCancellable?

  init(
    cancelActiveWork: @escaping () -> Void,
    configureRecordStores: @escaping (String?) -> Void,
    log: Logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Lifecycle")
  ) {
    self.cancelActiveWork = cancelActiveWork
    self.configureRecordStores = configureRecordStores
    self.log = log
  }

  /// Wires up destination-change handling and runs the initial configure for the current id.
  /// Calling this more than once is a no-op so SwiftUI's view `.task` can call it freely.
  func attach(
    initialDestinationId: String?,
    destinationIdPublisher: AnyPublisher<String?, Never>
  ) {
    guard !didAttach else {
      log.debug("attach called more than once; ignoring (multi-window scene recreation)")
      return
    }
    didAttach = true

    apply(destinationId: initialDestinationId)

    destinationIdObservation =
      destinationIdPublisher
      .removeDuplicates()
      .sink { [weak self] newId in
        self?.apply(destinationId: newId)
      }
  }

  /// Applies a destination id transition. Same-fingerprint changes are no-ops; only true
  /// destination-id changes cancel pending work and reconfigure the record stores.
  ///
  /// Internal so unit tests can drive transitions without setting up a Combine publisher.
  func apply(destinationId newId: String?) {
    if newId == lastConfiguredDestinationId {
      log.debug(
        "Same-fingerprint destination assignment (\(newId ?? "nil", privacy: .public)); skipping cancel/reconfigure"
      )
      return
    }
    log.info(
      "Destination id changed: \(self.lastConfiguredDestinationId ?? "nil", privacy: .public) → \(newId ?? "nil", privacy: .public)"
    )
    cancelActiveWork()
    lastConfiguredDestinationId = newId
    configureRecordStores(newId)
  }
}
