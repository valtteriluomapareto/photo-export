import Foundation
import os

/// Resolves a `BackupCollectionScanner.CollectionScanGroup` to a real
/// `ExportPlacement` by joining over three sets:
///
/// 1. **Existing placements** in `CollectionExportRecordStore.placements` —
///    authoritative because they encode the user's prior sibling-collision
///    decisions. A scanner leaf path that byte-equals an existing placement's
///    `relativePath` reuses that placement unchanged.
/// 2. **The current PhotoKit collection tree** — searched by sanitized
///    `(pathComponents, title)` equality. When exactly one album (or shared
///    album) matches, a fresh placement is constructed via the production
///    `ExportPlacementResolver`.
/// 3. **Orphan** — the leaf has no PhotoKit equivalent, or multiple PhotoKit
///    collections sanitize to the same leaf, or the resolver returned a
///    `relativePath` whose leaf disagrees with the on-disk leaf (a
///    sibling-collision conflict that would silently misroute records).
///
/// Pure with respect to its inputs: same `(group, photoCollections,
/// existingPlacements)` triple always yields the same outcome. The matcher
/// does not write to the store; the caller upserts the resulting placement.
///
/// Issue #106 — Import Existing Backup for `Collections/`.
struct BackupCollectionPlacementMatcher {

  // MARK: - Result types

  enum MatchResult: Equatable {
    /// Reused from `existingPlacements`. The placement's `createdAt` and
    /// `relativePath` are unchanged from disk.
    case existing(ExportPlacement)
    /// Newly constructed via the resolver. The placement's `id` equals what
    /// the next real export of the same album would produce.
    case fresh(ExportPlacement)
    /// No usable placement; the group's files contribute to the import
    /// report's `unmatched` bucket.
    case orphan(OrphanReason)
  }

  enum OrphanReason: Equatable {
    /// The on-disk leaf has no PhotoKit equivalent (album deleted, or never
    /// existed in this library).
    case noPhotoKitCollection
    /// The scanner emitted a shared-album group with non-empty
    /// `parentPathComponents`. PhotoKit does not allow nested shared albums;
    /// the on-disk shape is corrupt or hand-edited.
    case sharedAlbumNestedUnderFolder
    /// The resolver returned a placement whose `relativePath` last segment
    /// disagrees with the scanner's on-disk leaf. Happens when a fresh
    /// placement's sibling-collision suffix would land it somewhere other
    /// than where the files are. Carrying both names so the diagnostic
    /// report can show the user *why* the folder was skipped.
    case resolverDisagreesWithOnDiskLeaf(onDisk: String, resolved: String)
    /// More than one PhotoKit collection sanitizes to the leaf path
    /// (sanitization is non-injective — e.g. "Trip:" and "Trip_" both map
    /// to "Trip_"). Auto-tie-break would silently favor one rename history
    /// over another, so we refuse and let the user disambiguate.
    case ambiguousPhotoKitMatch(candidateIds: [String])
  }

  // MARK: - Dependencies

  private let resolver: ExportPlacementResolver
  private let logger: Logger

  init(
    resolver: ExportPlacementResolver = ExportPlacementResolver(),
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "BackupCollectionPlacementMatcher")
  ) {
    self.resolver = resolver
    self.logger = logger
  }

  // MARK: - Entry point

  func match(
    group: BackupCollectionScanner.CollectionScanGroup,
    photoCollections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> MatchResult {
    switch group.kind {
    case .favorites:
      return matchFavorites(existingPlacements: existingPlacements)
    case .album:
      return matchAlbum(
        group: group, photoCollections: photoCollections,
        existingPlacements: existingPlacements)
    case .sharedAlbum:
      return matchSharedAlbum(
        group: group, photoCollections: photoCollections,
        existingPlacements: existingPlacements)
    }
  }

  // MARK: - Favorites

  private func matchFavorites(existingPlacements: [ExportPlacement]) -> MatchResult {
    if let existing = existingPlacements.first(where: { $0.kind == .favorites }) {
      return .existing(existing)
    }
    return .fresh(ExportPlacement.favorites())
  }

  // MARK: - Albums

  private func matchAlbum(
    group: BackupCollectionScanner.CollectionScanGroup,
    photoCollections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> MatchResult {
    let onDiskRelPath = albumsRelativePath(
      parent: group.parentPathComponents, leaf: group.leafName)

    // Step 1: byte-equal existing-placement lookup. Authoritative — it encodes the
    // user's prior collision-suffix assignment, even if the underlying album has
    // since been deleted or renamed in PhotoKit.
    let existingMatches = existingPlacements.filter {
      $0.kind == .album && $0.relativePath == onDiskRelPath
    }
    if existingMatches.count == 1 {
      return .existing(existingMatches[0])
    }
    if existingMatches.count > 1 {
      logger.warning(
        "Multiple existing album placements at \(onDiskRelPath, privacy: .public); picking latest createdAt"
      )
      let latest = existingMatches.max(by: { $0.createdAt < $1.createdAt })!
      return .existing(latest)
    }

    // Step 2: sanitized-title search across the PhotoKit album tree.
    let candidates = photoKitAlbums(in: photoCollections).filter { descriptor in
      let parentSanitized = descriptor.pathComponents.map(ExportPathPolicy.sanitizeComponent)
      let leafSanitized = ExportPathPolicy.sanitizeComponent(descriptor.title)
      return parentSanitized == group.parentPathComponents
        && leafSanitized == group.leafName
    }

    if candidates.isEmpty {
      return .orphan(.noPhotoKitCollection)
    }
    if candidates.count > 1 {
      let ids = candidates.compactMap(\.localIdentifier).sorted()
      return .orphan(.ambiguousPhotoKitMatch(candidateIds: ids))
    }

    let descriptor = candidates[0]
    guard let collectionId = descriptor.localIdentifier else {
      // Defensive — `.album` always carries a PhotoKit identifier in production.
      return .orphan(.noPhotoKitCollection)
    }

    // Step 3: ask the resolver to construct a fresh placement. The resolver
    // consults sibling claimants and may assign a different leaf suffix than
    // what's on disk; the path-equality guard below catches that.
    let resolved: ExportPlacement
    do {
      resolved = try resolver.placement(
        for: .album(collectionId: collectionId),
        collections: photoCollections,
        existingPlacements: existingPlacements)
    } catch {
      logger.error(
        "Resolver refused album \(collectionId, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return .orphan(.noPhotoKitCollection)
    }

    if resolved.relativePath == onDiskRelPath {
      return .fresh(resolved)
    }
    return .orphan(
      .resolverDisagreesWithOnDiskLeaf(
        onDisk: onDiskRelPath, resolved: resolved.relativePath))
  }

  // MARK: - Shared albums

  private func matchSharedAlbum(
    group: BackupCollectionScanner.CollectionScanGroup,
    photoCollections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> MatchResult {
    if !group.parentPathComponents.isEmpty {
      return .orphan(.sharedAlbumNestedUnderFolder)
    }

    let onDiskRelPath = sharedAlbumsRelativePath(leaf: group.leafName)

    let existingMatches = existingPlacements.filter {
      $0.kind == .sharedAlbum && $0.relativePath == onDiskRelPath
    }
    if existingMatches.count == 1 {
      return .existing(existingMatches[0])
    }
    if existingMatches.count > 1 {
      logger.warning(
        "Multiple existing shared-album placements at \(onDiskRelPath, privacy: .public); picking latest createdAt"
      )
      let latest = existingMatches.max(by: { $0.createdAt < $1.createdAt })!
      return .existing(latest)
    }

    // Shared albums never nest under user folders, so candidates are top-level only.
    let candidates = photoCollections.filter { descriptor in
      guard descriptor.kind == .sharedAlbum else { return false }
      return ExportPathPolicy.sanitizeComponent(descriptor.title) == group.leafName
    }

    if candidates.isEmpty {
      return .orphan(.noPhotoKitCollection)
    }
    if candidates.count > 1 {
      let ids = candidates.compactMap(\.localIdentifier).sorted()
      return .orphan(.ambiguousPhotoKitMatch(candidateIds: ids))
    }

    let descriptor = candidates[0]
    guard let collectionId = descriptor.localIdentifier else {
      return .orphan(.noPhotoKitCollection)
    }

    let resolved: ExportPlacement
    do {
      resolved = try resolver.placement(
        for: .sharedAlbum(collectionId: collectionId),
        collections: photoCollections,
        existingPlacements: existingPlacements)
    } catch {
      logger.error(
        "Resolver refused shared album \(collectionId, privacy: .public): \(String(describing: error), privacy: .public)"
      )
      return .orphan(.noPhotoKitCollection)
    }

    if resolved.relativePath == onDiskRelPath {
      return .fresh(resolved)
    }
    return .orphan(
      .resolverDisagreesWithOnDiskLeaf(
        onDisk: onDiskRelPath, resolved: resolved.relativePath))
  }

  // MARK: - Helpers

  private func albumsRelativePath(parent: [String], leaf: String) -> String {
    ExportPlacementPathPolicy.collectionLeafRelativePath(
      kind: .album, parentPathComponents: parent, leafName: leaf)
  }

  private func sharedAlbumsRelativePath(leaf: String) -> String {
    ExportPlacementPathPolicy.collectionLeafRelativePath(
      kind: .sharedAlbum, parentPathComponents: [], leafName: leaf)
  }

  /// Recursively collects every `.album` descriptor in the PhotoKit tree,
  /// walking through `.folder` nodes. `.favorites` and `.sharedAlbum` are
  /// excluded (separate matchers handle them).
  private func photoKitAlbums(
    in tree: [PhotoCollectionDescriptor]
  ) -> [PhotoCollectionDescriptor] {
    var result: [PhotoCollectionDescriptor] = []
    for descriptor in tree {
      switch descriptor.kind {
      case .album:
        result.append(descriptor)
      case .folder:
        result.append(contentsOf: photoKitAlbums(in: descriptor.children))
      case .favorites, .sharedAlbum:
        continue
      }
    }
    return result
  }
}
