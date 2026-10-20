import Combine

/// Auto Export reads the same cached flag the export guards and the main window use, and
/// refreshes it through the same non-prompting re-read.
extension PhotoLibraryManager: AutoSyncPhotosAuthorizationProviding {
  var isAuthorizedPublisher: AnyPublisher<Bool, Never> {
    Empty().eraseToAnyPublisher()
  }

  func refreshAuthorization() {}
}
