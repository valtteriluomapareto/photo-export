import Combine
import Photos
import Testing

@testable import Photo_Export

/// `PhotoLibraryManager`'s Auto Export seam publishes its cached flag and refreshes it
/// through the non-prompting re-read. The refresh must emit before it returns: Auto Export
/// refreshes right before starting a run and relies on the new value having reached it.
@MainActor
struct PhotoLibraryManagerAutoSyncAuthorizationTests {
  @Test func refreshPublishesSynchronouslyUpdatesTheCachedFlagAndNeverPrompts() {
    let service = FakePhotoLibraryService()
    let manager = PhotoLibraryManager(overrideService: service)
    let provider: any AutoSyncPhotosAuthorizationProviding = manager
    var received: [Bool] = []
    let subscription = provider.isAuthorizedPublisher.sink { received.append($0) }
    #expect(received == [true])

    service.authorizationStatus = .denied
    service.isAuthorized = false
    provider.refreshAuthorization()
    #expect(received == [true, false])
    #expect(!manager.isAuthorized)
    #expect(manager.authorizationStatus == .denied)

    service.authorizationStatus = .limited
    service.isAuthorized = true
    provider.refreshAuthorization()
    #expect(received == [true, false, true])
    #expect(manager.isAuthorized)

    #expect(service.requestAuthorizationCalls == 0)
    withExtendedLifetime(subscription) {}
  }
}
