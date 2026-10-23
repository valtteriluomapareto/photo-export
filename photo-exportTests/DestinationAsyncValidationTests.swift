import AppKit
import Combine
import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DestinationAsyncValidationTests {
  private final class Probe: DestinationValidationProbing, @unchecked Sendable {
    let entered = AsyncCheckpoint()
    let calls = LockedBox<[Bool]>([])
    private let gate = DispatchSemaphore(value: 0)
    let heldPath: String
    init(heldPath: String) { self.heldPath = heldPath }
    func inspect(_ url: URL) -> DestinationValidationResult {
      calls.mutate { $0.append(pthread_main_np() == 0) }
      if url.lastPathComponent == heldPath {
        Task { await entered.enter() }
        gate.wait()
      }
      let fingerprint = DestinationFingerprint.makeLow(
        volumeRootPath: nil, relativePathFromVolumeRoot: url.path, standardizedPath: url.path)
      return DestinationValidationResult(
        isAvailable: true, isWritable: true, status: .ready, fingerprint: fingerprint)
    }
    func release() { gate.signal() }
  }

  @Test func newerRootClosesAdmissionAndSupersedesHeldValidation() async throws {
    let root = TestScratch.directory("AsyncValidation")
    let a = root.appendingPathComponent("A")
    let b = root.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    let probe = Probe(heldPath: "A")
    let opened = LockedBox<[URL]>([])
    let closed = LockedBox<[URL]>([])
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("AsyncValidation"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { url in
        opened.mutate { $0.append(url) }
        return true
      },
      validationScopeReleaser: { url in closed.mutate { $0.append(url) } }, validationProbe: probe)
    defer {
      probe.release()
      manager.clearSelection()
    }
    var publishedPaths: [String] = []
    let sink = manager.identityPublisher.sink {
      if let path = $0.fingerprint?.standardizedPath { publishedPaths.append(path) }
    }
    defer { sink.cancel() }
    #expect(manager.applyFolderSelection(a, decision: .newDestination))
    try #require(await probe.entered.waitForEnter(count: 1))
    #expect(!manager.canExportNow)
    #expect(!manager.canImportNow)
    #expect(manager.applyFolderSelection(b, decision: .newDestination))
    #expect(manager.selectedFolderURL == b)
    #expect(manager.identity == .unavailable)
    #expect(!manager.canExportNow)
    probe.release()
    await manager.waitForValidation()
    #expect(manager.selectedFolderURL == b)
    #expect(manager.canExportNow)
    #expect(manager.identity.fingerprint?.standardizedPath == b.path)
    #expect(publishedPaths == [b.path])
    #expect(probe.calls.value == [true, true])
    #expect(opened.value.map(\.path).sorted() == closed.value.map(\.path).sorted())
  }

  @Test func clearFromAvailabilitySubscriberCannotRestoreObsoleteResult() async throws {
    let root = TestScratch.directory("ReentrantValidation")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let probe = Probe(heldPath: "never")
    let closed = LockedBox(0)
    let manager = ExportDestinationManager(
      skipRestore: true, userDefaults: TestScratch.defaults("ReentrantValidation"),
      bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
      validationScopeAcquirer: { _ in true },
      validationScopeReleaser: { _ in closed.mutate { $0 += 1 } }, validationProbe: probe)
    var cleared = false
    let sink = manager.isAvailablePublisher.sink { available in
      guard available, !cleared else { return }
      cleared = true
      manager.clearSelection()
    }
    defer { sink.cancel() }
    #expect(manager.applyFolderSelection(root, decision: .newDestination))
    await manager.waitForValidation()
    #expect(cleared)
    #expect(manager.selectedFolderURL == nil)
    #expect(!manager.isAvailable)
    #expect(!manager.isWritable)
    #expect(manager.identity == .unavailable)
    #expect(manager.status == .noSelection)
    #expect(closed.value == 1)
  }
}
