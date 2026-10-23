import Foundation
import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(2)))
struct DestinationIOTests {
  private final class Gate: @unchecked Sendable {
    let entered = AsyncCheckpoint()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() {
      Task { await entered.enter() }
      semaphore.wait()
    }
    func release() {
      semaphore.signal()
      Task { await entered.releaseAll() }
    }
  }

  private final class Capture: @unchecked Sendable {}
  private final class WeakCapture: @unchecked Sendable {
    weak var value: Capture?
  }

  private func consumeCapture(on io: DestinationIO, weak: WeakCapture) async {
    let capture = Capture()
    weak.value = capture
    await io.run { [capture] in withExtendedLifetime(capture) {} }
  }

  @Test func completedLeafReleasesPreparationCaptureBeforeReturning() async {
    let weak = WeakCapture()
    await consumeCapture(on: DestinationIO(), weak: weak)
    #expect(weak.value == nil)
  }

  @Test func serialLeavesFinishInOrderWhileOtherDestinationProgresses() async throws {
    let first = RecordingDestinationIO()
    let other = DestinationIO()
    let gate = Gate()
    let order = LockedBox<[Int]>([])
    let held = Task {
      await first.run {
        order.mutate { $0.append(1) }
        gate.hold()
        order.mutate { $0.append(2) }
      }
    }
    defer { gate.release() }
    try #require(await gate.entered.waitForEnter(count: 1))
    let pending = Task { await first.run { order.mutate { $0.append(3) } } }
    try #require(await eventually("second leaf admitted") { first.submissions.value == 2 })
    let independent = Task { await other.run { pthread_main_np() == 0 } }
    try #require(await finished(independent))
    #expect(await independent.value)
    #expect(order.value == [1])
    gate.release()
    await held.value
    await pending.value
    #expect(order.value == [1, 2, 3])
    #expect(first.workerChecks.value.allSatisfy { $0 })
  }

  @Test(arguments: [false, true])
  func cancellationWaitsForPhysicalLeafCompletion(queued: Bool) async throws {
    let io = RecordingDestinationIO()
    let gate = Gate()
    let physical = LockedBox(false)
    let returned = LockedBox(false)
    defer { gate.release() }
    let predecessor: Task<Void, Never>?
    if queued {
      predecessor = Task { await io.run { gate.hold() } }
      try #require(await gate.entered.waitForEnter(count: 1))
    } else {
      predecessor = nil
    }
    let task = Task {
      await io.run {
        if !queued { gate.hold() }
        physical.mutate { $0 = true }
      }
      returned.mutate { $0 = true }
    }
    if !queued { try #require(await gate.entered.waitForEnter(count: 1)) }
    try #require(await eventually("leaf admitted") { io.submissions.value == (queued ? 2 : 1) })
    task.cancel()
    let independent = Task { await DestinationIO().run {} }
    try #require(await finished(independent))
    #expect(!physical.value)
    #expect(!returned.value)
    gate.release()
    await predecessor?.value
    await task.value
    try await io.run { () throws in }
    #expect(physical.value)
    #expect(returned.value)
  }

  @Test(arguments: [false, true])
  func realAndFakeReadHandlesRetainContext(recordingFake: Bool) async throws {
    let root = TestScratch.directory("DestinationReadContext")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("file")
    try Data([1, 2, 3, 4]).write(to: url)
    let io = RecordingDestinationIO()
    let files: any FileSystemService = recordingFake ? FakeFileSystem() : FileIOService()
    let handle = try await io.run {
      try files.openForReading(at: url, bypassingCache: false, destinationIO: io)
    }
    let before = io.submissions.value
    #expect(try await handle.read(offset: 1, length: 2) == Data([2, 3]))
    #expect(io.submissions.value == before + 1)
    await io.run { handle.close() }
    #expect(io.workerChecks.value.allSatisfy { $0 })
    #expect(!io.workerChecks.value.isEmpty)
  }

  @Test func plannerUsesContextForProbesOpensReadsAndCloses() async throws {
    let root = TestScratch.directory("PlannerDestinationContext")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stage = root.appendingPathComponent("stage")
    let candidate = root.appendingPathComponent("FILE.JPG")
    try Data([1, 2, 3, 4]).write(to: stage)
    try Data([1, 2, 3, 4]).write(to: candidate)
    let io = RecordingDestinationIO()
    let files = FakeFileSystem()
    let plan = try await FinalNamePlanner(fileSystem: files).plan(
      slot: .init(directory: root, filename: "FILE.JPG", policy: .suffix(base: "FILE", ext: "JPG")),
      stagedURL: stage, destinationIO: io, isClaimed: { _ in false }, shouldStop: { false })
    guard case .adopt = plan else {
      Issue.record("Identical file should be adopted")
      return
    }
    #expect(files.readOpens.count == 2)
    #expect(files.readCloses.count == 2)
    #expect(
      files.calls.filter {
        ["itemIdentity", "openForReading", "storedName"].contains($0.operation)
      }
      .allSatisfy { !$0.onMainThread })
    #expect(files.calls.contains { !$0.onMainThread })
    // One stage probe, candidate probe, open pair, two reads, close pair, stored name.
    #expect(io.submissions.value == 7)
    #expect(io.workerChecks.value.allSatisfy { $0 })
  }
  @Test(arguments: [false, true])
  func cancelledCompareClosesHandlesAfterPhysicalWork(holdClose: Bool) async throws {
    let root = TestScratch.directory("CancelledDestinationRead")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stage = root.appendingPathComponent("stage")
    let candidate = root.appendingPathComponent("FILE.JPG")
    try Data([1, 2, 3, 4]).write(to: stage)
    try Data([1, 2, 3, 4]).write(to: candidate)
    let gate = Gate()
    // Open pair, eight one-byte reads, then one physical close of the pair.
    let io = RecordingDestinationIO(beforeLeaf: { number in
      if number == (holdClose ? 10 : 2) { gate.hold() }
    })
    let files = FakeFileSystem()
    let returned = LockedBox(false)
    let task = Task {
      defer { returned.mutate { $0 = true } }
      return try await FinalNamePlanner(fileSystem: files, edgeChunkSize: 1, middleChunkSize: 1)
        .contentsEqual(stage, candidate, size: 4, destinationIO: io, shouldStop: { false })
    }
    defer { gate.release() }
    try #require(await gate.entered.waitForEnter(count: 1))
    task.cancel()
    let independent = Task { await DestinationIO().run {} }
    try #require(await finished(independent))
    #expect(!returned.value)
    #expect(files.readCloses.isEmpty)
    gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    await io.run {}
    #expect(files.readCloses.count == 2)
    #expect(Set(files.readCloses) == [stage, candidate])
    #expect(io.workerChecks.value.allSatisfy { $0 })
  }

  @Test func failedSecondOpenClosesTheFirstHandleOnItsContext() async throws {
    let root = TestScratch.directory("FailedDestinationOpen")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let stage = root.appendingPathComponent("stage")
    let candidate = root.appendingPathComponent("FILE.JPG")
    try Data([1, 2, 3, 4]).write(to: stage)
    try Data([1, 2, 3, 4]).write(to: candidate)
    let files = FakeFileSystem()
    files.identityOverride = { url, identity in
      if url == candidate { try? FileManager.default.removeItem(at: url) }
      return identity
    }
    let io = RecordingDestinationIO()
    let result = try await FinalNamePlanner(fileSystem: files).plan(
      slot: .init(directory: root, filename: "FILE.JPG", policy: .suffix(base: "FILE", ext: "JPG")),
      stagedURL: stage, destinationIO: io, isClaimed: { _ in false }, shouldStop: { false })
    #expect(result == .move(root.appendingPathComponent("FILE (1).JPG")))
    #expect(files.readOpens.count == 2)
    #expect(files.readCloses == [stage])
    #expect(io.workerChecks.value.allSatisfy { $0 })
  }

  private final class QueueIdentity: @unchecked Sendable {
    private let key = DispatchSpecificKey<String>()
    func executor(_ id: String) -> DestinationIO {
      let queue = DispatchQueue(label: "test.destination.\(id)", qos: .utility)
      queue.setSpecific(key: key, value: id)
      return DestinationIO(queue: queue)
    }
    var current: String? { DispatchQueue.getSpecific(key: key) }
  }

  @MainActor
  @Test func admittedOldCommitAndCleanupKeepTheirDestinationContext() async throws {
    let identity = QueueIdentity()
    let h = ExportManagerHarness(
      label: "CapturedDestinationIO", destinationId: "A",
      destinationIOFactory: { identity.executor($0 ?? "none") })
    let gate = Gate()
    defer {
      gate.release()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    let timestamps = LockedBox<[String]>([])
    let cleanupContexts = LockedBox<[String]>([])
    h.fileSystem.beforeMoveHook = { _, destination in
      if destination.lastPathComponent == "A.JPG" { gate.hold() }
    }
    h.fileSystem.afterTimestampsHook = { _ in
      timestamps.mutate { $0.append(identity.current ?? "missing") }
    }
    h.fileSystem.existsHook = { path in
      if path.contains(".photo-export-") {
        cleanupContexts.mutate { $0.append(identity.current ?? "missing") }
      }
    }
    func admit(_ id: String) {
      let asset = TestAssetFactory.makeAsset(
        id: id,
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)))
      h.photoLib.assetsByYearMonth["2025-4"] = [asset]
      h.photoLib.resourcesByAssetId[id] = [
        .init(type: .photo, originalFilename: "\(id).JPG", fileSize: 12)
      ]
      h.manager.startExportMonth(year: 2025, month: 4)
    }
    admit("A")
    try #require(await gate.entered.waitForEnter(count: 1))
    h.manager.cancelAndClear()
    h.store.beginConfigure(for: "B")
    h.collectionStore.beginConfigure(for: "B")
    await h.store.waitUntilSettled()
    await h.collectionStore.waitUntilSettled()
    admit("B")
    #expect(h.dest.endScopedAccessCount == 0)
    gate.release()
    await h.manager.waitForQueueDrained()
    try #require(
      await eventually("both captured scopes released") { h.dest.endScopedAccessCount == 2 })
    #expect(timestamps.value == ["A", "B"])
    #expect(cleanupContexts.value.contains("A"))
    #expect(cleanupContexts.value.contains("B"))
    #expect(!cleanupContexts.value.contains("missing"))
  }

  @MainActor
  @Test func logicalDestinationRoundTripReusesItsCapturedContext() async throws {
    var created: [String?] = []
    var contexts: [RecordingDestinationIO] = []
    let h = ExportManagerHarness(
      label: "DestinationContexts",
      destinationIOFactory: { id in
        created.append(id)
        let io = RecordingDestinationIO()
        contexts.append(io)
        return io
      })
    defer {
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
    for (index, id) in ["A", "B", "A"].enumerated() {
      h.store.configure(for: id)
      h.collectionStore.configure(for: id)
      let asset = TestAssetFactory.makeAsset(
        id: "asset-\(index)",
        creationDate: Calendar.current.date(from: DateComponents(year: 2025, month: 4, day: 15)))
      h.photoLib.assetsByYearMonth["2025-4"] = [asset]
      h.photoLib.resourcesByAssetId[asset.id] = [
        .init(type: .photo, originalFilename: "FILE\(index).JPG", fileSize: 12)
      ]
      h.manager.startExportMonth(year: 2025, month: 4)
      await h.manager.waitForQueueDrained()
      #expect(h.store.exportInfo(assetId: asset.id)?.variants[.original]?.status == .done)
      h.dest.canExportNow = false
      h.dest.canExportNow = true
    }
    #expect(created == ["A", "B"])
    #expect(contexts.allSatisfy { $0.submissions.value > 0 })
    #expect(contexts.flatMap { $0.workerChecks.value }.allSatisfy { $0 })
  }

}
