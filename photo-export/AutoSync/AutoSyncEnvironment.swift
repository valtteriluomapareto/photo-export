import Combine
import Foundation

/// Dependencies for `AutoSyncManager`, injected so policy tests can use fakes
/// without real PhotoKit or filesystem work. Production wiring supplies the services.
/// See docs/reference/auto-export-behavior.md#event-dispatch.
@MainActor
struct AutoSyncEnvironment {
  let exportRunner: any AutoSyncExportRunning
  let destination: any AutoSyncDestinationProviding
  let scopes: any AutoExportScopeProviding
  let photos: any PhotoLibraryChangeProviding
  let importing: any AutoSyncImportProviding
  let dirtyStateStore: any AutoSyncDirtyStateStore
  let retryStateStore: any AutoSyncRetryStateStore
  let runSummaryStore: any AutoSyncRunSummaryStore
  let clock: any AutoSyncClock
  /// Photos access. Required, with no default: a missing provider would read as always
  /// authorized and let runs scan a library they cannot see.
  let photosAuthorization: any AutoSyncPhotosAuthorizationProviding
  let userDefaults: UserDefaults
}
