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

  /// Baseline: each `invalidateCache()` call (one per real
  /// `photoLibraryDidChange` callback) bumps `libraryRevision` exactly once
  /// and the `@Published` publisher emits exactly once. Without source-side
  /// coalescing, a 50-asset Photos.app burst that arrives as 50 separate
  /// observer callbacks produces 50 downstream invalidations on every
  /// `libraryRevision`-observing sidebar/grid view.
  ///
  /// Documents the current behaviour. If a debounce lands at the source
  /// (plan §1.6), flip `expectedEmissions` to the post-debounce count and
  /// add a timing-window assertion.
  @Test func libraryRevisionBumpsPropagateOneToOne() async throws {
    let plm = PhotoLibraryManager()
    let burstSize = 50
    var emissions = 0
    let cancellable = plm.$libraryRevision
      .dropFirst()
      .sink { _ in emissions += 1 }

    for _ in 0..<burstSize {
      plm.invalidateCache()
    }

    // Combine `@Published` fires synchronously on the publishing actor; one
    // yield lets any tasks scheduled inside `invalidateCache` (the
    // `collectionCountCache.invalidateAll()` hop) drain so a debounce
    // implementation can't accidentally pass by side-channel.
    await Task.yield()

    #expect(
      emissions == burstSize,
      "no source-side coalescing today; each invalidateCache bumps libraryRevision once")
    #expect(plm.libraryRevision == burstSize)

    cancellable.cancel()
  }
}
