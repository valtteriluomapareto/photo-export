import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhotoLibraryManagerObservationTests {
  @Test func isAuthorizedRegistersADependency() {
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service)
    let probe = ObservationProbe { _ = library.isAuthorized }
    service.authorizationStatus = .denied
    service.isAuthorized = false

    library.refreshAuthorizationStatus()
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 1)
    }
    let afterChange = probe.changeCount
    library.isAuthorized = false
    #expect(probe.changeCount == afterChange)
  }

  @Test func authorizationStatusRegistersADependency() {
    let service = FakePhotoLibraryService()
    service.authorizationStatus = .denied
    service.isAuthorized = false
    let library = PhotoLibraryManager(overrideService: service)
    let probe = ObservationProbe { _ = library.authorizationStatus }

    service.authorizationStatus = .restricted
    library.refreshAuthorizationStatus()
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 1)
    }
  }

  @Test func limitedAccessWritesOnlyTheStatus() {
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service)
    let status = ObservationProbe { _ = library.authorizationStatus }
    let authorized = ObservationProbe { _ = library.isAuthorized }
    var values: [Bool] = []
    let subscription = library.isAuthorizedPublisher.dropFirst().sink { values.append($0) }

    service.authorizationStatus = .limited
    service.isAuthorized = true
    library.refreshAuthorizationStatus()
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(status.changeCount == 1)
    }
    #expect(authorized.changeCount == 0)
    #expect(values == [true])
    withExtendedLifetime(subscription) {}
  }

  @Test func isAuthorizedWriteNotifiesOnlyItself() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let authorized = ObservationProbe { _ = library.isAuthorized }
    let status = ObservationProbe { _ = library.authorizationStatus }
    let revision = ObservationProbe { _ = library.libraryRevision }

    library.isAuthorized = false
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(authorized.changeCount == 1)
    }
    #expect(status.changeCount == 0)
    #expect(revision.changeCount == 0)
  }

  @Test func equalAuthorizationWritesDeliverWithoutNotifying() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let authorized = ObservationProbe { _ = library.isAuthorized }
    let status = ObservationProbe { _ = library.authorizationStatus }
    var statusValues: [PHAuthorizationStatus] = []
    var authorizedValues: [Bool] = []
    let statusSubscription = library.authorizationStatusPublisher.dropFirst().sink {
      statusValues.append($0)
    }
    let authorizedSubscription = library.isAuthorizedPublisher.dropFirst().sink {
      authorizedValues.append($0)
    }

    library.authorizationStatus = .authorized
    library.isAuthorized = true
    #expect(statusValues == [.authorized])
    #expect(authorizedValues == [true])
    #expect(status.changeCount == 0)
    #expect(authorized.changeCount == 0)

    library.isAuthorized = false
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(authorized.changeCount == 1)
    }
    #expect(status.changeCount == 0)
    #expect(authorizedValues == [true, false])
    withExtendedLifetime((statusSubscription, authorizedSubscription)) {}
  }

  @Test func libraryRevisionNotifiesOnEveryInvalidation() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let probe = ObservationProbe { _ = library.libraryRevision }

    library.invalidateCache()
    library.invalidateCache(changedThumbnailAssetIDs: [])
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 2)
    }
    let afterInvalidation = probe.changeCount
    library.forgetPHAssetCache()
    #expect(probe.changeCount == afterInvalidation)
  }

  @Test func collectionTreeAndAssetDetailsFollowLibraryChanges() {
    let service = FakePhotoLibraryService()
    service.detailsByAssetId["A"] = AssetDetails(
      originalFilename: "A.jpg", fileSize: 10, resources: [])
    let library = PhotoLibraryManager(overrideService: service)
    let tree = ObservationProbe { _ = try? library.fetchCollectionTree() }
    let details = ObservationProbe { _ = library.assetDetails(for: "A") }

    library.invalidateCache(changedThumbnailAssetIDs: [])
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(tree.changeCount == 1)
    }
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(details.changeCount == 1)
    }
    let afterTree = tree.changeCount
    let afterDetails = details.changeCount
    library.forgetPHAssetCache()
    #expect(tree.changeCount == afterTree)
    #expect(details.changeCount == afterDetails)
  }

  @Test func thumbnailRevisionFollowsContentChangesOnly() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let probe = ObservationProbe { _ = library.thumbnailContentRevision(for: "A") }

    library.invalidateCache(changedThumbnailAssetIDs: [])
    #expect(probe.changeCount == 0)
    library.invalidateCache(changedThumbnailAssetIDs: ["B"])
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 1)
    }
    library.invalidateCache()
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 2)
    }
    library.invalidateCache(changedThumbnailAssetIDs: Set((0..<600).map { "overflow-\($0)" }))
    withKnownIssue("The library does not register this Observation dependency yet") {
      #expect(probe.changeCount == 3)
    }
    let afterOverflow = probe.changeCount
    library.forgetPHAssetCache()
    #expect(probe.changeCount == afterOverflow)
  }

  @Test func initReadsNoLiveStatusAndStartsUnauthorized() {
    let reads = LiveStatusReads()
    let library = PhotoLibraryManager(liveAuthorizationStatus: {
      reads.record()
      return .authorized
    })
    #expect(reads.count == 0)
    #expect(library.authorizationStatus == .notDetermined)
    #expect(!library.isAuthorized)
    #expect(library.libraryRevision == 0)

    let service = FakePhotoLibraryService()
    service.authorizationStatus = .denied
    service.isAuthorized = false
    let overridden = PhotoLibraryManager(overrideService: service)
    #expect(overridden.authorizationStatus == .denied)
    #expect(!overridden.isAuthorized)
    #expect(overridden.libraryRevision == 0)
  }
}

/// The authorization reader is Sendable even though construction stays on the main actor.
private final class LiveStatusReads: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func record() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
