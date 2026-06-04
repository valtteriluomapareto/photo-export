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

/// Snapshot of the destination identity the coordinator reacts to. Carries the **stable
/// logical id** (`id`) plus the advisory `fingerprint`. The id alone determines whether a
/// change is "same destination" — equal ids skip the cancel/reconfigure cycle even when a
/// transient fingerprint refresh (or a network-share remount under a new path) produced a
/// different live fingerprint.
///
/// `id` is the stable id sourced from `DestinationIdentity.stableId`, **not** recomputed from
/// `fingerprint?.id`. The earlier "no separate id" init ban (when the id *was*
/// `fingerprint?.id`) is relaxed: `init(identity:)` carries an id that may legitimately diverge
/// from the fingerprint's derived id. The `init(fingerprint:)` convenience (id tracks the
/// fingerprint id) remains for tests and no-drift call sites.
struct DestinationIdentitySnapshot: Equatable, Sendable {
  let id: String?
  let fingerprint: DestinationFingerprint?

  static let none = DestinationIdentitySnapshot(identity: .unavailable)

  init(identity: DestinationIdentity) {
    self.id = identity.stableId
    self.fingerprint = identity.fingerprint
  }

  /// Test / no-drift convenience: the id tracks the fingerprint id.
  init(fingerprint: DestinationFingerprint?) {
    self.init(
      identity: DestinationIdentity(
        stableId: fingerprint?.id,  // keying-id-ok: no-drift convenience
        fingerprint: fingerprint))
  }
}

/// Process-lifetime owner of bootstrap and destination-change handling for the app.
///
/// Lives in `PhotoExportApp` as a single `@StateObject`, but the wiring is intentionally
/// independent of view scope: `attach(initial:identityPublisher:)` is idempotent so
/// multi-window scene recreation re-runs the view's `.task` without re-bootstrapping the app.
///
/// The destination-change path keys on the **stable logical id**: a same-id change (the same
/// destination re-asserted with the same stable id, e.g. a stale-bookmark refresh or a network-
/// share remount that drifted the fingerprint but resolved to the same folder) is a no-op
/// rather than a `cancelAndClear()` + reconfigure cycle. The coordinator carries the full
/// `DestinationFingerprint` alongside the id so downstream code — safety gate, AutoSync — can
/// read `identityConfidence` and the volume/path components without recomputing them from a
/// URL; that fingerprint is advisory and may differ from the stable id's seed.
@MainActor
final class AppLifecycleCoordinator: ObservableObject {
  private let cancelActiveWork: () -> Void
  private let interruptForDestinationUnavailable: () -> Void
  private let configureRecordStores: (String?) -> ConfigureRecordStoresResult
  /// Removes app-internal state directories owned by `legacyId`. Called by
  /// `clearMigrationConflictAfterReconcile` once the user has chosen to drop
  /// the legacy records and the destination's current-id records have been
  /// rebuilt (e.g., via Import Existing Backup). Closure-based to keep the
  /// coordinator decoupled from the on-disk layout — `PhotoExportApp` wires
  /// it to delete `<ExportRecords>/<legacyId>/` plus
  /// `<AutoSync>/destinations/<legacyId>/`. Per the plan's Safety
  /// Invariants, only app-internal directories are touched here — no
  /// user-visible files on the destination drive.
  private let gcLegacyState: (String) -> Void
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
    interruptForDestinationUnavailable: @escaping () -> Void,
    configureRecordStores: @escaping (String?) -> ConfigureRecordStoresResult,
    gcLegacyState: @escaping (String) -> Void = { _ in },
    log: Logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Lifecycle")
  ) {
    self.cancelActiveWork = cancelActiveWork
    self.interruptForDestinationUnavailable = interruptForDestinationUnavailable
    self.configureRecordStores = configureRecordStores
    self.gcLegacyState = gcLegacyState
    self.log = log
  }

  /// Called by the recovery UI after the user has reconciled the
  /// destination's current-id records (e.g., via Import Existing Backup).
  /// GCs the legacy id's app-internal directories and clears the conflict
  /// flag. Idempotent — second call with no conflict in flight is a no-op.
  func clearMigrationConflictAfterReconcile() {
    guard let conflict = migrationConflict else { return }
    log.info(
      "Resolving migration conflict by GC'ing legacy \(conflict.legacyId, privacy: .public); new \(conflict.newId, privacy: .public) remains."
    )
    gcLegacyState(conflict.legacyId)
    migrationConflict = nil
  }

  /// Wires up destination-change handling and runs the initial configure for the current
  /// fingerprint. Calling this more than once is a no-op so SwiftUI's view `.task` can call
  /// it freely on every scene recreation.
  func attach(
    initial: DestinationIdentitySnapshot,
    identityPublisher: AnyPublisher<DestinationIdentity, Never>
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
    // thread hop. `removeDuplicates()` (over the full `DestinationIdentity`) filters
    // value-equal re-assignments; the `currentDestination.id == newId` check inside `apply` is
    // a belt-and-braces guard for any future publisher implementation that does not honor that
    // filter.
    //
    // **IMPORTANT:** the upstream publisher MUST emit on the main thread. If a future caller
    // wires a publisher that hops threads (e.g. `.subscribe(on: .global)`), the
    // `assumeIsolated` call will trap. The debug-only precondition below makes that case
    // observable in development; release builds rely on the contract being honored.
    // `removeDuplicates()` filters identity-equal re-emissions (stable id *and* fingerprint).
    // A stable-id-only filter would drop same-id-different-metadata events — e.g. a network-
    // share remount that keeps the stable id but drifts the fingerprint — which the same-id
    // branch in `apply(destination:)` is designed to surface (fresh metadata, no re-key).
    destinationObservation =
      identityPublisher
      .removeDuplicates()
      .sink { [weak self] identity in
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
          self?.apply(destination: DestinationIdentitySnapshot(identity: identity))
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
    // Same-id case is filtered by the early return above; the `(nil, nil)` branch is
    // therefore defensive (would only fire if some future caller bypasses that check).
    switch (currentDestination.id, destination.id) {
    case (nil, nil):
      break
    case (.some, nil):
      // Drive unmount or destination cleared. Resolve any active run as transient
      // (`cancelReason: .destinationUnavailable`) so AutoSync can resume when the
      // drive returns rather than treating every queued job as permanently failed.
      interruptForDestinationUnavailable()
    case (nil, .some):
      // First selection or drive remount. There is no active export work tied to the
      // previous (nil) destination, so no cleanup is needed.
      break
    case (.some, .some):
      // True destination change. Treat the previous destination's queued work as
      // orphaned and cancel.
      cancelActiveWork()
    }
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
