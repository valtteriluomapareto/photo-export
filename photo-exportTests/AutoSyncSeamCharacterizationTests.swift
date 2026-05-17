import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Characterization test for the AutoSync seam preservation contract.
///
/// Per `docs/reference/architecture-conventions.md` §AutoSync seam preservation,
/// this is the regression gate that pins the AutoSync-observable emission sequence.
/// The contract: across a manual export and an import, AutoSync subscribers see the
/// canonical state-transition sequence `idle → manual-active → idle → importing →
/// idle`, plus exactly one completion summary for the export.
///
/// The test asserts on the canonical sequence (after de-duplicating adjacent
/// identical states) rather than raw frame count, because
/// `exportRunStatePublisher` is a `CombineLatest3` over three `@Published`
/// mirrors and intermediate triples land in unobservable order across `await`
/// hops. Asserting raw counts or exact emission timing would flake under future
/// refactors that reorder property mutation; asserting canonical transitions
/// captures the invariant AutoSync actually depends on.
@MainActor
struct AutoSyncSeamCharacterizationTests {

  // MARK: - Canonical state

  /// Three-valued canonicalization of `ExportRunState`. AutoSync reads
  /// `(isManualActive, isAutoSyncActive)` to decide whether to start a background
  /// run; the active-context payload it uses for telemetry isn't part of the
  /// gating decision, so collapsing it to one of three states is the right shape
  /// for a regression gate.
  private enum CanonicalRunState: Equatable {
    case idle
    case manualActive
    case autoSyncActive

    init(_ state: ExportRunState) {
      if state.isAutoSyncActive {
        self = .autoSyncActive
      } else if state.isManualActive {
        self = .manualActive
      } else {
        self = .idle
      }
    }
  }

  // MARK: - Harness

  @MainActor
  private struct Harness {
    let manager: ExportManager
    let photoLib: FakePhotoLibraryService
    let dest: FakeExportDestination
    let writer: FakeAssetResourceWriter
    let store: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let storeRoot: URL
    let userDefaultsSuite: String

    func cleanup() async {
      if let checkpoint = writer.checkpoint {
        await checkpoint.releaseAll()
      }
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
      .appendingPathComponent("AutoSyncSeam-\(UUID().uuidString)", isDirectory: true)
    let store = ExportRecordStore(baseDirectoryURL: storeRoot)
    store.configure(for: "test")
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    collectionStore.configure(for: "test")
    let suiteName = "test-AutoSyncSeam-\(UUID().uuidString)"
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
      manager: manager, photoLib: photoLib, dest: dest, writer: writer,
      store: store, collectionStore: collectionStore,
      storeRoot: storeRoot, userDefaultsSuite: suiteName)
  }

  /// Drops adjacent duplicates while preserving order.
  private static func canonicalize<T: Equatable>(_ values: [T]) -> [T] {
    var result: [T] = []
    for value in values where result.last != value {
      result.append(value)
    }
    return result
  }

  // MARK: - Tests

  /// The regression gate for the AutoSync seam. A manual `runExport(context:)` for a
  /// one-asset favorites scope (gated so the queue passes through observable states)
  /// followed by `startImport()` against an empty backup folder must yield:
  ///
  /// - `exportRunStatePublisher` (canonical): `[idle, manualActive, idle]`
  /// - `isImportingPublisher`: `[false, true, false]`
  /// - `completedRunsPublisher`: exactly one summary, carrying the original context
  ///
  /// Re-run after every phase. A failure means an extraction reordered the publisher
  /// sources AutoSync observes — fix the extraction, not the test.
  @Test func manualExportThenImportYieldsCanonicalSequence() async throws {
    let harness = makeHarness()
    defer { Task { await harness.cleanup() } }

    // Seed one favorite asset so `.favoritesFull` actually enqueues a job.
    let asset = TestAssetFactory.makeAsset(id: "a1")
    harness.photoLib.favoritesAssets = [asset]
    harness.photoLib.resourcesByAssetId["a1"] = [
      TestAssetFactory.makeResource(originalFilename: "a1.HEIC")
    ]
    // Gate the writer so we pass through the manual-active state long enough for
    // the subscribed sinks to observe it.
    let writeGate = AsyncCheckpoint()
    harness.writer.checkpoint = writeGate

    // Subscribe BEFORE any work starts. `@Published`-backed publishers replay their
    // current value on subscription, so this captures the initial `idle`/`false`
    // baseline plus every subsequent emission.
    var runStateEmissions: [ExportRunState] = []
    var isImportingEmissions: [Bool] = []
    var completedSummaries: [ExportRunSummary] = []

    let cancellables: [AnyCancellable] = [
      harness.manager.exportRunStatePublisher.sink { runStateEmissions.append($0) },
      harness.manager.isImportingPublisher.sink { isImportingEmissions.append($0) },
      harness.manager.completedRunsPublisher.sink { completedSummaries.append($0) },
    ]
    defer { cancellables.forEach { $0.cancel() } }

    // Phase A: manual export via the awaitable run API.
    let context = ExportRunContext(
      source: .manual, visibility: .userVisible,
      scope: .favoritesFull, selection: .edited)

    async let summaryTask = harness.manager.runExport(context: context)
    await writeGate.waitForEnter(count: 1)
    await writeGate.release(1)
    let summary = await summaryTask
    #expect(summary.result == .completed)

    // Phase B: import an empty backup folder. `startImport()` flips `isImporting`
    // synchronously; the body resolves quickly because the scan finds nothing.
    harness.manager.startImport()
    await harness.manager.waitForImportCompletion()

    // Phase C: canonical-sequence assertions.
    let canonicalRunStates = Self.canonicalize(
      runStateEmissions.map(CanonicalRunState.init))
    let canonicalImporting = Self.canonicalize(isImportingEmissions)

    #expect(
      canonicalRunStates == [.idle, .manualActive, .idle],
      """
      AutoSync seam contract violation: exportRunStatePublisher canonical sequence \
      must be [idle, manualActive, idle] for a manual export. Got: \(canonicalRunStates)
      """)
    #expect(
      canonicalImporting == [false, true, false],
      """
      AutoSync seam contract violation: isImportingPublisher canonical sequence \
      must be [false, true, false] for one import. Got: \(canonicalImporting)
      """)
    #expect(
      completedSummaries.count == 1,
      """
      completedRunsPublisher must emit exactly one summary per runExport completion; \
      got \(completedSummaries.count)
      """)
    #expect(
      completedSummaries.first?.context == context,
      "completion summary must carry the original run context")
  }
}
