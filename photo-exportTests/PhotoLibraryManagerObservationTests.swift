import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhotoLibraryManagerObservationTests {
  /// Changing access fails without its dependency; equal writes already stay silent.
  @Test func isAuthorizedRegistersADependency() {
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service)
    let probe = ObservationProbe { _ = library.isAuthorized }
    service.authorizationStatus = .denied
    service.isAuthorized = false

    library.refreshAuthorizationStatus()
    #expect(probe.changeCount == 1)
    let afterChange = probe.changeCount
    library.isAuthorized = false
    #expect(probe.changeCount == afterChange)
  }

  /// Changing status fails without a dependency independent of access sufficiency.
  @Test func authorizationStatusRegistersADependency() {
    let service = FakePhotoLibraryService()
    service.authorizationStatus = .denied
    service.isAuthorized = false
    let library = PhotoLibraryManager(overrideService: service)
    let probe = ObservationProbe { _ = library.authorizationStatus }

    service.authorizationStatus = .restricted
    library.refreshAuthorizationStatus()
    #expect(probe.changeCount == 1)
  }

  /// Combine repeats and sibling silence already pass; the status dependency is missing.
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
    #expect(status.changeCount == 1)
    #expect(authorized.changeCount == 0)
    #expect(values == [true])
    withExtendedLifetime(subscription) {}
  }

  /// The own-property notification is missing; unrelated dependency silence already passes.
  @Test func isAuthorizedWriteNotifiesOnlyItself() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let authorized = ObservationProbe { _ = library.isAuthorized }
    let status = ObservationProbe { _ = library.authorizationStatus }
    let revision = ObservationProbe { _ = library.libraryRevision }

    library.isAuthorized = false
    #expect(authorized.changeCount == 1)
    #expect(status.changeCount == 0)
    #expect(revision.changeCount == 0)
  }

  /// Equal-write delivery and silence already pass; the changing-write control needs a dependency.
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
    #expect(authorized.changeCount == 1)
    #expect(status.changeCount == 0)
    #expect(authorizedValues == [true, false])
    withExtendedLifetime((statusSubscription, authorizedSubscription)) {}
  }

  /// Observation notifies before synchronous publisher delivery; subscribers still read old storage.
  @Test func authorizationWritesNotifyBeforeDelivery() {
    let service = FakePhotoLibraryService()
    let library = PhotoLibraryManager(overrideService: service)
    let status = ObservationProbe { _ = library.authorizationStatus }
    var events: [String] = []
    let statusSubscription = library.authorizationStatusPublisher.dropFirst().sink {
      events.append("status \($0.rawValue)")
      #expect(status.changeCount == 1)
      #expect(library.authorizationStatus == .authorized)
    }
    let authorizedSubscription = library.isAuthorizedPublisher.dropFirst().sink {
      events.append("authorized \($0)")
    }
    service.authorizationStatus = .denied
    service.isAuthorized = false

    library.refreshAuthorizationStatus()
    #expect(events == ["status \(PHAuthorizationStatus.denied.rawValue)", "authorized false"])
    withExtendedLifetime((statusSubscription, authorizedSubscription)) {}
  }

  /// Every invalidation notifies revision readers; forgetting cached assets stays silent.
  @Test func libraryRevisionNotifiesOnEveryInvalidation() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let probe = ObservationProbe { _ = library.libraryRevision }

    library.invalidateCache()
    library.invalidateCache(changedThumbnailAssetIDs: [])
    #expect(probe.changeCount == 2)
    let afterInvalidation = probe.changeCount
    library.forgetPHAssetCache()
    #expect(probe.changeCount == afterInvalidation)
  }

  /// Overridden query reads fail to follow invalidations until they register a revision dependency.
  @Test func collectionTreeAndAssetDetailsFollowLibraryChanges() {
    let service = FakePhotoLibraryService()
    service.detailsByAssetId["A"] = AssetDetails(
      originalFilename: "A.jpg", fileSize: 10, resources: [])
    let library = PhotoLibraryManager(overrideService: service)
    let tree = ObservationProbe { _ = try? library.fetchCollectionTree() }
    let details = ObservationProbe { _ = library.assetDetails(for: "A") }

    library.invalidateCache(changedThumbnailAssetIDs: [])
    #expect(tree.changeCount == 1)
    #expect(details.changeCount == 1)
    let afterTree = tree.changeCount
    let afterDetails = details.changeCount
    library.forgetPHAssetCache()
    #expect(tree.changeCount == afterTree)
    #expect(details.changeCount == afterDetails)
  }

  /// Content notifications are missing; empty-ID changes and cache eviction already stay silent.
  @Test func thumbnailRevisionFollowsContentChangesOnly() {
    let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
    let probe = ObservationProbe { _ = library.thumbnailContentRevision(for: "A") }

    library.invalidateCache(changedThumbnailAssetIDs: [])
    #expect(probe.changeCount == 0)
    library.invalidateCache(changedThumbnailAssetIDs: ["B"])
    #expect(probe.changeCount == 1)
    library.invalidateCache()
    #expect(probe.changeCount == 2)
    library.invalidateCache(changedThumbnailAssetIDs: Set((0..<600).map { "overflow-\($0)" }))
    #expect(probe.changeCount == 3)
    let afterOverflow = probe.changeCount
    library.forgetPHAssetCache()
    #expect(probe.changeCount == afterOverflow)
  }

  /// Already passes: initialization defers live status reads and mirrors an override.
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
