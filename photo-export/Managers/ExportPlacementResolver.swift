import CryptoKit
import Foundation
import os

/// Maps a `LibrarySelection` to an `ExportPlacement`.
///
/// The only code that produces `ExportPlacement` values for collection-side selections
/// in production. Pure with respect to its inputs: same `(selection, collections,
/// existingPlacements)` triple always yields the same placement.
///
/// Identity rules (per `docs/project/plans/collections-export-plan.md` §"Placement IDs"):
/// - Timeline: `timeline:<YYYY>-<MM>`. The synthetic constructor on `ExportPlacement`
///   already handles this; the resolver is only consulted for collection selections.
/// - Favorites: fixed `collections:favorites`.
/// - Album: `collections:album:<collectionIdHash16>:<displayPathHash8>` where
///   `collectionIdHash16` is the first 16 hex chars of `SHA256(collectionLocalIdentifier)`
///   and `displayPathHash8` is the first 8 hex chars of `SHA256(parentPath || U+0000 ||
///   title)`. The path-hash makes the id change when the album is renamed or moved
///   between folders so the next export resolves to a fresh placement.
///
/// Sibling-collision disambiguation (per §"Path Policy → Disambiguation"):
/// - Two distinct placements that, after sanitization, would have the same full path
///   under the same parent folder under `Collections/Albums/` are *sibling collisions*.
/// - First claimant keeps the bare path; new placements get `_2`, `_3`, … suffixes.
/// - Stale placements from deleted albums count as live claimants so a reinstated album
///   doesn't silently steal a path.
/// - For two newly-discovered colliding albums (no existing record for either), sort
///   lexicographically by `collectionLocalIdentifier` and give the bare path to the
///   first.
struct ExportPlacementResolver {
  enum ResolutionError: Error, Equatable {
    /// `LibrarySelection.album(collectionId:)` referenced an id that is not present in
    /// the supplied `collections` tree (album was deleted or never existed).
    case albumNotFound(collectionId: String)
    /// `LibrarySelection.folder(...)` was passed to the resolver. Folders are not
    /// directly placed — `ExportManager.startExportFolder(folderId:)` walks the subtree
    /// and resolves each descendant album individually. Surfaced as an error so a stray
    /// callsite is loud rather than silently producing a malformed placement.
    case folderNotResolvable(collectionId: String)
  }

  private let logger: Logger
  private let now: () -> Date

  init(
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "PlacementResolver"),
    now: @escaping () -> Date = Date.init
  ) {
    self.logger = logger
    self.now = now
  }

  /// Resolves a placement for a selection. See type-level comment for identity rules and
  /// collision policy.
  func placement(
    for selection: LibrarySelection,
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) throws -> ExportPlacement {
    switch selection {
    case .timelineMonth(let year, let month):
      return ExportPlacement.timeline(year: year, month: month, createdAt: now())

    case .favorites:
      return ExportPlacement.favorites(createdAt: now())

    case .album(let collectionId):
      guard let descriptor = findAlbum(collectionId: collectionId, in: collections) else {
        throw ResolutionError.albumNotFound(collectionId: collectionId)
      }
      return resolveAlbum(
        descriptor: descriptor,
        collections: collections,
        existingPlacements: existingPlacements
      )

    case .folder(let collectionId):
      throw ResolutionError.folderNotResolvable(collectionId: collectionId)
    }
  }

  // MARK: - Album resolution

  private func resolveAlbum(
    descriptor: PhotoCollectionDescriptor,
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> ExportPlacement {
    let collectionId = descriptor.localIdentifier ?? ""
    let displayPathHash = displayPathHash8(
      pathComponents: descriptor.pathComponents, title: descriptor.title)
    let candidateId =
      "collections:album:\(collectionIdHash16(for: collectionId)):\(displayPathHash)"

    // Step 1: look for an existing placement that matches this exact triple
    // `(kind=.album, collectionLocalIdentifier, displayPathHash8)`. If found, return it
    // unchanged so callers see the persisted createdAt and relativePath.
    let matches = existingPlacements.filter {
      $0.kind == .album && $0.collectionLocalIdentifier == collectionId
        && $0.id.hasSuffix(":\(displayPathHash)")
    }
    if matches.count == 1 {
      return matches[0]
    } else if matches.count > 1 {
      // Defensive: shouldn't happen but a buggy past write could produce duplicates.
      // Pick the latest createdAt and log so the issue surfaces.
      logger.warning(
        "Found \(matches.count) placements matching collection \(collectionId, privacy: .public) with displayPathHash \(displayPathHash, privacy: .public); picking latest createdAt"
      )
      let latest = matches.max(by: { $0.createdAt < $1.createdAt })!
      return latest
    }

    // Step 2: build the candidate relative path and check for sibling collisions.
    let parentPathString = sanitizedFolderPath(descriptor.pathComponents)
    let sanitizedLeaf = ExportPathPolicy.sanitizeComponent(descriptor.title)
    let leaf = leafWithCollisionSuffix(
      sanitizedLeaf: sanitizedLeaf,
      parentPathString: parentPathString,
      forDescriptor: descriptor,
      collections: collections,
      existingPlacements: existingPlacements
    )
    let relativePath: String = {
      var path = "Collections/Albums/"
      if !parentPathString.isEmpty {
        path += parentPathString + "/"
      }
      return path + leaf + "/"
    }()
    let displayName: String = {
      if descriptor.pathComponents.isEmpty { return descriptor.title }
      return descriptor.pathComponents.joined(separator: "/") + "/" + descriptor.title
    }()
    return ExportPlacement(
      kind: .album,
      id: candidateId,
      displayName: displayName,
      collectionLocalIdentifier: collectionId,
      relativePath: relativePath,
      createdAt: now()
    )
  }

  // MARK: - Sibling-collision logic

  /// Returns the leaf name to use for the album, applying a `_2`/`_3`/… suffix when a
  /// sibling collision with an existing or sibling new album would otherwise produce the
  /// same on-disk folder.
  private func leafWithCollisionSuffix(
    sanitizedLeaf: String,
    parentPathString: String,
    forDescriptor descriptor: PhotoCollectionDescriptor,
    collections: [PhotoCollectionDescriptor],
    existingPlacements: [ExportPlacement]
  ) -> String {
    // Existing claimants: any existing placement under the same parent folder whose
    // leaf matches the candidate (with or without an existing suffix). We compare on
    // the *sanitized* leaf component because users see and pick by that.
    let existingLeaves =
      existingPlacements
      .filter { $0.kind == .album }
      .compactMap { existing -> String? in
        // Strip the leading "Collections/Albums/" and trailing "/", then split.
        // Compare parent path; if it matches our candidate parent, the last
        // segment is a sibling leaf.
        let prefix = "Collections/Albums/"
        guard existing.relativePath.hasPrefix(prefix) else { return nil }
        var trimmed = String(existing.relativePath.dropFirst(prefix.count))
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
          .map(String.init)
        guard let leaf = parts.last else { return nil }
        let parent = parts.dropLast().joined(separator: "/")
        return parent == parentPathString ? leaf : nil
      }

    // New (not-yet-existing) sibling claimants from the collection tree: other albums
    // whose sanitized parent + leaf would land under the same folder. Excludes the
    // descriptor we're resolving. Each contributes one entry per (collectionId,
    // sanitized leaf) pair.
    //
    // "New" here means "no existing placement matches the album's *current*
    // displayPathHash". A renamed or moved album whose old placement is still on disk
    // counts as new for the new path: the old placement is stale (different path-hash)
    // and the new path-hash hasn't been claimed yet. Without this distinction, two
    // distinct renamed albums could each end up at the bare path because the filter
    // would have dropped them as "covered above".
    let siblingCandidates = albumsInTree(collections)
      .filter { $0.localIdentifier != descriptor.localIdentifier }
      .filter { other in
        sanitizedFolderPath(other.pathComponents) == parentPathString
          && ExportPathPolicy.sanitizeComponent(other.title) == sanitizedLeaf
      }
      .filter { other in
        // If an existing placement matches `other` at its *current* path-hash, it
        // already has its bare/suffixed path locked in via `existingLeaves` above —
        // skip it to avoid double-counting.
        let otherHash = displayPathHash8(
          pathComponents: other.pathComponents, title: other.title)
        return existingPlacements.first(where: {
          $0.kind == .album && $0.collectionLocalIdentifier == other.localIdentifier
            && $0.id.hasSuffix(":\(otherHash)")
        }) == nil
      }

    let collidingNewIds: [String] =
      ([descriptor.localIdentifier ?? ""]
      + siblingCandidates.compactMap { $0.localIdentifier })
      .filter { !$0.isEmpty }

    // If no collision (no other claimants share this leaf), keep the bare leaf.
    let bareLeafTaken = existingLeaves.contains(sanitizedLeaf)
    let newSiblings = collidingNewIds.count > 1
    if !bareLeafTaken && !newSiblings {
      return sanitizedLeaf
    }

    // Decide whether *this* descriptor gets the bare path or a suffix among the new
    // claimants. Existing placements always claim first; among new claimants, sort
    // lexicographically by `collectionLocalIdentifier` so the result is independent of
    // PhotoKit traversal order.
    let lexSortedNewIds = collidingNewIds.sorted()
    let myId = descriptor.localIdentifier ?? ""
    let myIndexAmongNew = lexSortedNewIds.firstIndex(of: myId) ?? 0

    // First-new gets bare iff no existing placement already claimed it.
    if !bareLeafTaken, myIndexAmongNew == 0 {
      return sanitizedLeaf
    }

    // I need the Nth available suffix slot (0-indexed). If bare was taken, my slot is
    // `myIndexAmongNew` (all news get suffixes). If bare was free and I'm not first-new,
    // the first-new took bare, so my slot is `myIndexAmongNew - 1`.
    let targetSlot = bareLeafTaken ? myIndexAmongNew : (myIndexAmongNew - 1)
    var slot = 0
    var n = 2
    while true {
      let candidate = "\(sanitizedLeaf)_\(n)"
      // Skip suffixes already claimed by existing placements; new claimants only take
      // unclaimed suffixes in order.
      if !existingLeaves.contains(candidate) {
        if slot == targetSlot { return candidate }
        slot += 1
      }
      n += 1
      // Defensive cap; should never hit at personal-library scale.
      if n > 1000 { return "\(sanitizedLeaf)_\(n)" }
    }
  }

  // MARK: - Hash helpers

  private func collectionIdHash16(for id: String) -> String {
    Self.sha256Hex(of: id, prefix: 16)
  }

  private func displayPathHash8(pathComponents: [String], title: String) -> String {
    // Apply Unicode NFC (canonical composition) to every component before hashing so
    // PhotoKit titles that arrive in different normalization forms across launches or
    // OS versions hash to the same value. Without this, an album titled "Café" arriving
    // as NFD on one launch and NFC on another would produce two different placement
    // ids and the next export would silently land at a brand-new on-disk folder.
    let normalizedComponents = pathComponents.map(\.precomposedStringWithCanonicalMapping)
    let normalizedTitle = title.precomposedStringWithCanonicalMapping
    let combined =
      normalizedComponents.joined(separator: "\u{0000}") + "\u{0000}" + normalizedTitle
    return Self.sha256Hex(of: combined, prefix: 8)
  }

  fileprivate static func sha256Hex(of string: String, prefix: Int) -> String {
    let digest = SHA256.hash(data: Data(string.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(prefix))
  }

  // MARK: - Tree traversal

  private func findAlbum(
    collectionId: String, in collections: [PhotoCollectionDescriptor]
  ) -> PhotoCollectionDescriptor? {
    for descriptor in collections {
      if descriptor.kind == .album && descriptor.localIdentifier == collectionId {
        return descriptor
      }
      if let found = findAlbum(collectionId: collectionId, in: descriptor.children) {
        return found
      }
    }
    return nil
  }

  private func albumsInTree(_ collections: [PhotoCollectionDescriptor])
    -> [PhotoCollectionDescriptor]
  {
    var result: [PhotoCollectionDescriptor] = []
    for descriptor in collections {
      if descriptor.kind == .album {
        result.append(descriptor)
      }
      result.append(contentsOf: albumsInTree(descriptor.children))
    }
    return result
  }

  private func sanitizedFolderPath(_ components: [String]) -> String {
    components.map(ExportPathPolicy.sanitizeComponent).joined(separator: "/")
  }
}
