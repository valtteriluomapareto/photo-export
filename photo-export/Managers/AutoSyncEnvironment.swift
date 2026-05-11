import Combine
import Foundation

/// Bundle of dependencies `AutoSyncManager` needs to function. Plan §"AutoSyncManager
/// Shape": "Tests should exercise the auto-sync policy with fake protocols, not real
/// PhotoKit or filesystem work." Each field is a protocol the manager consumes; the
/// production wiring builds an environment from real managers, the test harness
/// builds one from fakes.
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
  let perDestinationTokenStore: any AutoSyncPerDestinationTokenStore
  let clock: any AutoSyncClock
  let userDefaults: UserDefaults
}
