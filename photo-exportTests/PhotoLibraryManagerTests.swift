import Combine
import Foundation
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

  /// Regression test for issue #104 ("green check mark even if month is
  /// not fully exported"). `invalidateCache()` historically bumped
  /// `libraryRevision` synchronously while dispatching the
  /// `collectionCountCache` wipe in a separate, unawaited Task. Sinks
  /// attached to `$libraryRevision` fired in the same actor frame and
  /// could race past the still-populated count cache, reading stale
  /// counts and rendering the green checkmark on a month that had gained
  /// new photos in Photos.app.
  ///
  /// The fix sequences the count-cache wipe BEFORE the `libraryRevision`
  /// bump, so any observer reacting to the bump always sees a cleared
  /// cache. The observable consequence pinned here: `invalidateCache` no
  /// longer bumps `libraryRevision` synchronously — the bump arrives
  /// after at least one actor hop, gated on the cache wipe completing.
  /// (Sidebar `.onChange(libraryRevision)` handlers run in the same
  /// frame as the synchronous bump in the buggy code, so deferring the
  /// bump is what closes the race.)
  ///
  /// This test deliberately pins a behavioural detail — synchronous vs.
  /// deferred bump — rather than try to reproduce the race directly,
  /// because Swift Concurrency's task scheduling makes the
  /// observer-vs-invalidation race non-deterministic in test
  /// environments. The deferred-bump contract is the load-bearing piece
  /// of the fix; if a future refactor restores the synchronous bump, the
  /// race re-opens and this test fires.
  @Test
  func invalidateCacheDefersLibraryRevisionBumpUntilCountCacheIsCleared() async throws {
    let manager = PhotoLibraryManager()
    let initial = manager.libraryRevision

    manager.invalidateCache()

    // Inside the same synchronous actor frame that called invalidateCache,
    // libraryRevision MUST still hold its prior value. The buggy code
    // bumped it here, which fired `@Published` sinks (including
    // `TimelineSidebarView.onChange`) before the count-cache wipe Task
    // had a chance to run — letting those sinks read stale counts.
    #expect(
      manager.libraryRevision == initial,
      """
      libraryRevision bumped synchronously inside invalidateCache (was \(initial), \
      now \(manager.libraryRevision)). The fix must defer the bump until the \
      count-cache invalidation completes so observers don't race a stale cache. \
      See issue #104.
      """)

    // After the deferred work lands, the bump must arrive — otherwise
    // sidebars stop self-healing after Photos.app mutations entirely.
    var waited = 0
    while manager.libraryRevision == initial && waited < 200 {
      try? await Task.sleep(nanoseconds: 5_000_000)
      waited += 1
    }

    #expect(
      manager.libraryRevision == initial &+ 1,
      """
      libraryRevision never bumped after invalidateCache (still \(manager.libraryRevision) \
      after \(waited * 5) ms). The deferred bump path must reach the &+= assignment.
      """)
  }
}
