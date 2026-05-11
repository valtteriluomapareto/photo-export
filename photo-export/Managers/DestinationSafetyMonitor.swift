import Combine
import Foundation
import os

/// Phase 0b safety scan. Observes the destination fingerprint and detects the
/// "destination has files but no matching records" state. Surfaces it as
/// `@Published needsSafetyConfirmation`, which `DestinationSnapshotAdapter`
/// folds into the `DestinationSnapshot.safety` field as
/// `.unsafeNeedsConfirmation`.
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

  private let destinationManager: ExportDestinationManager
  private let exportRecordStore: ExportRecordStore
  private let collectionExportRecordStore: CollectionExportRecordStore
  private let confirmationStore: any DestinationSafetyConfirmationStore
  private let log: Logger

  /// Tracks the most recent evaluation so a late-arriving scan result for a
  /// stale destination doesn't overwrite the current one. Plain Int suffices
  /// because all writes happen on @MainActor.
  private var evaluationGeneration: Int = 0
  private var observation: AnyCancellable?

  init(
    destinationManager: ExportDestinationManager,
    exportRecordStore: ExportRecordStore,
    collectionExportRecordStore: CollectionExportRecordStore,
    confirmationStore: any DestinationSafetyConfirmationStore,
    log: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "DestinationSafety")
  ) {
    self.destinationManager = destinationManager
    self.exportRecordStore = exportRecordStore
    self.collectionExportRecordStore = collectionExportRecordStore
    self.confirmationStore = confirmationStore
    self.log = log
  }

  /// Subscribe to destination changes. Call once from `PhotoExportApp.body`'s
  /// `.task` after the lifecycle coordinator has been attached, so the
  /// record stores have been `configure(for:)`d before we read their
  /// counts.
  func attach() {
    guard observation == nil else { return }
    observation =
      destinationManager.$destinationFingerprint
      .removeDuplicates(by: { $0?.id == $1?.id })
      .receive(on: RunLoop.main)
      .sink { [weak self] fingerprint in
        self?.evaluate(for: fingerprint)
      }
    // Initial evaluation against the current fingerprint.
    evaluate(for: destinationManager.destinationFingerprint)
  }

  /// User confirmed the destination's existing contents are theirs. Persist
  /// the confirmation and clear the flag.
  func confirmCurrentDestination() {
    guard let id = destinationManager.destinationFingerprint?.id else { return }
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

  private func evaluate(for fingerprint: DestinationFingerprint?) {
    evaluationGeneration += 1
    let gen = evaluationGeneration

    guard let id = fingerprint?.id else {
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
      let presence = await self.scanDestinationDirectory()
      guard self.evaluationGeneration == gen else {
        // Stale generation — user already switched destinations.
        return
      }
      let flag = (presence == .hasUserFiles)
      if self.needsSafetyConfirmation != flag {
        self.needsSafetyConfirmation = flag
      }
    }
  }

  private enum Presence: Equatable {
    case empty
    case hasUserFiles
  }

  private func scanDestinationDirectory() async -> Presence {
    guard let scopedURL = destinationManager.beginScopedAccess() else {
      return .empty
    }
    defer { destinationManager.endScopedAccess(for: scopedURL) }
    do {
      let contents = try FileManager.default.contentsOfDirectory(
        at: scopedURL, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])
      // `.skipsHiddenFiles` filters `.DS_Store` and similar; if anything
      // remains, treat as user content.
      return contents.isEmpty ? .empty : .hasUserFiles
    } catch {
      log.warning(
        "Safety scan failed at \(scopedURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      // On scan failure, don't flag — the user can't act on a transient I/O
      // error, and AutoSync will still gate on isAvailable / safety
      // elsewhere if the destination is actually unreadable.
      return .empty
    }
  }
}
