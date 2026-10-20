import Combine

/// Auto Export reads the same cached flag the export guards and the main window use, and
/// refreshes it through the same non-prompting re-read. `@Published` emits synchronously in
/// `willSet`, so the sink gets the new value before `refreshAuthorization()` returns; it
/// must use that value rather than read `isAuthorized` back.
extension PhotoLibraryManager: AutoSyncPhotosAuthorizationProviding {
  var isAuthorizedPublisher: AnyPublisher<Bool, Never> {
    $isAuthorized.eraseToAnyPublisher()
  }

  func refreshAuthorization() {
    refreshAuthorizationStatus()
  }
}
