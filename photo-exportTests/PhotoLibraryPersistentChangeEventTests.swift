import Foundation
import Testing

@testable import Photo_Export

struct PhotoLibraryPersistentChangeEventTests {
  @Test func defaultEventIsEmpty() {
    let event = PhotoLibraryPersistentChangeEvent()

    #expect(event.insertedLocalIdentifiers.isEmpty)
    #expect(event.updatedLocalIdentifiers.isEmpty)
    #expect(event.deletedLocalIdentifiers.isEmpty)
    #expect(event.collectionChangesPresent == false)
    #expect(event.nextToken == nil)
    #expect(event.hasAssetChanges == false)
  }

  @Test func hasAssetChangesIsTrueForAnyAssetIdSet() {
    let inserted = PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: ["a"])
    let updated = PhotoLibraryPersistentChangeEvent(updatedLocalIdentifiers: ["b"])
    let deleted = PhotoLibraryPersistentChangeEvent(deletedLocalIdentifiers: ["c"])
    let collectionsOnly = PhotoLibraryPersistentChangeEvent(collectionChangesPresent: true)

    #expect(inserted.hasAssetChanges)
    #expect(updated.hasAssetChanges)
    #expect(deleted.hasAssetChanges)
    #expect(collectionsOnly.hasAssetChanges == false)
  }

  /// `requiresUIWake` drives the safety-net adapter's
  /// `onPotentialLibraryChange` bridge — it must include collection-only
  /// changes (album rename / reorder / create) so the sidebar's collection
  /// tree and per-album counts refresh even when no asset identifiers moved.
  /// Documenting the over-eager behavior as intentional: an album-rename
  /// event with zero asset deltas wakes the UI bridge.
  @Test func requiresUIWakeIncludesCollectionOnlyChanges() {
    let empty = PhotoLibraryPersistentChangeEvent()
    let insertedAsset = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"])
    let renamedAlbum = PhotoLibraryPersistentChangeEvent(
      collectionChangesPresent: true)
    let both = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], collectionChangesPresent: true)

    #expect(empty.requiresUIWake == false)
    #expect(insertedAsset.requiresUIWake)
    #expect(renamedAlbum.requiresUIWake, "album-only changes still wake the UI")
    #expect(both.requiresUIWake)
  }

  @Test func equalityIgnoresOnlyAssetSetOrdering() {
    let lhs = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a", "b", "c"],
      observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let rhs = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["c", "b", "a"],
      observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(lhs == rhs)
  }

  @Test func fetchErrorCasesAreDistinct() {
    let errors: [PhotoLibraryPersistentChangeFetchError] =
      [.tokenExpired, .tokenInvalid, .detailsUnavailable]

    #expect(Set(errors).count == errors.count)
  }
}
