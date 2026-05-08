import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 0a (auto-sync plan): the awaitable `runExport(context:) async -> ExportRunSummary`
/// API. MVP coverage maps `.timelineFullLibrary`, `.favoritesFull`, and `.allAlbumsFull`
/// to the existing fire-and-forget start* methods; targeted asset-id and `.autoExport`
/// scopes resolve immediately with `.failed` until later slices implement them.
@MainActor
struct ExportManagerRunExportTests {

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() {
      manager.cancelAndClear()
      store.flushForTesting()
      try? FileManager.default.removeItem(at: storeRoot)
      dest.cleanup()
      UserDefaults().removePersistentDomain(forName: userDefaultsSuite)
    }
  }

  private func makeHarness() -> Harness {
    let photoLib = FakePhotoLibraryService()
    let dest = FakeExportDestination()
    let writer = FakeAssetResourceWriter()
    let fileSystem = FakeFileSystem()
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExportManagerRunExport-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-ExportManagerRunExport-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let manager = ExportManager(
      photoLibraryService: photoLib,
      exportDestination: dest,
      exportRecordStore: store,
      collectionExportRecordStore: collectionStore,
      assetResourceWriter: writer,
      fileSystem: fileSystem,
      userDefaults: defaults
    )
    return Harness(
      manager: manager, photoLib: photoLib, dest: dest,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  private func makeContext(scope: ExportRunScope) -> ExportRunContext {
    ExportRunContext(
      source: .manual,
      visibility: .userVisible,
      scope: scope,
      selection: .edited
    )
  }

  // MARK: - Empty library

  /// `runExport` against an empty Photos library resolves immediately with `.completed`
  /// — `processQueueIfNeeded` early-returns on the empty queue and finalizes the run.
  @Test func timelineFullLibraryEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { harness.cleanup() }
    // Empty `yearCounts` → availableYears() returns []; nothing to enqueue.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .timelineFullLibrary))

    #expect(summary.result == .completed)
    #expect(summary.cancelReason == nil)
    #expect(summary.enqueuedCount == 0)
    #expect(summary.completedCount == 0)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// `.favoritesFull` against an empty favorites collection resolves immediately.
  @Test func favoritesFullEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { harness.cleanup() }
    // `favoritesAssets` is empty by default.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .favoritesFull))

    #expect(summary.result == .completed)
    #expect(harness.manager.activeRunContext == nil)
  }

  /// `.allAlbumsFull` against an empty album set resolves immediately.
  @Test func allAlbumsFullEmptyResolvesCompleted() async {
    let harness = makeHarness()
    defer { harness.cleanup() }
    // `collectionTree` is empty by default.

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .allAlbumsFull))

    #expect(summary.result == .completed)
    #expect(harness.manager.activeRunContext == nil)
  }

  // MARK: - Targeted scopes (not implemented yet)

  @Test func timelineAssetsScopeResolvesFailedForNow() async {
    let harness = makeHarness()
    defer { harness.cleanup() }

    let summary = await harness.manager.runExport(
      context: makeContext(scope: .timelineAssets(["asset-1"])))

    #expect(summary.result == .failed)
    #expect(harness.manager.activeRunContext == nil)
  }

  @Test func autoExportScopeResolvesFailedForNow() async {
    let harness = makeHarness()
    defer { harness.cleanup() }

    let summary = await harness.manager.runExport(
      context: makeContext(
        scope: .autoExport(
          AutoExportScopeSelection(timeline: true, favorites: true, albums: false))))

    #expect(summary.result == .failed)
    #expect(harness.manager.activeRunContext == nil)
  }

  // MARK: - Destination-unavailable interruption

  /// `interruptForDestinationUnavailable()` resolves the active run as transient —
  /// `result == .interrupted`, `cancelReason == .destinationUnavailable` — distinct
  /// from `cancelAndClear`'s `.cancelled / .userCancelled`. AutoSync uses this signal
  /// to resume after the drive returns rather than treating queued work as failed.
  @Test func interruptForDestinationUnavailableResolvesAsInterrupted() async {
    let harness = makeHarness()
    defer { harness.cleanup() }

    async let summaryTask = harness.manager.runExport(
      context: makeContext(scope: .timelineFullLibrary))

    // Yield to let the run begin; then simulate a drive unmount.
    await Task.yield()
    harness.manager.interruptForDestinationUnavailable()
    let summary = await summaryTask

    // Either the run finished naturally (empty library completes immediately) or the
    // interrupt won the race. Both outcomes are valid; what we're proving is that
    // calling interrupt while a run is in flight resolves cleanly without hanging.
    #expect(harness.manager.activeRunContext == nil)
    if summary.result == .interrupted {
      #expect(summary.cancelReason == .destinationUnavailable)
    } else {
      // Empty-library case raced ahead — verify it at least resolved.
      #expect(summary.result == .completed || summary.result == .interrupted)
    }
  }

  // MARK: - Run context surfacing

  /// `activeRunContext` is set while a run is in flight and cleared once the awaitable
  /// resolves. The published value flips through nil → ctx → nil; future SwiftUI views
  /// can observe this directly.
  @Test func activeRunContextSurfacesAndClears() async {
    let harness = makeHarness()
    defer { harness.cleanup() }

    var observedContexts: [ExportRunContext?] = []
    let cancellable = harness.manager.$activeRunContext.sink { ctx in
      observedContexts.append(ctx)
    }
    defer { cancellable.cancel() }

    let context = makeContext(scope: .timelineFullLibrary)
    _ = await harness.manager.runExport(context: context)

    // The publisher should emit: initial nil (Combine replays current value), then the
    // run's context when set, then nil again when finalize clears it.
    #expect(observedContexts.contains(where: { $0 == context }))
    #expect(harness.manager.activeRunContext == nil)
    // Last published value is nil — run cleared the context after finalize.
    if let last = observedContexts.last {
      #expect(last == nil)
    } else {
      Issue.record("Expected at least one observed value")
    }
  }
}
