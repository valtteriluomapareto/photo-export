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
    let identitySubject: CurrentValueSubject<DestinationIdentity, Never>
    let recordStore: ExportRecordStore
    let collectionStore: CollectionExportRecordStore
    let confirmationStore: InMemoryDestinationSafetyConfirmationStore
    let storeRoot: URL

    func cleanup() {
      try? FileManager.default.removeItem(at: storeRoot)
    }

    /// Sends a no-drift identity whose stable id tracks the fingerprint id.
    func send(_ fingerprint: DestinationFingerprint) {
      identitySubject.send(
        DestinationIdentity(stableId: fingerprint.id, fingerprint: fingerprint))
    }
  }

  private func makeHarness(scanResult: Bool = false) -> Harness {
    let storeRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("SafetyMonitor-\(UUID().uuidString)", isDirectory: true)
    let recordStore = ExportRecordStore(baseDirectoryURL: storeRoot)
    let collectionStore = CollectionExportRecordStore(baseDirectoryURL: storeRoot)
    let confirmationStore = InMemoryDestinationSafetyConfirmationStore()
    let identitySubject = CurrentValueSubject<DestinationIdentity, Never>(.unavailable)
    let scanResultRef = ScanResultRef(value: scanResult)
    let monitor = DestinationSafetyMonitor(
      identityPublisher: identitySubject.eraseToAnyPublisher(),
      exportRecordStore: recordStore,
      collectionExportRecordStore: collectionStore,
      confirmationStore: confirmationStore,
      scanDirectory: { @MainActor in scanResultRef.value }
    )
    return Harness(
      monitor: monitor,
      identitySubject: identitySubject,
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
    harness.identitySubject.send(.unavailable)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func alreadyConfirmedDestinationDoesNotFlag() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-A")
    try? harness.confirmationStore.confirm(destinationId: fp.id)

    harness.monitor.attach()
    harness.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func emptyRecordsAndEmptyDirectoryDoesNotFlag() async {
    let harness = makeHarness(scanResult: false)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-C")

    harness.monitor.attach()
    harness.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func emptyRecordsAndNonEmptyDirectoryFlags() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-D")

    harness.monitor.attach()
    harness.send(fp)
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
    harness.send(fp)
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  @Test func confirmingCurrentDestinationClearsTheFlag() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let fp = fingerprint(id: "dest-E")

    harness.monitor.attach()
    harness.send(fp)
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
    let identitySubject = CurrentValueSubject<DestinationIdentity, Never>(.unavailable)
    defer { try? FileManager.default.removeItem(at: storeRoot) }

    // Track which fingerprint evaluation each scan call corresponds to.
    // First call: long-suspended; second call: immediate.
    let scanCallsRef = ScanCallsRef()
    let monitor = DestinationSafetyMonitor(
      identityPublisher: identitySubject.eraseToAnyPublisher(),
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
    identitySubject.send(DestinationIdentity(stableId: fp1.id, fingerprint: fp1))
    identitySubject.send(DestinationIdentity(stableId: fp2.id, fingerprint: fp2))
    // Settle everything.
    for _ in 0..<10 { await Task.yield() }

    // Final state reflects fp2 (empty dir → no flag), not fp1.
    #expect(monitor.needsSafetyConfirmation == false)
  }

  // MARK: - Stable-id keying (#127)

  /// The confirmation must be keyed on the **stable id**, not `fingerprint?.id`. Here the
  /// stable id deliberately differs from the fingerprint id: a destination already confirmed
  /// under the stable id stays safe even though the fingerprint id is unconfirmed. If the
  /// monitor still keyed on `fingerprint?.id`, the unconfirmed fingerprint id plus files
  /// present would (wrongly) flag.
  @Test func evaluationKeysOnStableIdNotFingerprintId() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let stableId = "stable-S"
    let fp = fingerprint(id: "mountA")  // fp.id != stableId
    #expect(fp.id != stableId)
    try? harness.confirmationStore.confirm(destinationId: stableId)

    harness.monitor.attach()
    harness.identitySubject.send(DestinationIdentity(stableId: stableId, fingerprint: fp))
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  /// `confirmCurrentDestination()` persists under the stable id, and that confirmation survives
  /// a network-share remount that drifts the fingerprint — no re-prompt on reconnect.
  @Test func confirmationPersistsAcrossRemountDrift() async {
    let harness = makeHarness(scanResult: true)
    defer { harness.cleanup() }
    let stableId = "stable-S"
    let fpMountA = fingerprint(id: "mountA")
    let fpMountB = fingerprint(id: "mountB")  // drifted fingerprint, same destination

    harness.monitor.attach()
    harness.identitySubject.send(
      DestinationIdentity(stableId: stableId, fingerprint: fpMountA))
    await settleAsyncScan()
    #expect(harness.monitor.needsSafetyConfirmation == true)

    harness.monitor.confirmCurrentDestination()
    #expect(harness.confirmationStore.isConfirmed(destinationId: stableId))
    #expect(harness.monitor.needsSafetyConfirmation == false)

    // Remount under a drifted fingerprint but the same stable id — must not re-prompt.
    harness.identitySubject.send(
      DestinationIdentity(stableId: stableId, fingerprint: fpMountB))
    await settleAsyncScan()
    #expect(harness.monitor.needsSafetyConfirmation == false)
  }

  /// Residual tail (#127 migration / #131 recovery): an upgrader whose path id already drifted
  /// gets a *fresh* stable id with an empty record store. With files present and no prior
  /// confirmation, the monitor flags for recovery (rebuild-from-disk) rather than the app
  /// silently re-exporting. The fresh stable id deliberately differs from the fingerprint id.
  @Test func freshlySeededIdWithFilesButNoRecordsFlagsForRecovery() async {
    let harness = makeHarness(scanResult: true)  // files present on disk
    defer { harness.cleanup() }
    let fp = fingerprint(id: "drifted-mount")
    let freshStableId = "fresh-seed-id"
    #expect(fp.id != freshStableId)

    harness.monitor.attach()
    harness.identitySubject.send(
      DestinationIdentity(stableId: freshStableId, fingerprint: fp))
    await settleAsyncScan()

    #expect(harness.monitor.needsSafetyConfirmation == true)
  }

  @MainActor
  private final class ScanCallsRef {
    var callCount: Int = 0
  }
}
