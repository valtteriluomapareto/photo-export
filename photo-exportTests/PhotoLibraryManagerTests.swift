import Combine
import Testing

@testable import Photo_Export

/// Coverage for the small Combine surface on `PhotoLibraryManager`. The class
/// otherwise touches PhotoKit directly, so most of its behaviour is exercised
/// through the `FakePhotoLibraryService` injection seam at higher layers
/// (`ExportManager`, `MonthViewModel`, the Backup scanner). This file pins the
/// bits that DO have a non-trivial in-process implementation worth a unit
/// test in isolation.
@MainActor
struct PhotoLibraryManagerTests {

  /// Issue #49: `bindLivePhotoDetectionFallback(to:)` subscribes
  /// `livePhotoDetectionFallbackEnabled` to a `Bool` publisher — production
  /// passes `ExportManager.$livePhotosPairedExport.eraseToAnyPublisher()`. A
  /// refactor that drops the sink, replaces it with `.assign(to:)` on the
  /// wrong key path, or hops the value through `.receive(on:)` and breaks the
  /// "observable on the next fetch" guarantee would silently disable iCloud-
  /// only Live Photo detection until the next launch. This test pins the
  /// synchronous-propagation contract.
  @Test func bindLivePhotoDetectionFallback_propagates() {
    let subject = PassthroughSubject<Bool, Never>()
    let plm = PhotoLibraryManager()
    plm.bindLivePhotoDetectionFallback(to: subject.eraseToAnyPublisher())

    #expect(plm.livePhotoDetectionFallbackEnabled == false)
    subject.send(true)
    #expect(plm.livePhotoDetectionFallbackEnabled == true)
    subject.send(false)
    #expect(plm.livePhotoDetectionFallbackEnabled == false)
  }

  /// Re-binding replaces the prior subscription. Documents the
  /// `livePhotoDetectionCancellables.removeAll()` line in
  /// `bindLivePhotoDetectionFallback` — without that line, a stale binding
  /// from a previous `bindLivePhotoDetectionFallback` call would keep
  /// overwriting `livePhotoDetectionFallbackEnabled` whenever the prior
  /// publisher emitted, racing the new binding.
  /// `forgetPHAssetCache()` (issue #112) is a one-liner that calls
  /// `phAssetCache.removeAll()`. The interesting verification — "cache drops
  /// between AutoSync sub-scopes" — is structural, via the
  /// `RecordingPHAssetCacheControl` spy in `AutoSyncManagerTests`. This test
  /// pins the method's existence and the `phAssetCacheCount` getter on a
  /// fresh manager (initial cache is empty; calling forget keeps it empty
  /// rather than crashing on a no-op `removeAll()`).
  ///
  /// The cache cannot be populated from a unit test without a real
  /// PhotoKit-authorised session — `cacheAssets(_:)` is `private`, and
  /// `overrideService` early-returns from `fetchAssets(in:)` before the
  /// cache-population path. So the test surface here is intentionally narrow.
  @Test func forgetPHAssetCacheLeavesEmptyCacheUntouched() {
    let plm = PhotoLibraryManager()
    #expect(plm.phAssetCacheCount == 0)
    plm.forgetPHAssetCache()
    #expect(plm.phAssetCacheCount == 0)
  }

  @Test func bindLivePhotoDetectionFallback_rebindReplacesPriorSubscription() {
    let firstSubject = PassthroughSubject<Bool, Never>()
    let secondSubject = PassthroughSubject<Bool, Never>()
    let plm = PhotoLibraryManager()

    plm.bindLivePhotoDetectionFallback(to: firstSubject.eraseToAnyPublisher())
    firstSubject.send(true)
    #expect(plm.livePhotoDetectionFallbackEnabled == true)

    plm.bindLivePhotoDetectionFallback(to: secondSubject.eraseToAnyPublisher())
    // The first subject is now disconnected — emitting on it must not move
    // the property.
    firstSubject.send(false)
    #expect(plm.livePhotoDetectionFallbackEnabled == true)
    // The second subject drives the value.
    secondSubject.send(false)
    #expect(plm.livePhotoDetectionFallbackEnabled == false)
  }
}
