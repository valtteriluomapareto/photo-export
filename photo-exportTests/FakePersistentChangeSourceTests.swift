import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

@MainActor
struct FakePersistentChangeSourceTests {

  @Test func defaultAuthorizationStatusIsAuthorized() {
    let source = FakePersistentChangeSource()

    #expect(source.authorizationStatus == .authorized)
  }

  @Test func pushedEventsArriveOnSubscribers() {
    let source = FakePersistentChangeSource()
    var received: [PhotoLibraryChangeOutcome] = []
    let cancellable = source.changes.sink { received.append($0) }

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"],
      observedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    source.push(event)
    source.pushError(.tokenExpired)

    cancellable.cancel()

    #expect(received.count == 2)
    if case .success(let receivedEvent) = received[0] {
      #expect(receivedEvent.insertedLocalIdentifiers == ["asset-1"])
    } else {
      Issue.record("First emission was not a success outcome")
    }
    if case .failure(let error) = received[1] {
      #expect(error == .tokenExpired)
    } else {
      Issue.record("Second emission was not a failure outcome")
    }
  }

  @Test func emissionsBeforeSubscribeAreDropped() {
    let source = FakePersistentChangeSource()
    source.push(PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: ["pre-subscribe"]))

    var received: [PhotoLibraryChangeOutcome] = []
    let cancellable = source.changes.sink { received.append($0) }
    source.push(PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: ["post-subscribe"]))
    cancellable.cancel()

    #expect(received.count == 1)
  }

  @Test func authorizationStatusIsMutableForLimitedTransitionTests() {
    let source = FakePersistentChangeSource()

    source.authorizationStatus = .limited
    #expect(source.authorizationStatus == .limited)

    source.authorizationStatus = .denied
    #expect(source.authorizationStatus == .denied)
  }
}
