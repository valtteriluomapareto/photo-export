import Combine

/// AutoSync's view of Photos access. `PhotoLibraryManager` provides the production
/// value; tests inject a fake whose live value can differ from its cached one.
///
/// `isAuthorizedPublisher` replays the cached value on subscribe and emits synchronously
/// on the main actor whenever it changes, with no thread hop. `refreshAuthorization()`
/// re-reads the system's current status without prompting and publishes any change
/// before it returns, so the reducer sees a revoke before the run it would block.
@MainActor
protocol AutoSyncPhotosAuthorizationProviding: AnyObject {
  var isAuthorizedPublisher: AnyPublisher<Bool, Never> { get }
  func refreshAuthorization()
}
