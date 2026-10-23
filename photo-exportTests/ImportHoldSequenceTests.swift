import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ImportHoldSequenceTests {
  @MainActor
  private final class Trace {
    private(set) var holds: [Bool] = []
    private(set) var flags: [Bool] = []
    private var subscriptions = Set<AnyCancellable>()

    init(_ manager: ExportManager) {
      manager.isImportingPublisher.sink { [weak self] in
        self?.holds.append($0)
      }.store(in: &subscriptions)
      manager.isImportingFlagOnlyPublisher.sink { [weak self] in
        self?.flags.append($0)
      }.store(in: &subscriptions)
    }

    func stop() { subscriptions.removeAll() }
  }

  private static let italy = ExportPlacement(
    kind: .album, id: "collections:album:abc:def", displayName: "Italy",
    collectionLocalIdentifier: "album-1", relativePath: "Collections/Albums/Italy/",
    createdAt: Date(timeIntervalSince1970: 1_700_000_000))

  private func seedHistory(_ h: ExportManagerHarness) {
    h.store.markVariantExported(
      assetId: "asset-A", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "A.HEIC", exportedAt: Date())
    h.store.markVariantExported(
      assetId: "asset-B", variant: .original, year: 2025, month: 3,
      relPath: "2025/03/", filename: "B.HEIC", exportedAt: Date())
    h.collectionStore.upsertPlacement(Self.italy)
    h.collectionStore.markVariantExported(
      assetId: "asset-C", placement: Self.italy, variant: .original,
      filename: "C.HEIC", exportedAt: Date())
  }

  private func finishImport(_ h: ExportManagerHarness) async throws {
    let task = try #require(h.manager.importTask)
    _ = await finished(task)
  }

  private func close(_ h: ExportManagerHarness, trace: Trace) async {
    trace.stop()
    let pending = h.manager.importTask
    h.manager.cancelAndClear()
    if let pending { _ = await finished(pending) }
    try? await h.store.flush()
    try? await h.collectionStore.flush()
    h.dest.cleanup()
    try? FileManager.default.removeItem(at: h.storeRoot)
  }

  /// Already passes: an ordinary import holds exports exactly until its task completes.
  @Test func plainImportHoldsOnceAndReleasesOnce() async throws {
    let h = ExportManagerHarness(label: "ImportHoldPlain")
    let trace = Trace(h.manager)
    try await withCleanup {
      h.manager.startImport()
      try await finishImport(h)
      #expect(trace.holds == [false, true, false])
      #expect(trace.flags == [false, true, false])
    } cleanup: {
      await close(h, trace: trace)
    }
  }

  /// Already passes: a completed missing-backup check retains its hold after activity ends.
  @Test func missingBackupKeepsTheHoldAfterTheImportEnds() async throws {
    let h = ExportManagerHarness(label: "ImportHoldMissing")
    let trace = Trace(h.manager)
    seedHistory(h)
    try await withCleanup {
      h.manager.startImportForConfirmedSameFolder()
      try await finishImport(h)
      try #require(h.manager.previousBackupMissing)
      #expect(trace.holds == [false, true])
      #expect(trace.flags == [false, true, false])
    } cleanup: {
      await close(h, trace: trace)
    }
  }

  /// Already passes: reacquiring the active flag precedes clearing the existing missing hold.
  @Test func recheckWhileMissingHasNoGap() async throws {
    let h = ExportManagerHarness(label: "ImportHoldRecheck")
    let trace = Trace(h.manager)
    seedHistory(h)
    try await withCleanup {
      h.manager.startImportForConfirmedSameFolder()
      try await finishImport(h)
      try #require(h.manager.previousBackupMissing)
      h.manager.startImportForConfirmedSameFolder()
      #expect(trace.holds == [false, true])
      try await finishImport(h)
      #expect(trace.holds == [false, true])
      #expect(trace.flags == [false, true, false, true, false])
    } cleanup: {
      await close(h, trace: trace)
    }
  }

  /// Already passes: abandoning a missing-backup decision releases the composite hold once.
  @Test func cancelAndClearReleasesAMissingBackupHold() async throws {
    let h = ExportManagerHarness(label: "ImportHoldClear")
    let trace = Trace(h.manager)
    seedHistory(h)
    try await withCleanup {
      h.manager.startImportForConfirmedSameFolder()
      try await finishImport(h)
      try #require(h.manager.previousBackupMissing)
      h.manager.cancelAndClear()
      #expect(trace.holds == [false, true, false])
      #expect(trace.flags == [false, true, false])
    } cleanup: {
      await close(h, trace: trace)
    }
  }

  /// Delivery and missing-flag isolation already hold before replacing the Published storage.
  @Test func missingBackupFlagNotifiesOnlyItself() async throws {
    let h = ExportManagerHarness(label: "ImportHoldDependency")
    let trace = Trace(h.manager)
    seedHistory(h)
    try await withCleanup {
      h.manager.startImportForConfirmedSameFolder()
      try await finishImport(h)
      try #require(h.manager.previousBackupMissing)
      let missing = ObservationProbe { _ = h.manager.previousBackupMissing }
      let importing = ObservationProbe { _ = h.manager.isImporting }
      let stage = ObservationProbe { _ = h.manager.importStage }
      h.manager.clearPreviousBackupMissing()
      #expect(missing.changeCount == 1)
      #expect(importing.changeCount == 0)
      #expect(stage.changeCount == 0)
      #expect(trace.holds == [false, true, false])
      #expect(trace.flags == [false, true, false])
    } cleanup: {
      await close(h, trace: trace)
    }
  }
}
