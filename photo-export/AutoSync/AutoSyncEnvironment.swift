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
  /// Crash-survivable journal for the in-flight AutoSync fan-out. Written
  /// at fan-out boundaries by `AutoSyncManager.startRun`; cleared on clean
  /// finish. Surfaced in the user's diagnostic report so a previous
  /// session's silent shutdown is observable from the saved `.txt`.
  let currentRunStore: any AutoSyncCurrentRunStore
  /// PHAsset cache control surface for the fan-out. AutoSyncManager calls
  /// `forgetPHAssetCache()` between sub-scopes to bound peak memory at one
  /// scope's working set rather than the whole fan-out (issue #112).
  let phAssetCacheControl: any PHAssetCacheControlling
  let clock: any AutoSyncClock
  let userDefaults: UserDefaults
}
