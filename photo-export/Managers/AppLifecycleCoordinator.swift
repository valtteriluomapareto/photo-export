import Combine
import Foundation
import os

/// Result of running the per-destination directory coordinator and configuring the record
/// stores. Surfaces the migration-conflict case so the UI (when wired up) can present a
/// recoverable blocked state instead of silently adopting `<newId>/` and orphaning
/// `<legacyId>/`.
enum ConfigureRecordStoresResult: Equatable, Sendable {
  case success
  case migrationConflict(newId: String, legacyId: String)
  case migrationFailed(message: String)
}

/// Snapshot of a migration-conflict situation. Both `<newId>/` and `<legacyId>/` exist on
/// disk; the auto-sync plan calls for blocking automatic export and exposing recovery
/// options in Settings until the user resolves it.
struct MigrationConflictState: Equatable, Sendable {
  let newId: String
  let legacyId: String
}

/// Snapshot of the destination identity the coordinator reacts to. Carries the structured
/// fingerprint when one is available, plus the bare id for the no-fingerprint cases (drive
/// unmounted / no destination selected). The id alone is what determines whether a change
/// is "same destination" — equal ids skip the cancel/reconfigure cycle even if a transient
/// fingerprint refresh produced a slightly different live fingerprint.
///
/// Construction is via `init(fingerprint:)` or `.none`; both keep `id == fingerprint?.id`
/// invariant. There is intentionally no public initializer that takes id and fingerprint
/// separately — earlier review caught that allowing them to drift silently would let a
/// caller pass an id that disagrees with the embedded fingerprint's derived id, which
/// would then split downstream code that mixes `currentDestination.id` (used today) with
/// `currentDestination.fingerprint?.id` (the future safety-gate read).
struct DestinationIdentitySnapshot: Equatable, Sendable {
  let id: String?
  let fingerprint: DestinationFingerprint?

  static let none = DestinationIdentitySnapshot(fingerprint: nil)

  init(fingerprint: DestinationFingerprint?) {
    self.fingerprint = fingerprint
    self.id = fingerprint?.id
  }
}

/// Process-lifetime owner of bootstrap and destination-change handling for the app.
///
/// Lives in `PhotoExportApp` as a single `@StateObject`, but the wiring is intentionally
/// independent of view scope: `attach(initial:fingerprintPublisher:)` is idempotent so
/// multi-window scene recreation re-runs the view's `.task` without re-bootstrapping the app.
///
/// The destination-change path is fingerprint-aware: a same-id change (the current
/// fingerprint re-asserted with the same id, e.g. from a stale-bookmark refresh that
/// resolved to the same volume) is a no-op rather than a `cancelAndClear()` + reconfigure
/// cycle. The coordinator carries the full `DestinationFingerprint` (not just the id hash)
/// so downstream code — safety gate, AutoSync — can read `identityConfidence` and the
/// volume/path components without recomputing them from a URL.
@MainActor
final class AppLifecycleCoordinator: ObservableObject {
  private let cancelActiveWork: () -> Void
  private let configureRecordStores: (String?) -> ConfigureRecordStoresResult
  private let log: Logger

  @Published private(set) var currentDestination: DestinationIdentitySnapshot = .none
  @Published private(set) var migrationConflict: MigrationConflictState?

  /// Convenience accessor for the id of the most recently configured destination. Equals
  /// `currentDestination.id`.
  var lastConfiguredDestinationId: String? { currentDestination.id }

  private var didAttach = false
  private var destinationObservation: AnyCancellable?

  init(
    cancelActiveWork: @escaping () -> Void,
    configureRecordStores: @escaping (String?) -> ConfigureRecordStoresResult,
    log: Logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Lifecycle")
  ) {
    self.cancelActiveWork = cancelActiveWork
    self.configureRecordStores = configureRecordStores
    self.log = log
  }

  /// Wires up destination-change handling and runs the initial configure for the current
  /// fingerprint. Calling this more than once is a no-op so SwiftUI's view `.task` can call
  /// it freely on every scene recreation.
  func attach(
    initial: DestinationIdentitySnapshot,
    fingerprintPublisher: AnyPublisher<DestinationFingerprint?, Never>
  ) {
    guard !didAttach else {
      log.debug("attach called more than once; ignoring (multi-window scene recreation)")
      return
    }
    didAttach = true

    apply(destination: initial)

    // The publisher is driven by `ExportDestinationManager`'s `@MainActor` writes, so
    // emissions arrive on the main thread. `MainActor.assumeIsolated` makes the call to
    // `apply(destination:)` explicit under Swift 6 strict concurrency without paying for a
    // thread hop. `removeDuplicates()` (over the id hash) filters value-equal re-assignments;
    // the `currentDestination.id == newId` check inside `apply` is a belt-and-braces guard
    // for any future publisher implementation that does not honor that filter.
    destinationObservation =
      fingerprintPublisher
      .removeDuplicates(by: { $0?.id == $1?.id })
      .sink { [weak self] fingerprint in
        MainActor.assumeIsolated {
          self?.apply(destination: DestinationIdentitySnapshot(fingerprint: fingerprint))
        }
      }
  }

  /// Applies a destination transition. Same-id snapshots (the current id re-asserted) are
  /// no-ops; only true destination-id changes cancel pending work and reconfigure the record
  /// stores. Internal so unit tests can drive transitions directly.
  func apply(destination: DestinationIdentitySnapshot) {
    if destination.id == currentDestination.id {
      log.debug(
        "Same-id destination assignment (\(destination.id ?? "nil", privacy: .public)); skipping cancel/reconfigure"
      )
      // Update the fingerprint snapshot anyway so downstream code sees the freshest live
      // metadata — but only if the snapshot actually differs. Skipping the assignment when
      // the value is equal avoids re-firing `objectWillChange` on every transient
      // fingerprint refresh, which would otherwise re-render any SwiftUI view observing
      // `currentDestination`.
      if destination != currentDestination {
        currentDestination = destination
      }
      return
    }
    log.info(
      "Destination id changed: \(self.currentDestination.id ?? "nil", privacy: .public) → \(destination.id ?? "nil", privacy: .public)"
    )
    cancelActiveWork()
    currentDestination = destination
    let result = configureRecordStores(destination.id)
    switch result {
    case .success:
      migrationConflict = nil
    case .migrationConflict(let newId, let legacyId):
      migrationConflict = MigrationConflictState(newId: newId, legacyId: legacyId)
    case .migrationFailed:
      // Transient I/O failure during rename. Preserve any prior conflict state — a previous
      // launch may have surfaced a real legacy/stable conflict that this transient failure
      // shouldn't paper over. Logged at the call site.
      break
    }
  }
}
