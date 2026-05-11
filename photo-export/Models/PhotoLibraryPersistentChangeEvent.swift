import Foundation

/// A single persistent-change observation reported by `PHPhotoLibrary.fetchPersistentChanges`.
/// Carries the inserted, updated, and deleted asset identifiers since the previous token plus
/// a flag indicating whether collection-level changes (album membership, rename, folder
/// movement) were present in the same change set.
///
/// The reducer treats `insertedLocalIdentifiers` and `updatedLocalIdentifiers` as a single
/// dirty set for asset-targeted re-evaluation; `deletedLocalIdentifiers` is informational
/// because MVP does not auto-delete exported files. `collectionChangesPresent` drives
/// album-scope reconciliation when the Albums Auto Export scope is selected.
///
/// `nextToken` is the token to advance the global persistent-change token to once dirty IDs
/// (or full-reconciliation intent) have been durably recorded; if the consumer crashes before
/// recording, the token is not advanced and the same range is re-read on next launch.
struct PhotoLibraryPersistentChangeEvent: Equatable, Sendable {
  let insertedLocalIdentifiers: Set<String>
  let updatedLocalIdentifiers: Set<String>
  let deletedLocalIdentifiers: Set<String>
  let collectionChangesPresent: Bool
  let observedAt: Date
  let nextToken: Data?

  init(
    insertedLocalIdentifiers: Set<String> = [],
    updatedLocalIdentifiers: Set<String> = [],
    deletedLocalIdentifiers: Set<String> = [],
    collectionChangesPresent: Bool = false,
    observedAt: Date = Date(),
    nextToken: Data? = nil
  ) {
    self.insertedLocalIdentifiers = insertedLocalIdentifiers
    self.updatedLocalIdentifiers = updatedLocalIdentifiers
    self.deletedLocalIdentifiers = deletedLocalIdentifiers
    self.collectionChangesPresent = collectionChangesPresent
    self.observedAt = observedAt
    self.nextToken = nextToken
  }

  var hasAssetChanges: Bool {
    !insertedLocalIdentifiers.isEmpty || !updatedLocalIdentifiers.isEmpty
      || !deletedLocalIdentifiers.isEmpty
  }
}

/// Failure modes from `PHPhotoLibrary.fetchPersistentChanges(since:)`. Routed individually so
/// logs and Export Issues can distinguish whether the OS is recycling tokens too aggressively
/// or our handling has a bug.
enum PhotoLibraryPersistentChangeFetchError: Error, Equatable, Sendable {
  case tokenExpired
  case tokenInvalid
  case detailsUnavailable
}
