import Combine
import Photos
import Testing

@testable import Photo_Export

/// The scan entry points read the live authorization status, not the cached flag: without
/// access PhotoKit returns empty results rather than an error, so a revoke the app hasn't
/// refreshed yet would otherwise read as an empty library and a scan would complete. A live
/// denial also refreshes the cached flag, so the main window and Auto Export see it at once.
///
/// The stubbed reader denies access, so each call throws at its guard and nothing reaches
/// PhotoKit. A guard moved after a fetch would read the real library here and fail to throw
/// `authorizationDenied` in an unauthorized test host.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PhotoLibraryManagerLiveAuthorizationTests {
  private typealias Denied = PhotoLibraryManager.PhotoLibraryError

  /// A manager whose cached flag still says authorized while the system says denied.
  private func staleManager() -> (PhotoLibraryManager, LiveReads) {
    let reads = LiveReads()
    let manager = PhotoLibraryManager(liveAuthorizationStatus: {
      reads.record()
      return .denied
    })
    manager.authorizationStatus = .authorized
    manager.isAuthorized = true
    return (manager, reads)
  }

  @Test func yearListingThrowsOnALiveDenialAndRefreshesTheCachedFlag() {
    let (manager, reads) = staleManager()
    var published: [Bool] = []
    let subscription = manager.$isAuthorized.dropFirst().sink { published.append($0) }

    #expect(throws: Denied.authorizationDenied) { try manager.availableYearsWithCounts() }
    #expect(reads.count > 0)
    #expect(published == [false])
    #expect(!manager.isAuthorized && manager.authorizationStatus == .denied)
    withExtendedLifetime(subscription) {}
  }

  @Test func progressiveFetchThrowsOnALiveDenialAndRefreshesTheCachedFlag() async {
    let (manager, reads) = staleManager()
    var received = 0
    await #expect(throws: Denied.authorizationDenied) {
      for try await batch in manager.fetchAssetsProgressive(in: .favorites, mediaType: nil) {
        received += batch.count
      }
    }
    #expect(received == 0)
    #expect(reads.count > 0)
    // Refreshed before the stream threw.
    #expect(!manager.isAuthorized && manager.authorizationStatus == .denied)
  }

  @Test func aLiveDenialWithTheCachedFlagAlreadyOffLeavesItAlone() {
    let (manager, _) = staleManager()
    manager.authorizationStatus = .denied
    manager.isAuthorized = false
    let revision = manager.libraryRevision
    #expect(throws: Denied.authorizationDenied) { try manager.availableYearsWithCounts() }
    #expect(manager.libraryRevision == revision)
  }
}

/// Counts reads of the stubbed status; the reader runs off the main actor.
private final class LiveReads: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func record() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}
