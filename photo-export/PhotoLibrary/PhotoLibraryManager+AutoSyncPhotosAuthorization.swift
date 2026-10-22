/// Auto Export reads the same cached flag the export guards and the main window use, and
/// refreshes it through the same non-prompting re-read. The bridge delivers synchronously
/// before storage, so the sink gets the new value before `refreshAuthorization()` returns; it
/// must use that value rather than read `isAuthorized` back. The conformance's
/// `isAuthorizedPublisher` is the named publisher declared beside `isAuthorized`.
extension PhotoLibraryManager: AutoSyncPhotosAuthorizationProviding {
  func refreshAuthorization() {
    refreshAuthorizationStatus()
  }
}
