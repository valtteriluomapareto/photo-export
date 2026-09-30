import AppKit
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
      if grid == .timeline {
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
          selectedAsset: $selection.asset, photoLibraryService: service)
      }
    }
  }

  @MainActor
  private final class Fixture {
    let selection = Selection()
    let service = FakePhotoLibraryService()
    let timelineStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let root: URL
    let defaults: UserDefaults
    let defaultsName: String
    let window: NSWindow

    init(grid: Grid) {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GridSelection-\(UUID().uuidString)", isDirectory: true)
      defaultsName = "GridSelection-\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: defaultsName)!
      timelineStore = ExportRecordStore(baseDirectoryURL: root)
      collectionStore = CollectionExportRecordStore(baseDirectoryURL: root)
      timelineStore.configure(for: "grid-test")
      collectionStore.configure(for: "grid-test")
      let manager = ExportManager(
        photoLibraryService: service, exportDestination: FakeExportDestination(),
        exportRecordStore: timelineStore, collectionExportRecordStore: collectionStore,
        assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
        userDefaults: defaults)
      let hosted = NSHostingView(
        rootView: HostedGrid(grid: grid, service: service, selection: selection)
          .environmentObject(PhotoLibraryManager(overrideService: service))
          .environmentObject(timelineStore)
          .environmentObject(collectionStore)
          .environmentObject(manager)
          .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults)))
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
  /// deadline bounds a failed observation; stream continuations control all races.
  /// Allow CI's parallel MainActor tests to finish before the first render pass.
  private func observe(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while !condition(), !Task.isCancelled, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
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
}
