import Combine
import Photos

@testable import Photo_Export

/// `PhotoLibraryChangeProviding` test double. Tests construct one, subscribe a system under
/// test to it, and call `push(_:)` / `pushError(_:)` to drive events.
///
/// `authorizationStatus` defaults to `.authorized`; tests that need limited or denied access
/// can override the property before the system under test reads it. Changes published while
/// no one is subscribed are dropped — pushing events before subscribers attach is the
/// caller's responsibility.
@MainActor
final class FakePersistentChangeSource: StartablePhotoLibraryChangeProviding {
  var authorizationStatus: PHAuthorizationStatus = .authorized

  private let subject = PassthroughSubject<PhotoLibraryChangeOutcome, Never>()

  /// Called as each subscriber attaches to `changes`.
  var onSubscribe: (() -> Void)?
  /// Called from `start()`.
  var onStart: (() -> Void)?
  private(set) var startCount = 0

  var changes: AnyPublisher<PhotoLibraryChangeOutcome, Never> {
    subject.handleEvents(receiveSubscription: { [weak self] _ in self?.onSubscribe?() })
      .eraseToAnyPublisher()
  }

  func start() {
    startCount += 1
    onStart?()
  }

  /// Pushes a successful event into the stream.
  func push(_ event: PhotoLibraryPersistentChangeEvent) {
    subject.send(.success(event))
  }

  /// Pushes a fetch failure into the stream.
  func pushError(_ error: PhotoLibraryPersistentChangeFetchError) {
    subject.send(.failure(error))
  }
}
