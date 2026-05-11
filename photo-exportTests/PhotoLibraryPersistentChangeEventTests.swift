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
