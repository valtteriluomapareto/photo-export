import Combine
import Foundation
import Testing

@testable import Photo_Export

/// Phase 0b: `DestinationSafetyMonitor` decides whether the current
/// destination needs a user-confirmation step before AutoSync can run
/// against it. Rule: flag = `hasUserFiles` AND `record stores empty` AND
/// `not previously confirmed`.
@MainActor
struct DestinationSafetyMonitorTests {

  // MARK: - Harness

  private struct Harness {
    let monitor: DestinationSafetyMonitor
    let fingerprintSubject: CurrentValueSubject<DestinationFingerprint?, Never>
    let recordStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let confirmationStore: InMemoryDestinationSafetyConfirmationStore
    let storeRoot: URL

    func cleanup() {
      try? FileManager.default.removeItem(at: storeRoot)
    }
  }

  private func makeHarness(scanResult: Bool = false) -> Harness {
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SafetyMonitor-\(UUID().uuidString)", isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let confirmationStore = InMemoryDestinationSafetyConfirmationStore()
    let fingerprintSubject = CurrentValueSubject<DestinationFingerprint?, Never>(nil)
    let scanResultRef = ScanResultRef(value: scanResult)
    let monitor = DestinationSafetyMonitor(
      fingerprintPublisher: fingerprintSubject.eraseToAnyPublisher(),
      exportRecordStore: recordStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: confirmationStore,
      scanDirectory: { @MainActor in scanResultRef.value }
    )
    return Harness(
      monitor: monitor,
      fingerprintSubject: fingerprintSubject,
      recordStore: recordStore,
      collectionStore: collectionStore,
      confirmationStore: confirmationStore,
      storeRoot: storeRoot
    )
  }

  @MainActor
  private final class ScanResultRef {
    var value: Bool
    init(value: Bool) { self.value = value }
  }

  private func fingerprint(id: String) -> DestinationFingerprint {
    .makeHigh(
      volumeUUIDString: "uuid-\(id)",
      volumeRootPath: nil,
      relativePathFromVolumeRoot: "/\(id)",
      standardizedPath: "/Volumes/\(id)"
    )
  }

  /// Yield enough times for the async-scan `Task` inside `evaluate(for:)`
  /// to schedule, run the closure, and write back to @Published.
  private func settleAsyncScan() async {
    for _ in 0..<3 { await Task.yield() }
  }

  // MARK: - Tests

  @Test func nilFingerprintLeavesFlagClear() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }

    harness.monitor.attach()
    harness.fingerprintSubject.send(nil)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func alreadyConfirmedDestinationDoesNotFlag() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-A")
    try? harness.confirmationStore.confirm(destinationId: fp.id)

    harness.monitor.attach()
    harness.fingerprintSubject.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func emptyRecordsAndEmptyDirectoryDoesNotFlag() async {
    let harness = makeHarness(scanResult: false)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-C")

    harness.monitor.attach()
    harness.fingerprintSubject.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func emptyRecordsAndNonEmptyDirectoryFlags() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-D")

    harness.monitor.attach()
    harness.fingerprintSubject.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == true)
  }

  /// Issue #129 recovery backbone: rebuilding records from the destination is
  /// what resolves the "files but no records" prompt. This pins the invariant
  /// the rebuild relies on — once the record store is non-empty, the monitor
  /// reports safe even though the directory still holds user files (the scan is
  /// short-circuited before it runs).
  @Test func recordsPresentDoesNotFlagEvenWithFiles() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-rebuilt")

    // Simulate the post-rebuild world: the import has repopulated the store.
    harness.recordStore.configure(for: fp.id)
    harness.recordStore.markVariantExported(
      assetId: "asset-1", variant: .original, year: 2025, month: 1,
      relPath: "2025/01/", filename: "IMG_0001.JPG", exportedAt: Date())
    harness.recordStore.flushForTesting()

    harness.monitor.attach()
    harness.fingerprintSubject.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func confirmingCurrentDestinationClearsTheFlag() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-E")

    harness.monitor.attach()
    harness.fingerprintSubject.send(fp)
    await settleAsyncScan()
    #expect(harness.monitor.needsSafetyConfirmation == true)

    harness.monitor.confirmCurrentDestination()

    #expect(harness.monitor.needsSafetyConfirmation == false)
    #expect(harness.confirmationStore.isConfirmed(destinationId: fp.id))
  }

  @Test func staleScanDoesNotOverwriteNewerEvaluation() async {
    // Simulate a slow scan whose result lands after the destination has
    // changed. The generation guard inside `evaluate` should discard the
    // stale result.
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SafetyMonitor-stale-\(UUID().uuidString)", isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let confirmationStore = InMemoryDestinationSafetyConfirmationStore()
    let fingerprintSubject = CurrentValueSubject<DestinationFingerprint?, Never>(nil)
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    // Track which fingerprint evaluation each scan call corresponds to.
    // First call: long-suspended; second call: immediate.
    let scanCallsRef = ScanCallsRef()
    let monitor = DestinationSafetyMonitor(
      fingerprintPublisher: fingerprintSubject.eraseToAnyPublisher(),
      exportRecordStore: recordStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: confirmationStore,
      scanDirectory: { @MainActor in
        scanCallsRef.callCount += 1
        let myCall = scanCallsRef.callCount
        if myCall == 1 {
          // Suspend long enough for the second scan to land first.
          await Task.yield()
          await Task.yield()
          await Task.yield()
          return true  // would flag, but stale
        } else {
          return false  // wins
        }
      }
    )

    monitor.attach()
    let fp1 = fingerprint(id: "old")
    let fp2 = fingerprint(id: "new")
    fingerprintSubject.send(fp1)
    fingerprintSubject.send(fp2)
    // Settle everything.
    for _ in 0..<10 { await Task.yield() }

    // Final state reflects fp2 (empty dir → no flag), not fp1.
    #expect(monitor.needsSafetyConfirmation == false)
  }

  @MainActor
  private final class ScanCallsRef {
    var callCount: Int = 0
  }
}
