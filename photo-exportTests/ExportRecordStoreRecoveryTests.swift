import Foundation
import Testing

@testable import Photo_Export

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ExportRecordStoreRecoveryTests {

  private func makeTempDir() -> URL {
    let dir = TestScratch.directory("RecordRecovery")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func storeDir(base: URL, dest: String) -> URL {
    base.appendingPathComponent(dest, isDirectory: true)
  }

  private func logURL(base: URL, dest: String) -> URL {
    storeDir(base: base, dest: dest)
      .appendingPathComponent(ExportRecordStore.Constants.logFileName)
  }

  private func snapshotURL(base: URL, dest: String) -> URL {
    storeDir(base: base, dest: dest)
      .appendingPathComponent(ExportRecordStore.Constants.snapshotFileName)
  }

  private func makeRecord(
    id: String, year: Int = 2025, month: Int = 1, status: ExportStatus = .done
  ) -> ExportRecord {
    ExportRecord(
      id: id, year: year, month: month, relPath: "\(year)/\(String(format: "%02d", month))/",
      variants: [
        .original: ExportVariantRecord(
          filename: "\(id).JPG", status: status, exportDate: Date(), lastError: nil)
      ])
  }

  // MARK: - Snapshot + log overlay

  @Test func snapshotPlusLogOverlayProducesCorrectState() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "overlay-test"

    // Write a snapshot with 3 records
    let dir = storeDir(base: base, dest: dest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let snapshotRecords: [String: ExportRecord] = [
      "a": makeRecord(id: "a", year: 2025, month: 1),
      "b": makeRecord(id: "b", year: 2025, month: 2),
      "c": makeRecord(id: "c", year: 2025, month: 3),
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let snapshotData = try encoder.encode(snapshotRecords)
    try snapshotData.write(to: snapshotURL(base: base, dest: dest))

    // Write a log with 2 mutations: update "b" to failed, add "d"
    var updatedB = snapshotRecords["b"]!
    updatedB.variants[.original] = ExportVariantRecord(
      filename: "b.JPG", status: .failed, exportDate: Date(), lastError: "Disk error")
    let mutation1 = ExportRecordMutation.upsert(updatedB)
    let newD = makeRecord(id: "d", year: 2025, month: 4)
    let mutation2 = ExportRecordMutation.upsert(newD)

    let logFile = logURL(base: base, dest: dest)
    let m1Data = try encoder.encode(mutation1)
    let m2Data = try encoder.encode(mutation2)
    var logData = Data()
    logData.append(m1Data)
    logData.append(Data([0x0A]))
    logData.append(m2Data)
    logData.append(Data([0x0A]))
    try logData.write(to: logFile)

    // Load and verify
    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    #expect(store.recordsById.count == 4)
    #expect(store.recordsById["a"]?.variants[.original]?.status == .done)
    #expect(store.recordsById["b"]?.variants[.original]?.status == .failed)
    #expect(store.recordsById["b"]?.variants[.original]?.lastError == "Disk error")
    #expect(store.recordsById["c"]?.variants[.original]?.status == .done)
    #expect(store.recordsById["d"]?.variants[.original]?.status == .done)

    // Done counts should reflect the overlay
    #expect(store.recordCount(year: 2025, month: 1, variant: .original, status: .done) == 1)
    #expect(store.recordCount(year: 2025, month: 2, variant: .original, status: .done) == 0)
    #expect(store.recordCount(year: 2025, month: 3, variant: .original, status: .done) == 1)
    #expect(store.recordCount(year: 2025, month: 4, variant: .original, status: .done) == 1)
  }

  // MARK: - Corrupted snapshot falls back to log

  /// Phase 1.4 of the collections-export plan changes corruption behavior: a corrupt
  /// snapshot transitions the store to `.failed` and **does not** replay the log. The
  /// rationale is the deferred-rename rule (corrupt file stays on disk so Quit-and-relaunch
  /// reproduces `.failed`) and the no-silent-recovery property: if the snapshot was the
  /// authoritative state and it's unreadable, log-only replay could yield an inconsistent
  /// view; users get a Reset action in Phase 4 to consciously discard the corrupt snapshot.
  @Test func corruptedSnapshotTransitionsToFailedAndPreservesFile() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "corrupted-snap"

    let dir = storeDir(base: base, dest: dest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Write corrupted snapshot
    let snapURL = snapshotURL(base: base, dest: dest)
    try Data("this is not valid JSON".utf8).write(to: snapURL)

    // Write a valid log line; under the new behavior it is **not** replayed.
    let record = makeRecord(id: "from-log", year: 2025, month: 5)
    let mutation = ExportRecordMutation.upsert(record)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let mutData = try encoder.encode(mutation)
    var logData = Data()
    logData.append(mutData)
    logData.append(Data([0x0A]))
    try logData.write(to: logURL(base: base, dest: dest))

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    // Store transitions to `.failed`; in-memory state stays empty.
    #expect(store.state == .failed)
    #expect(store.recordsById.isEmpty)

    // Corrupt file is **left in place** (deferred-rename rule).
    #expect(FileManager.default.fileExists(atPath: snapURL.path))

    // resetToEmpty renames the corrupt file out of the way and writes a fresh empty
    // snapshot at the canonical path. After the call, both files exist on disk: the
    // forensic `.broken-<ISO8601>` (preserves the corrupt bytes for inspection) and the
    // new empty `export-records.json`.
    store.resetToEmpty()
    #expect(store.state == .ready)
    #expect(store.recordsById.isEmpty)
    let dirContents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let brokenFiles = dirContents.filter { $0.contains(".broken-") }
    #expect(brokenFiles.count == 1)
    // New empty snapshot at the canonical path.
    let newSnapshot = try Data(contentsOf: snapURL)
    let decoded = try JSONDecoder().decode([String: ExportRecord].self, from: newSnapshot)
    #expect(decoded.isEmpty)
  }

  // MARK: - Empty snapshot + populated log

  @Test func emptySnapshotWithPopulatedLogUsesLogOnly() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "no-snap"

    let dir = storeDir(base: base, dest: dest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // No snapshot file — only a log
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var logData = Data()
    for i in 1...5 {
      let record = makeRecord(id: "log-\(i)", year: 2025, month: i)
      let mutation = ExportRecordMutation.upsert(record)
      let mutData = try encoder.encode(mutation)
      logData.append(mutData)
      logData.append(Data([0x0A]))
    }
    try logData.write(to: logURL(base: base, dest: dest))

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    #expect(store.recordsById.count == 5)
    for i in 1...5 {
      #expect(store.recordsById["log-\(i)"]?.variants[.original]?.status == .done)
    }
  }

  // MARK: - Log with mixed valid/corrupted lines

  @Test func corruptedLogLinesAreSkipped() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "mixed-log"

    let dir = storeDir(base: base, dest: dest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let goodRecord = makeRecord(id: "good", year: 2025, month: 1)
    let goodMutation = ExportRecordMutation.upsert(goodRecord)
    let goodData = try encoder.encode(goodMutation)

    var logData = Data()
    logData.append(goodData)
    logData.append(Data([0x0A]))
    logData.append(Data("this is garbage\n".utf8))  // corrupted line
    let good2 = makeRecord(id: "good2", year: 2025, month: 2)
    let good2Data = try encoder.encode(ExportRecordMutation.upsert(good2))
    logData.append(good2Data)
    logData.append(Data([0x0A]))

    try logData.write(to: logURL(base: base, dest: dest))

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    // Both good records should be loaded, corrupted line skipped
    #expect(store.recordsById.count == 2)
    #expect(store.recordsById["good"] != nil)
    #expect(store.recordsById["good2"] != nil)
  }

  // MARK: - Compaction trigger

  @Test func compactionCreatesSnapshotFile() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "compact-test"

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    // Accumulate history, then request explicit idle maintenance.
    let threshold = ExportRecordStore.Constants.compactEveryNMutations
    for i in 1...threshold {
      store.markExported(
        assetId: "asset-\(i)", year: 2025, month: (i % 12) + 1,
        relPath: "2025/\(String(format: "%02d", (i % 12) + 1))/",
        filename: "IMG_\(i).JPG", exportedAt: Date())
    }

    try await store.checkpointHistory()
    let snapFile = snapshotURL(base: base, dest: dest)
    #expect(FileManager.default.fileExists(atPath: snapFile.path))

    // Verify the snapshot is valid JSON and contains the expected records
    let store2 = ExportRecordStore(baseDirectoryURL: base)
    store2.configure(for: dest)
    #expect(store2.recordsById.count == threshold)
  }

  @Test func compactionPreservesRecentMutation() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "compact-race"

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    let threshold = ExportRecordStore.Constants.compactEveryNMutations
    // Include the last mutation in the checkpoint before reopening.
    for i in 1...(threshold + 1) {
      store.markExported(
        assetId: "asset-\(i)", year: 2025, month: (i % 12) + 1,
        relPath: "2025/\(String(format: "%02d", (i % 12) + 1))/",
        filename: "IMG_\(i).JPG", exportedAt: Date())
    }

    try await store.checkpointHistory()

    let store2 = ExportRecordStore(baseDirectoryURL: base)
    store2.configure(for: dest)

    #expect(store2.recordsById.count == threshold + 1)
  }

  // MARK: - Delete mutation in log

  @Test func deleteMutationRemovesRecord() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "delete-test"

    let dir = storeDir(base: base, dest: dest)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    // Write upsert then delete
    let record = makeRecord(id: "to-delete", year: 2025, month: 1)
    let upsert = ExportRecordMutation.upsert(record)
    let delete = ExportRecordMutation.delete(id: "to-delete")

    var logData = Data()
    logData.append(try encoder.encode(upsert))
    logData.append(Data([0x0A]))
    logData.append(try encoder.encode(delete))
    logData.append(Data([0x0A]))
    try logData.write(to: logURL(base: base, dest: dest))

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: dest)

    #expect(store.recordsById["to-delete"] == nil)
    #expect(store.recordCount(year: 2025, month: 1, variant: .original, status: .done) == 0)
  }

  // MARK: - Persistence round-trip

  @Test func mutationsPersistedAndReloadable() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dest = "roundtrip"

    let store1 = ExportRecordStore(baseDirectoryURL: base)
    store1.configure(for: dest)

    store1.markExported(
      assetId: "rt-1", year: 2025, month: 3, relPath: "2025/03/",
      filename: "RT1.JPG", exportedAt: Date())
    store1.markFailed(assetId: "rt-2", error: "Something broke", at: Date())
    store1.drainSynchronously()

    // Create a fresh store and reload
    let store2 = ExportRecordStore(baseDirectoryURL: base)
    store2.configure(for: dest)

    #expect(store2.recordsById.count == 2)
    #expect(store2.recordsById["rt-1"]?.variants[.original]?.status == .done)
    #expect(store2.recordsById["rt-2"]?.variants[.original]?.status == .failed)
    #expect(store2.recordsById["rt-2"]?.variants[.original]?.lastError == "Something broke")
  }
}
