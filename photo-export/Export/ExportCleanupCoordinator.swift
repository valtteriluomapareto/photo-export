import Foundation
import os

/// Drives the Danger Zone options' disk- and record-store passes: "Remove
/// deleted files" plus the folder-structure cleanup it implies (stale album
/// folders and empty directories). A `@MainActor`
/// collaborator in the same family as `ExportQueueCoordinator` /
/// `VariantExporter` / `ImportCoordinator`: ExportManager owns the *when* (each
/// pass runs inline in the run's enqueue Task, strictly before the drain loop
/// starts) and this type owns the *how*.
///
/// Ordering contract: every pass must complete before `processQueueIfNeeded()`
/// starts the drain for that run. Under that invariant the passes can never race
/// the exporters — the files and folders they delete belong to assets that are
/// no longer in the library (and therefore never queued), and the empty-folder
/// walk runs while no drain is active. The one exception window is a
/// `resume()` mid-bulk-enqueue starting the drain early; the empty-folder walk
/// guards on `!isRunning` for that and defers to the next run.
///
/// Cancellation: the same cooperative `generation` seam as the rest of the
/// pipeline, reached through the injected `ExportQueueCoordinator` reference
/// (issue #67 item 2). Each pass checks `isCurrent(gen)` before mutating
/// anything and between awaits; a stale pass returns a zero summary.
///
/// File deletion follows the record stores' two-phase reconcile pattern:
/// snapshot the deletion targets on the main actor, perform the IO off-main in
/// a detached task, then apply record-store mutations on the main actor.
@MainActor
final class ExportCleanupCoordinator {

  // MARK: - Scope

  /// The part of the destination a cleanup pass is responsible for. Shaped by
  /// what each enqueue path naturally has in hand: the fetched asset list and
  /// the placement being exported.
  ///
  /// `FolderCleanupScope` is the empty-folder walk's unit: one prunable
  /// subtree plus the **deletion ceiling** — the highest directory
  /// (inclusive, relative to the destination root) that this run may remove.
  /// The ceiling encodes the safe-deletion rule "only ever delete up to the
  /// node the export covers":
  /// - `ancestorCeiling == nil`: never prune above the subtree itself — an
  ///   Export Month stops at its month folder, an Export Year at its year
  ///   folder, a single-album export at that album's folder, Export Favorites
  ///   at the Favorites folder.
  /// - `ancestorCeiling == "Collections/Albums"`: Export All Albums may also
  ///   remove the Albums umbrella when it empties out (but never
  ///   `Collections` itself).
  /// - `ancestorCeiling == "Collections"`: the full-library run (Export All)
  ///   may remove the whole Collections umbrella — and never the destination
  ///   root, which is never a prunable node anywhere.
  struct FolderCleanupScope: Equatable {
    let subtree: String
    let ancestorCeiling: String?
  }
  enum CleanupScope {
    /// One timeline month. Existing ids come from that month's fetch.
    case timelineMonth(year: Int, month: Int, existingAssetIds: Set<String>)
    /// One timeline year (Export Year / Export All year iteration). The union
    /// of fetched ids protects assets whose record month doesn't match any
    /// fetched bucket edge case; the per-month buckets decide staleness for
    /// assets whose month drifted within the year.
    case timelineYear(
      year: Int, existingAssetIds: Set<String>, existingAssetIdsByMonth: [Int: Set<String>])
    /// One collection placement (favorites / album / shared album). Existing
    /// ids come from that scope's fetch — for an album this includes assets
    /// removed from the album but still in the library, so album membership is
    /// mirrored too.
    case collection(placement: ExportPlacement, existingAssetIds: Set<String>)
  }

  // MARK: - Dependencies

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportCleanup")
  /// Cancellation seam. Weak — same lifetime owner (`ExportManager`) as the
  /// other collaborators holding it (issue #67 item 2 pattern).
  private weak var queueCoordinator: ExportQueueCoordinator?
  private let recordStoreRouter: RecordStoreRouter
  private let exportDestination: any ExportDestination
  private let fileSystem: any FileSystemService

  init(
    queueCoordinator: ExportQueueCoordinator,
    recordStoreRouter: RecordStoreRouter,
    exportDestination: any ExportDestination,
    fileSystem: any FileSystemService
  ) {
    self.queueCoordinator = queueCoordinator
    self.recordStoreRouter = recordStoreRouter
    self.exportDestination = exportDestination
    self.fileSystem = fileSystem
  }

  /// Maps every album/shared-album local identifier in `tree` to the
  /// placement id the resolver would compute for its **current** path
  /// (`ExportPlacementResolver.candidatePlacementId`). A persisted placement
  /// whose id is absent from this map's values (or whose collection id has no
  /// entry at all — deleted album) is stale. Shared by
  /// `removeStaleAlbumPlacements` and the full-library reconcile's filters.
  static func livePlacementIds(
    in tree: [PhotoCollectionDescriptor]
  ) -> [String: String] {
    var map: [String: String] = [:]
    func walk(_ descriptors: [PhotoCollectionDescriptor]) {
      for descriptor in descriptors {
        if let collectionId = descriptor.localIdentifier,
          !collectionId.isEmpty,
          let candidateId = ExportPlacementResolver.candidatePlacementId(for: descriptor)
        {
          map[collectionId] = candidateId
        }
        walk(descriptor.children)
      }
    }
    walk(tree)
    return map
  }

  // MARK: - Remove deleted files

  /// Deletes the on-disk files and record-store entries of every recorded
  /// asset under `scope` that no longer appears in the fetched library
  /// snapshot. Runs inline in the enqueue Task *after* the scope's assets were
  /// fetched and *before* its jobs are queued.
  ///
  /// Only `.done` variants own files; a stale record with `.failed` /
  /// `.inProgress` variants has nothing to delete on disk, but its record is
  /// still removed — an asset missing from the library can never be retried.
  func removeDeletedAssets(
    in scope: CleanupScope, generation gen: Int
  ) async -> ExportCleanupSummary {
    guard let queueCoordinator, queueCoordinator.isCurrent(gen) else { return .zero }

    // Phase 1 (main): snapshot the stale entries as deletion targets.
    struct StaleEntry {
      let assetId: String
      let placement: ExportPlacement
      let variants: [ExportVariant: ExportVariantRecord]
    }
    var stale: [StaleEntry] = []
    switch scope {
    case .timelineMonth(let year, let month, let existingAssetIds):
      let placement = ExportPlacement.timeline(year: year, month: month)
      let recorded = recordStoreRouter.recordedVariantsByAsset(placement: placement)
      for (assetId, variants) in recorded where !existingAssetIds.contains(assetId) {
        stale.append(StaleEntry(assetId: assetId, placement: placement, variants: variants))
      }
    case .timelineYear(let year, let existingAssetIds, let existingAssetIdsByMonth):
      for entry in recordStoreRouter.timelineRecordedAssets(year: year) {
        let inUnion = existingAssetIds.contains(entry.assetId)
        let inBucket = existingAssetIdsByMonth[entry.month]?.contains(entry.assetId) ?? false
        if !(inUnion && inBucket) {
          stale.append(
            StaleEntry(
              assetId: entry.assetId,
              placement: ExportPlacement.timeline(year: entry.year, month: entry.month),
              variants: entry.variants))
        }
      }
    case .collection(let placement, let existingAssetIds):
      let recorded = recordStoreRouter.recordedVariantsByAsset(placement: placement)
      for (assetId, variants) in recorded where !existingAssetIds.contains(assetId) {
        stale.append(StaleEntry(assetId: assetId, placement: placement, variants: variants))
      }
    }
    guard !stale.isEmpty else { return .zero }
    guard queueCoordinator.isCurrent(gen) else { return .zero }

    // Phase 2 (off-main): delete the `.done` variants' files.
    let removedFiles = await deleteRecordedFiles(
      for: stale.map { (placement: $0.placement, variants: $0.variants) }, generation: gen)
    guard queueCoordinator.isCurrent(gen) else { return .zero }

    // Phase 3 (main): remove the records wholesale.
    for entry in stale {
      recordStoreRouter.removeRecord(assetId: entry.assetId, placement: entry.placement)
    }
    logger.info(
      "Removed deleted assets: \(removedFiles) file(s), \(stale.count) record(s) in scope"
    )
    return ExportCleanupSummary(
      removedFiles: removedFiles, removedRecords: stale.count, removedFolders: 0)
  }

  // MARK: - Folder-structure cleanup (stale-album half)

  /// Deletes the folder, files, records, and placement metadata of the
  /// *candidate* collection placements whose source album no longer exists in
  /// the fetched collection tree. Part of the automatic folder-structure
  /// cleanup ("Remove deleted files" implies it); the empty-directory half is
  /// `removeEmptyFolders(subtrees:)`.
  ///
  /// **Scope contract:** the caller filters the candidates to what the current
  /// run's export type covers — a single-album run passes only that album's
  /// placement, an Export All Albums run every `.album` placement, an Export
  /// Folder run only placements under that folder's on-disk subtree. A run
  /// never judges placements outside its own scope. Favorites is synthetic
  /// (no `PHAssetCollection`) and never matches; renamed or moved albums still
  /// exist, so their old placements stay until a future stale-path refinement.
  ///
  /// Stale placements remain collision claimants while they exist (the
  /// resolver counts them as live so a reinstated album can't silently steal a
  /// path) — running this pass *before* placement resolution lets a reinstated
  /// album reclaim its bare path.
  func removeStaleAlbumPlacements(
    candidates: [ExportPlacement], tree: [PhotoCollectionDescriptor],
    ancestorCeiling: String?, generation gen: Int
  ) async -> ExportCleanupSummary {
    guard let queueCoordinator, queueCoordinator.isCurrent(gen) else { return .zero }

    let liveIds = Self.livePlacementIds(in: tree)
    let liveSharedAlbumIds = Set(PhotoCollectionDescriptor.sharedAlbumLocalIds(in: tree))

    struct StalePlacement {
      let placement: ExportPlacement
      let recordCount: Int
      let variantsByAsset: [String: [ExportVariant: ExportVariantRecord]]
    }
    var stale: [StalePlacement] = []
    for placement in candidates {
      guard
        let collectionId = placement.collectionLocalIdentifier,
        !collectionId.isEmpty
      else { continue }
      let isLive: Bool
      switch placement.kind {
      case .album, .sharedAlbum:
        // Live = the album still exists AND its placement id still matches
        // the id the resolver would compute for the album's current path. A
        // moved or renamed album keeps its collection id but produces a
        // different path hash, so its old placement counts as stale and its
        // old folder is cleaned up; the album re-exports at the new location
        // on the next run of that album.
        isLive = liveIds[collectionId] == placement.id
      case .timeline, .favorites:
        continue
      }
      if !isLive {
        stale.append(
          StalePlacement(
            placement: placement,
            recordCount: recordStoreRouter.collectionRecordCount(placementId: placement.id),
            variantsByAsset: recordStoreRouter.recordedVariantsByAsset(placement: placement)))
      }
    }
    guard !stale.isEmpty else { return .zero }
    guard queueCoordinator.isCurrent(gen) else { return .zero }

    // Files of every recorded variant, then the placement folder itself.
    let removedFiles = await deleteRecordedFiles(
      for: stale.flatMap { entry in
        entry.variantsByAsset.map { (placement: entry.placement, variants: $0.value) }
      },
      generation: gen)
    var removedFolders = 0
    if let root = exportDestination.selectedFolderURL {
      for entry in stale {
        let folderURL = root.appendingPathComponent(entry.placement.relativePath)
        if fileSystem.fileExists(atPath: folderURL.path) {
          do {
            try fileSystem.trashItem(at: folderURL)
            removedFolders += 1
            // Bottom-up but never past the run's deletion ceiling: empty
            // umbrellas above the removed album folder go too (for Export All
            // Albums up to `Collections/Albums`, for the full run up to
            // `Collections`), umbrellas with content stay, and a
            // single-album run passes no ceiling at all.
            if let ancestorCeiling {
              removedFolders += Self.pruneEmptyAncestors(
                of: folderURL, destinationRoot: root,
                ceilingPath: root.appendingPathComponent(ancestorCeiling),
                fileSystem: fileSystem)
            }
          } catch {
            logger.error(
              "Could not remove stale album folder \(entry.placement.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
      }
    }

    // Records + placement metadata last, so a cancelled pass leaves the store
    // pointing at files that still exist.
    var removedRecords = 0
    for entry in stale {
      recordStoreRouter.removePlacement(id: entry.placement.id, kind: entry.placement.kind)
      removedRecords += max(1, entry.recordCount)
    }
    logger.info(
      "Removed stale album placements: \(stale.count) folder(s), \(removedFiles) file(s), \(removedRecords) record(s)"
    )
    return ExportCleanupSummary(
      removedFiles: removedFiles,
      removedRecords: removedRecords,
      removedFolders: removedFolders)
  }

  // MARK: - Folder-structure cleanup (empty-directory half)

  /// Removes empty directories bottom-up, but **only inside the subtrees the
  /// current run's export scope covers** (relative to the destination root —
  /// e.g. `2025/07` for an Export Month, `Collections/Albums/Trip/` for an
  /// album run) **plus their now-empty ancestor directories up to the
  /// destination root** — so an emptied `Collections/Albums/Trip/` also takes
  /// the empty `Collections/Albums/` and `Collections/` umbrellas with it.
  /// Ancestors that still contain anything (files, other scopes' folders) are
  /// kept, which is what preserves the type-scoping guarantee: a run never
  /// prunes another export type's *content*, only umbrellas that have become
  /// genuinely empty. The destination root itself is never removed. The
  /// subtree roots count as prunable — an emptied month folder disappears.
  ///
  /// Runs after a run's enqueue/cleanup phase and only while no drain is
  /// active: a drain that is writing files would race the walk (the walk could
  /// delete a folder the exporter just created but hasn't written into yet).
  /// When a drain is detected the pass defers to the next run — empty-folder
  /// removal is idempotent, so nothing is lost.
  func removeEmptyFolders(
    scopes: [FolderCleanupScope], generation gen: Int
  ) async -> ExportCleanupSummary {
    guard let queueCoordinator, queueCoordinator.isCurrent(gen) else { return .zero }
    guard !queueCoordinator.isRunning else {
      logger.info("Skipping empty-folder cleanup: export queue is running")
      return .zero
    }
    guard let root = exportDestination.selectedFolderURL else { return .zero }
    // Dedupe (first scope for a subtree wins) + drop subtrees that don't
    // exist (nothing to prune, and the enumerator would report nothing
    // anyway — the filter just avoids pointless scoped-access work).
    var seen = Set<String>()
    let scopesWithRoots: [(subtree: URL, ancestorCeiling: String?)] = scopes
      .filter { seen.insert($0.subtree).inserted }
      .compactMap { scope in
        let url = root.appendingPathComponent(scope.subtree)
        return fileSystem.fileExists(atPath: url.path) ? (url, scope.ancestorCeiling) : nil
      }
    guard !scopesWithRoots.isEmpty else { return .zero }

    _ = exportDestination.beginScopedAccess()
    defer { exportDestination.endScopedAccess(for: root) }

    struct FolderWalkResult {
      let removedFolders: Int
    }
    let result: FolderWalkResult = await Task.detached(priority: .utility) { [fileSystem] in
      let fm = FileManager.default
      // A folder counts as empty when it holds nothing but dotfiles
      // (`.DS_Store` and friends): Finder writes those the moment the user
      // browses the backup, and without this rule a browsed folder would
      // never qualify as empty. Hidden metadata is deleted with the folder.
      func isEffectivelyEmpty(_ entries: [String]) -> Bool {
        entries.allSatisfy { $0.hasPrefix(".") }
      }
      // Collect every directory inside each subtree — including the subtree
      // root itself, so an emptied scope folder (a fully-deleted month, say)
      // disappears — plus each subtree's ancestor chain, but only up to the
      // scope's deletion ceiling (nil = no ancestor pruning at all). Then
      // delete empty ones deepest-first: sorting by path length descending
      // processes children before their parents, so a parent emptied by its
      // children's deletion is itself empty by the time the walk reaches it.
      // Ancestors with remaining content fail the emptiness check and stay.
      var directories: [URL] = []
      var seenPaths = Set<String>()
      func collect(_ url: URL) {
        if seenPaths.insert(url.path).inserted {
          directories.append(url)
        }
      }
      for scope in scopesWithRoots {
        let subtreeRoot = scope.subtree
        collect(subtreeRoot)
        let enumerator = fm.enumerator(
          at: subtreeRoot,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [],
          errorHandler: nil
        )
        while let item = enumerator?.nextObject() as? URL {
          if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            collect(item)
          }
        }
        if let ceiling = scope.ancestorCeiling {
          let ceilingPath = root.appendingPathComponent(ceiling).path
          var ancestor = subtreeRoot.deletingLastPathComponent()
          while ancestor.path != root.path && ancestor.path.hasPrefix(root.path) {
            guard ancestor.path == ceilingPath || ancestor.path.hasPrefix(ceilingPath + "/")
            else { break }
            collect(ancestor)
            ancestor = ancestor.deletingLastPathComponent()
          }
        }
      }
      var removed = 0
      for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        guard isEffectivelyEmpty(contents) else { continue }
        do {
          try fileSystem.trashItem(at: directory)
          removed += 1
        } catch {
          // Leave the folder in place; the next run's walk retries.
        }
      }
      return FolderWalkResult(removedFolders: removed)
    }.value

    logger.info("Empty-folder cleanup removed \(result.removedFolders) folder(s)")
    return ExportCleanupSummary(
      removedFiles: 0, removedRecords: 0, removedFolders: result.removedFolders)
  }

  // MARK: - Shared helpers

  /// Removes the now-empty ancestor directories of `removedFolder`, bottom-up,
  /// stopping at (not including) `destinationRoot` and never going **above
  /// `ceilingPath`** — the run's deletion ceiling (inclusive: the ceiling
  /// folder itself may be removed when empty). An ancestor with any remaining
  /// content — including folders belonging to other export scopes — stops the
  /// walk. Runs on the calling (main) actor: a stale-album pass removes at
  /// most a handful of folders, so the handful of `contentsOfDirectory` calls
  /// is negligible next to the removals already performed.
  nonisolated static func pruneEmptyAncestors(
    of removedFolder: URL, destinationRoot root: URL,
    ceilingPath: URL, fileSystem: any FileSystemService
  ) -> Int {
    var removed = 0
    let rootPath = root.path
    let ceiling = ceilingPath.path
    var parent = removedFolder.deletingLastPathComponent()
    while parent.path != rootPath && parent.path.hasPrefix(rootPath) {
      // Never prune above the ceiling (the ceiling itself is the last
      // prunable node).
      guard parent.path == ceiling || parent.path.hasPrefix(ceiling + "/") else { break }
      let contents =
        (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? ["keep"]
      // Dotfile-only folders (.DS_Store from Finder browsing) count as empty —
      // same rule as the empty-folder walk.
      guard contents.allSatisfy({ $0.hasPrefix(".") }) else { break }
      do {
        try fileSystem.trashItem(at: parent)
        removed += 1
      } catch {
        break
      }
      parent = parent.deletingLastPathComponent()
    }
    return removed
  }

  /// Deletes every `.done` variant's backing file for the given
  /// `(placement, variants)` pairs. Resolves each variant's on-disk location
  /// from its own persisted `subfolder` (issue #38) under its placement, so a
  /// mid-life `videoLayout`-toggle record is found where the writer put it.
  /// Corrupt `.done` entries with a `nil` filename contribute nothing (there
  /// is no path to delete) — record removal handles them.
  private func deleteRecordedFiles(
    for placementsWithVariants: [(
      placement: ExportPlacement, variants: [ExportVariant: ExportVariantRecord]
    )],
    generation gen: Int
  ) async -> Int {
    guard let root = exportDestination.selectedFolderURL else { return 0 }
    _ = exportDestination.beginScopedAccess()
    defer { exportDestination.endScopedAccess(for: root) }

    var targets: [URL] = []
    for (placement, variants) in placementsWithVariants {
      for (_, variantRecord) in variants where variantRecord.status == .done {
        guard let filename = variantRecord.filename, !filename.isEmpty else { continue }
        let dirRelPath = ExportPlacementPathPolicy.relativePath(
          placement: placement, subfolder: variantRecord.subfolder)
        targets.append(
          root.appendingPathComponent(dirRelPath).appendingPathComponent(filename))
      }
    }
    guard !targets.isEmpty else { return 0 }
    guard let queueCoordinator, queueCoordinator.isCurrent(gen) else { return 0 }

    let targetsCopy = targets
    return await Task.detached(priority: .utility) { [fileSystem] in
      var removed = 0
      for url in targetsCopy {
        do {
          try fileSystem.trashItem(at: url)
          removed += 1
        } catch {
          // A missing file is the expected no-op for a stale record whose
          // backing file vanished earlier; anything else surfaces in the
          // caller's log via the summary shortfall.
        }
      }
      return removed
    }.value
  }
}
