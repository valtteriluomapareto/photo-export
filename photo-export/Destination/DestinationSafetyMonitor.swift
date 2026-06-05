import Combine
import Foundation
import os

/// Phase 0b safety scan. Observes the destination identity and detects the
/// "destination has files but no matching records" state. Surfaces it as
/// `@Published needsSafetyConfirmation`, which `DestinationSnapshotAdapter`
/// folds into the `DestinationSnapshot.safety` field as
/// `.unsafeNeedsConfirmation`.
///
/// The confirmation is keyed on the **stable logical id**, not `fingerprint?.id`, so a user's
/// confirmation survives a network-share remount that drifts the fingerprint — otherwise the
/// re-keyed lookup would miss and re-prompt on every reconnect.
///
/// Plan §"Destination Safety Model":
///   "If the destination contains files that the app's record stores have no
///   matching records for, surface as `unsafeNeedsConfirmation` and require
///   user confirmation before automatic exports start. ... A user-confirmed
///   destination stays confirmed across launches via the safety record."
///
/// MVP rule: if the destination directory contains *any* user-visible file
/// (anything except `.DS_Store`) and the per-destination record stores are
/// both empty *and* the user hasn't confirmed this destination before, the
/// monitor flags it. Switching to a previously-confirmed destination, or to
/// one with matching records, stays `.safe`.
@MainActor
final class DestinationSafetyMonitor: ObservableObject {
  @Published private(set) var needsSafetyConfirmation: Bool = false

  private let identityPublisher: AnyPublisher<DestinationIdentity, Never>
  private let exportRecordStore: ExportRecordStore
  private let collectionExportRecordStore: CollectionExportRecordStore
  private let confirmationStore: any DestinationSafetyConfirmationStore
  /// Returns true when the destination directory contains user-visible
  /// files. Closure-based so tests can stub the filesystem walk without
  /// needing a real scoped-access URL. Production wires this from
  /// `ExportDestinationManager.beginScopedAccess` +
  /// `FileManager.contentsOfDirectory`.
  private let scanDirectory: @MainActor () async -> Bool
  private let log: Logger

  /// Cached most-recent identity observed via the publisher. Used by
  /// `confirmCurrentDestination()` so the confirm-action path doesn't need
  /// a separate accessor closure.
  private var currentIdentity: DestinationIdentity = .unavailable
  /// Tracks the most recent evaluation so a late-arriving scan result for a
  /// stale destination doesn't overwrite the current one. Plain Int suffices
  /// because all writes happen on @MainActor.
  private var evaluationGeneration: Int = 0
  private var observation: AnyCancellable?

  init(
    identityPublisher: AnyPublisher<DestinationIdentity, Never>,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore,
    confirmationStore: any DestinationSafetyConfirmationStore,
    scanDirectory: @MainActor @escaping () async -> Bool,
    log: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "DestinationSafety")
  ) {
    self.identityPublisher = identityPublisher
    self.exportRecordStore = exportRecordStore
    self.collectionExportRecordStore = collectionExportRecordStore
    self.confirmationStore = confirmationStore
    self.scanDirectory = scanDirectory
    self.log = log
  }

  /// Convenience initializer that wires the production scan against
  /// `ExportDestinationManager.beginScopedAccess()` /
  /// `FileManager.contentsOfDirectory`. `PhotoExportApp` calls this; tests
  /// use the designated initializer with a stubbed `scanDirectory`.
  convenience init(
    destinationManager: ExportDestinationManager,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore,
    confirmationStore: any DestinationSafetyConfirmationStore
  ) {
    let log = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "DestinationSafety")
    let scan: @MainActor () async -> Bool = { @MainActor [weak destinationManager] in
      guard let dm = destinationManager, let scopedURL = dm.beginScopedAccess() else {
        return false
      }
      defer { dm.endScopedAccess(for: scopedURL) }
      do {
        let contents = try FileManager.default.contentsOfDirectory(
          at: scopedURL, includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles])
        return !contents.isEmpty
      } catch {
        log.warning(
          "Safety scan failed at \(scopedURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return false
      }
    }
    self.init(
      identityPublisher: destinationManager.$identity.eraseToAnyPublisher(),
      exportRecordStore: exportRecordStore,
      collectionExportRecordStore: collectionExportRecordStore,
      confirmationStore: confirmationStore,
      scanDirectory: scan,
      log: log
    )
  }

  /// Subscribe to destination changes. Call once from `PhotoExportApp.body`'s
  /// `.task` after the lifecycle coordinator has been attached, so the
  /// record stores have been `configure(for:)`d before we read their
  /// counts.
  func attach() {
    guard observation == nil else { return }
    observation =
      identityPublisher
      .removeDuplicates(by: { $0.stableId == $1.stableId })
      .receive(on: RunLoop.main)
      .sink { [weak self] identity in
        self?.currentIdentity = identity
        self?.evaluate(for: identity)
      }
  }

  /// User confirmed the destination's existing contents are theirs. Persist
  /// the confirmation and clear the flag.
  func confirmCurrentDestination() {
    guard let id = currentIdentity.stableId else { return }
    do {
      try confirmationStore.confirm(destinationId: id)
      log.info("User confirmed destination \(id, privacy: .public)")
    } catch {
      log.error(
        "Failed to persist safety confirmation for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    needsSafetyConfirmation = false
  }

  // MARK: - Private

  private func evaluate(for identity: DestinationIdentity) {
    evaluationGeneration += 1
    let gen = evaluationGeneration

    guard let id = identity.stableId else {
      needsSafetyConfirmation = false
      return
    }

    if confirmationStore.isConfirmed(destinationId: id) {
      needsSafetyConfirmation = false
      return
    }

    // Records present → user has used the app with this destination before;
    // no need to prompt. Lazy-evaluation: timeline store first, fall back to
    // collection store. Both checks are O(1) on in-memory data.
    let hasTimelineRecords = !exportRecordStore.recordsById.isEmpty
    let hasCollectionRecords = !collectionExportRecordStore.placements.isEmpty
    if hasTimelineRecords || hasCollectionRecords {
      needsSafetyConfirmation = false
      return
    }

    // Records empty — scan the destination directory. Async because the
    // scoped-access dance crosses an actor hop and the filesystem read
    // touches an external drive.
    Task { @MainActor [weak self] in
      guard let self else { return }
      let hasUserFiles = await self.scanDirectory()
      guard self.evaluationGeneration == gen else {
        // Stale generation — user already switched destinations.
        return
      }
      // Re-check the synchronous gates against the *post-scan* world. The
      // record stores can finish loading their JSONL during the slow
      // filesystem scan; if they did, the destination is no longer
      // "records empty" and we must not flag it. Same for confirmation:
      // the user might have confirmed via another path while we waited.
      if self.confirmationStore.isConfirmed(destinationId: id) {
        if self.needsSafetyConfirmation { self.needsSafetyConfirmation = false }
        return
      }
      let recordsNowPresent =
        !self.exportRecordStore.recordsById.isEmpty
        || !self.collectionExportRecordStore.placements.isEmpty
      if recordsNowPresent {
        if self.needsSafetyConfirmation { self.needsSafetyConfirmation = false }
        return
      }
      if self.needsSafetyConfirmation != hasUserFiles {
        self.needsSafetyConfirmation = hasUserFiles
      }
    }
  }
}
