import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

/// Mounts the actual grid views, including the timeline's Equatable wrapper, so
/// these tests exercise the parent/detail binding rather than only model state.
@MainActor
@Suite(.serialized)
struct LibraryGridSelectionLifecycleTests {
  enum Grid: CaseIterable {
    case timeline, favorites, album, sharedAlbum

    func scope(_ index: Int) -> PhotoFetchScope {
      switch self {
      case .timeline: return .timeline(year: 2026, month: index + 1)
      case .favorites: return index == 0 ? .favorites : .album(collectionId: "other")
      case .album: return .album(collectionId: "album-\(index)")
      case .sharedAlbum: return .sharedAlbum(collectionId: "shared-\(index)")
      }
    }

    func selection(_ index: Int) -> LibrarySelection {
      switch scope(index) {
      case .timeline(let year, let month): return .timelineMonth(year: year, month: month ?? 1)
      case .favorites: return .favorites
      case .album(let id): return .album(collectionId: id)
      case .sharedAlbum(let id): return .sharedAlbum(collectionId: id)
      }
    }
  }

  @MainActor
  private final class Selection: ObservableObject {
    @Published var scopeIndex = 0
    @Published var asset: AssetDescriptor?
    @Published var isVisible = true

    func switchScope(to index: Int) {
      scopeIndex = index
      asset = nil
    }
  }

  @MainActor
  private struct HostedGrid: View {
    let grid: Grid
    let service: FakePhotoLibraryService
    @ObservedObject var selection: Selection

    var body: some View {
      if !selection.isVisible {
        Color.clear
      } else if grid == .timeline {
        MonthContentView(
          year: 2026, month: selection.scopeIndex + 1,
          versionSelection: .edited, livePhotosPaired: false,
          onExportMonth: {}, selectedAsset: $selection.asset,
          photoLibraryService: service
        )
        .equatable()
      } else {
        CollectionContentView(
          selection: grid.selection(selection.scopeIndex), title: "Test collection",
          versionSelection: .edited, livePhotosPaired: false, onExportCollection: {},
          selectedAsset: $selection.asset, photoLibraryService: service
        )
        .equatable()
      }
    }
  }

  @MainActor
  private final class Fixture {
    let selection = Selection()
    let counter = BodyInvalidationCounter()
    let service = FakePhotoLibraryService()
    let library: PhotoLibraryManager
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let root: URL
    let defaults: UserDefaults
    let defaultsName: String
    let window: NSWindow
    let hostingView: NSView

    init(grid: Grid) {
      root = TestScratch.directory("GridSelection")
      defaultsName = TestScratch.suiteName("GridSelection")
      defaults = TestScratch.defaults(suiteName: defaultsName)
      timelineStore = ExportRecordStore(baseDirectoryURL: root)
      collectionStore = CollectionExportRecordStore(baseDirectoryURL: root)
      timelineStore.configure(for: "grid-test")
      collectionStore.configure(for: "grid-test")
      library = PhotoLibraryManager(overrideService: service)
      let manager = ExportManager(
        photoLibraryService: service, exportDestination: FakeExportDestination(),
        exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
        assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
        userDefaults: defaults)
      let hosted = NSHostingView(
        rootView: HostedGrid(grid: grid, service: service, selection: selection)
          .environmentObject(library)
          .environment(\.bodyInvalidationCounter, counter)
          .environmentObject(timelineStore)
          .environmentObject(collectionStore)
          .environmentObject(manager)
          .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults)))
      hostingView = hosted
      window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = hosted

    }

    func show() { window.orderFront(nil) }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      timelineStore.flushForTesting()
      collectionStore.flushForTesting()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: defaultsName)
    }
  }

  /// SwiftUI schedules render passes independently of the stream producer. The
  /// test's time limit bounds a failed observation; stream continuations control
  /// all races.
  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func disappearingGridReleasesItsPreheatWindowAndReappears(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let assets = [
      TestAssetFactory.makeAsset(id: "first"), TestAssetFactory.makeAsset(id: "second"),
    ]
    fixture.service.progressiveStreamOverride = { _ in
      AsyncThrowingStream { continuation in
        continuation.yield(assets)
        continuation.finish()
      }
    }
    defer { fixture.close() }
    fixture.show()
    let loaded = await observe { fixture.service.startCachingCalls.count == 1 }
    try #require(loaded)
    fixture.selection.isVisible = false
    let stopped = await observe { fixture.service.stopCachingCalls.count == 1 }
    try #require(stopped, "Removing a loaded grid must release its preheat registrations")
    #expect(fixture.service.stopCachingCalls[0].map(\.id) == assets.map(\.id))

    fixture.selection.isVisible = true
    let reloaded = await observe { fixture.service.startCachingCalls.count == 2 }
    try #require(reloaded)
    #expect(fixture.service.startCachingCalls[1].map(\.id) == assets.map(\.id))
    fixture.selection.isVisible = false
    let stoppedAgain = await observe { fixture.service.stopCachingCalls.count == 2 }
    #expect(stoppedAgain)
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func removingGridDuringLoadCannotRegisterItsLateWindow(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let old = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let terminated = AsyncCheckpoint()
    old.continuation.onTermination = { _ in Task { await terminated.enter() } }
    var requests = 0
    let current = TestAssetFactory.makeAsset(id: "current")
    fixture.service.progressiveStreamOverride = { _ in
      requests += 1
      if requests == 1 { return old.stream }
      return AsyncThrowingStream { continuation in
        continuation.yield([current])
        continuation.finish()
      }
    }
    try await withCleanup {
      fixture.show()
      let began = await observe { requests == 1 }
      try #require(began)
      old.continuation.yield([TestAssetFactory.makeAsset(id: "obsolete")])
      fixture.selection.isVisible = false
      await terminated.waitForEnter(count: 1)
      await terminated.releaseAll()
      old.continuation.finish()
      fixture.selection.isVisible = true
      let loaded = await observe { fixture.service.startCachingCalls.count == 1 }
      try #require(loaded)
      #expect(fixture.service.startCachingCalls[0].map(\.id) == ["current"])
    } cleanup: {
      old.continuation.finish()
      fixture.close()
      await terminated.releaseAll()
    }
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func retainedGridRestartsPreheatAfterReattachingToWindow(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let asset = TestAssetFactory.makeAsset(id: "same-grid")
    fixture.service.progressiveStreamOverride = { _ in
      AsyncThrowingStream { continuation in
        continuation.yield([asset])
        continuation.finish()
      }
    }
    defer { fixture.close() }
    fixture.show()
    let loaded = await observe { fixture.service.startCachingCalls.count == 1 }
    try #require(loaded)
    fixture.window.contentView = nil
    let stopped = await observe { fixture.service.stopCachingCalls.count == 1 }
    try #require(stopped)
    // Preserve the hosting view and its StateObject rather than recreate the grid.
    fixture.window.contentView = fixture.hostingView
    let reloaded = await observe { fixture.service.startCachingCalls.count == 2 }
    try #require(reloaded)
    #expect(fixture.service.startCachingCalls[1].map(\.id) == ["same-grid"])
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func firstBatchSelectsDetailBeforeStreamFinishesAndKeepsUserChoice(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let stream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    var requested = false
    fixture.service.progressiveStreamOverride = { _ in
      requested = true
      return stream.stream
    }
    defer {
      stream.continuation.finish()
      fixture.close()
    }
    fixture.show()
    let began = await observe { requested }
    try #require(began)
    let first = TestAssetFactory.makeAsset(id: "first")
    let chosen = TestAssetFactory.makeAsset(id: "chosen")
    stream.continuation.yield([first, chosen])

    // The stream remains open: awaiting its completion cannot satisfy this check.
    let selectedFirst = await observe { fixture.selection.asset == first }
    try #require(selectedFirst)
    #expect(fixture.service.startCachingCalls.isEmpty)

    fixture.selection.asset = chosen
    stream.continuation.yield([TestAssetFactory.makeAsset(id: "last")])
    stream.continuation.finish()
    let finished = await observe { !fixture.service.startCachingCalls.isEmpty }
    try #require(finished)
    #expect(fixture.service.startCachingCalls.last?.count == 3)
    #expect(fixture.selection.asset == chosen)
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func rapidScopeChangesDoNotSelectAssetsFromObsoleteLoads(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let first = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let second = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let third = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let streams = [first, second, third]
    var requestedScopes: [PhotoFetchScope] = []
    fixture.service.progressiveStreamOverride = { scope in
      let index = requestedScopes.count
      requestedScopes.append(scope)
      return index < streams.count ? streams[index].stream : nil
    }
    defer {
      for stream in streams { stream.continuation.finish() }
      fixture.close()
    }
    fixture.show()
    let beganFirst = await observe { requestedScopes.count == 1 }
    try #require(beganFirst)
    let initial = TestAssetFactory.makeAsset(id: "initial")
    first.continuation.yield([initial])
    let selectedFirst = await observe { fixture.selection.asset == initial }
    try #require(selectedFirst)

    fixture.selection.switchScope(to: 1)
    let beganSecond = await observe { requestedScopes.count == 2 }
    try #require(beganSecond)
    #expect(fixture.selection.asset == nil)
    fixture.selection.switchScope(to: 0)
    let beganThird = await observe { requestedScopes.count == 3 }
    try #require(beganThird)
    #expect(fixture.selection.asset == nil)

    second.continuation.yield([TestAssetFactory.makeAsset(id: "obsolete")])
    second.continuation.finish()
    first.continuation.finish()
    // Returning to the same scope and first asset must still populate the binding.
    third.continuation.yield([initial])
    let selectedCurrent = await observe { fixture.selection.asset == initial }
    try #require(selectedCurrent)
    third.continuation.finish()
    let finished = await observe { !fixture.service.startCachingCalls.isEmpty }
    try #require(finished)
    #expect(requestedScopes == [grid.scope(0), grid.scope(1), grid.scope(0)])
    #expect(fixture.selection.asset == initial)
  }

  @Test(.timeLimit(.minutes(1)), arguments: Grid.allCases, [false, true])
  func emptyAndFailedLoadsAllowNextScopeSelection(grid: Grid, fails: Bool) async throws {
    let fixture = Fixture(grid: grid)
    let stream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    let nextStream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    var requests = 0
    fixture.service.progressiveStreamOverride = { _ in
      requests += 1
      return requests == 1 ? stream.stream : nextStream.stream
    }
    defer {
      stream.continuation.finish()
      nextStream.continuation.finish()
      fixture.close()
    }
    fixture.show()
    let began = await observe { requests == 1 }
    try #require(began)
    if fails {
      stream.continuation.finish(throwing: CocoaError(.fileReadUnknown))
    } else {
      stream.continuation.finish()
    }
    fixture.selection.switchScope(to: 1)
    let beganNext = await observe { requests == 2 }
    try #require(beganNext)
    #expect(fixture.selection.asset == nil)
    let next = TestAssetFactory.makeAsset(id: "after-empty-or-error")
    nextStream.continuation.yield([next])
    let selectedNext = await observe { fixture.selection.asset == next }
    try #require(selectedNext)
  }
  @Test(.timeLimit(.minutes(1)), arguments: Grid.allCases)
  func parentOnlySelectionChangeRendersTheCurrentHighlight(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let a = TestAssetFactory.makeAsset(id: "A")
    let b = TestAssetFactory.makeAsset(id: "B")
    fixture.service.progressiveStreamOverride = { _ in
      AsyncThrowingStream {
        $0.yield([a, b])
        $0.finish()
      }
    }
    defer { fixture.close() }
    fixture.show()
    let loaded = await observe {
      fixture.selection.asset == a && !fixture.service.startCachingCalls.isEmpty
    }
    try #require(loaded)
    fixture.counter.reset()
    fixture.selection.asset = b
    let highlighted = await observe { fixture.counter.count(for: "selected:B") > 0 }
    #expect(highlighted, "A parent-only ID change must reach the actual grid rendering input")
  }

  enum RefreshMutation: CaseIterable { case metadata, removal, empty }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases, RefreshMutation.allCases)
  func refreshSynchronizesTheParentDetail(grid: Grid, mutation: RefreshMutation) async throws {
    let fixture = Fixture(grid: grid)
    let a = TestAssetFactory.makeAsset(id: "A")
    let b = TestAssetFactory.makeAsset(id: "B")
    let c = TestAssetFactory.makeAsset(id: "C")
    let revised = TestAssetFactory.makeAsset(
      id: "B", pixelWidth: 701, pixelHeight: 502, hasAdjustments: true)
    var snapshot = [a, b, c]
    var requests = 0
    fixture.service.progressiveStreamOverride = { _ in
      requests += 1
      return AsyncThrowingStream {
        $0.yield(snapshot)
        $0.finish()
      }
    }
    defer { fixture.close() }
    fixture.show()
    let loaded = await observe { fixture.selection.asset == a }
    try #require(loaded)
    fixture.selection.asset = b
    var transitions: [AssetDescriptor?] = []
    let subscription = fixture.selection.$asset.dropFirst().sink { transitions.append($0) }
    defer { subscription.cancel() }
    switch mutation {
    case .metadata: snapshot = [a, revised, c]
    case .removal: snapshot = [c, a]
    case .empty: snapshot = []
    }
    let expected: AssetDescriptor? =
      mutation == .metadata ? revised : mutation == .removal ? c : nil
    fixture.library.invalidateCache(changedThumbnailAssetIDs: [])
    let refreshed = await observe { fixture.selection.asset == expected }
    #expect(requests == 2)
    #expect(refreshed, "The actual grid must reconcile its parent detail after refresh")
    if mutation != .empty { #expect(!transitions.contains(where: { $0 == nil })) }
    if mutation == .metadata { #expect(!transitions.contains(where: { $0?.id == a.id })) }
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func heldRefreshPreservesTheLatestBindingChoice(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let a = TestAssetFactory.makeAsset(id: "A")
    let b = TestAssetFactory.makeAsset(id: "B")
    let revised = TestAssetFactory.makeAsset(id: "B", pixelWidth: 777, hasAdjustments: true)
    let refresh = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    var requests = 0
    fixture.service.progressiveStreamOverride = { _ in
      requests += 1
      if requests == 2 { return refresh.stream }
      return AsyncThrowingStream {
        $0.yield([a, b])
        $0.finish()
      }
    }
    defer {
      refresh.continuation.finish()
      fixture.close()
    }
    fixture.show()
    let loaded = await observe { fixture.selection.asset == a }
    try #require(loaded)
    fixture.library.invalidateCache(changedThumbnailAssetIDs: [])
    let began = await observe { requests == 2 }
    try #require(began)
    #expect(fixture.selection.asset == a, "An in-flight refresh retains the displayed snapshot")
    fixture.selection.asset = b  // Deliberately do not call model.select.
    refresh.continuation.yield([a, revised])
    refresh.continuation.finish()
    let updated = await observe { fixture.selection.asset == revised }
    #expect(updated)
  }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases)
  func progressiveFutureBatchChoiceIsNotCleared(grid: Grid) async throws {
    let fixture = Fixture(grid: grid)
    let stream = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    fixture.service.progressiveStreamOverride = { _ in stream.stream }
    defer {
      stream.continuation.finish()
      fixture.close()
    }
    fixture.show()
    let a = TestAssetFactory.makeAsset(id: "A")
    let later = TestAssetFactory.makeAsset(id: "later")
    stream.continuation.yield([a])
    let loaded = await observe { fixture.selection.asset == a }
    try #require(loaded)
    fixture.selection.asset = later
    // Force another render/selection projection before its batch arrives.
    stream.continuation.yield([TestAssetFactory.makeAsset(id: "middle")])
    let delivered = await observe {
      fixture.service.decodedThumbnailCalls.contains { $0.assetId == "middle" }
    }
    try #require(delivered)
    #expect(fixture.selection.asset == later)
    stream.continuation.yield([later])
    stream.continuation.finish()
    let finished = await observe { fixture.service.startCachingCalls.last?.count == 3 }
    try #require(finished)
    #expect(fixture.selection.asset == later)
  }

  enum StaleOutcome: CaseIterable { case empty, metadata, failure }

  @Test(.timeLimit(.minutes(2)), arguments: Grid.allCases, StaleOutcome.allCases)
  func obsoleteRefreshCannotClearOrReplaceReturnedScope(grid: Grid, outcome: StaleOutcome)
    async throws
  {
    let fixture = Fixture(grid: grid)
    let old = TestAssetFactory.makeAsset(id: "same")
    let current = TestAssetFactory.makeAsset(id: "same", pixelWidth: 999, hasAdjustments: true)
    let refresh = AsyncThrowingStream<[AssetDescriptor], any Error>.makeStream()
    var requests = 0
    fixture.service.progressiveStreamOverride = { _ in
      requests += 1
      if requests == 2 { return refresh.stream }
      let asset = requests == 1 ? old : current
      return AsyncThrowingStream {
        $0.yield([asset])
        $0.finish()
      }
    }
    defer {
      refresh.continuation.finish()
      fixture.close()
    }
    fixture.show()
    let loaded = await observe { fixture.selection.asset == old }
    try #require(loaded)
    fixture.library.invalidateCache(changedThumbnailAssetIDs: [])
    let began = await observe { requests == 2 }
    try #require(began)
    fixture.selection.switchScope(to: 1)
    let changed = await observe { requests == 3 && fixture.selection.asset == current }
    try #require(changed)
    fixture.selection.switchScope(to: 0)
    let returned = await observe { requests == 4 && fixture.selection.asset == current }
    try #require(returned)
    var transitions: [AssetDescriptor?] = []
    let subscription = fixture.selection.$asset.dropFirst().sink { transitions.append($0) }
    defer { subscription.cancel() }
    switch outcome {
    case .empty:
      refresh.continuation.yield([])
      refresh.continuation.finish()
    case .metadata:
      refresh.continuation.yield([old])
      refresh.continuation.finish()
    case .failure: refresh.continuation.finish(throwing: CocoaError(.fileReadUnknown))
    }
    // Acknowledge completion of the obsolete consumer itself, without starting
    // another refresh that could invalidate/mask a stale write.
    let settled = await observe { fixture.counter.count(for: "grid-refresh-finished") == 1 }
    try #require(settled)
    #expect(requests == 4)
    #expect(fixture.selection.asset == current)
    #expect(!transitions.contains(where: { $0 == nil || $0 == old }))
  }

}
