import Foundation
import Testing

@testable import Photo_Export

/// Exercises decode-time migration from the legacy flat `ExportRecord` schema into the new
/// per-variant schema.
@MainActor
struct ExportRecordLegacyMigrationTests {
  private func makeTempDir() -> URL {
    TestScratch.directory("LegacyMig")
  }

  private func writeLegacySnapshot(_ json: String, at dir: URL, dest: String) throws {
    let storeDir = dir.appendingPathComponent(dest, isDirectory: true)
    try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    try Data(json.utf8).write(
      to: storeDir.appendingPathComponent(ExportRecordStore.Constants.snapshotFileName))
  }

  // MARK: - Legacy .done → .original done

  @Test func legacyDoneDecodesAsOriginalDone() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let json = """
      {
        "legacy-done": {
          "id": "legacy-done",
          "year": 2024,
          "month": 4,
          "relPath": "2024/04/",
          "filename": "IMG_0001.JPG",
          "status": "done",
          "exportDate": "2024-04-10T10:00:00Z",
          "lastError": null
        }
      }
      """
    try writeLegacySnapshot(json, at: base, dest: "legacy")

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: "legacy")

    let record = store.exportInfo(assetId: "legacy-done")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001.JPG")
    #expect(record?.variants[.edited] == nil)
    #expect(store.isExported(assetId: "legacy-done"))
  }

  // MARK: - Legacy .failed → .original failed

  @Test func legacyFailedDecodesAsOriginalFailed() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let json = """
      {
        "legacy-fail": {
          "id": "legacy-fail",
          "year": 2024,
          "month": 5,
          "relPath": "2024/05/",
          "filename": "BAD.JPG",
          "status": "failed",
          "exportDate": "2024-05-10T10:00:00Z",
          "lastError": "Out of disk space"
        }
      }
      """
    try writeLegacySnapshot(json, at: base, dest: "legacy")

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: "legacy")

    let record = store.exportInfo(assetId: "legacy-fail")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(record?.variants[.original]?.lastError == "Out of disk space")
  }

  // MARK: - Legacy .inProgress → .failed with interrupted message

  @Test func legacyInProgressRecoversToFailed() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let json = """
      {
        "legacy-inprog": {
          "id": "legacy-inprog",
          "year": 2024,
          "month": 6,
          "relPath": "2024/06/",
          "filename": "X.JPG",
          "status": "inProgress",
          "exportDate": null,
          "lastError": null
        }
      }
      """
    try writeLegacySnapshot(json, at: base, dest: "legacy")

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: "legacy")

    let record = store.exportInfo(assetId: "legacy-inprog")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(
      record?.variants[.original]?.lastError == ExportVariantRecovery.interruptedMessage)
  }

  // MARK: - New schema .inProgress also converted on load

  @Test func newSchemaInProgressRecoversOnLoad() throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let json = """
      {
        "new-inprog": {
          "id": "new-inprog",
          "year": 2024,
          "month": 7,
          "relPath": "2024/07/",
          "variants": {
            "original": {
              "filename": "IMG_0001.JPG",
              "status": "inProgress",
              "exportDate": null,
              "lastError": null
            },
            "edited": {
              "filename": "IMG_0001_edited.JPG",
              "status": "done",
              "exportDate": "2024-07-10T10:00:00Z",
              "lastError": null
            }
          }
        }
      }
      """
    try writeLegacySnapshot(json, at: base, dest: "modern")

    let store = ExportRecordStore(baseDirectoryURL: base)
    store.configure(for: "modern")

    let record = store.exportInfo(assetId: "new-inprog")
    #expect(record?.variants[.original]?.status == .failed)
    #expect(
      record?.variants[.original]?.lastError == ExportVariantRecovery.interruptedMessage)
    #expect(record?.variants[.edited]?.status == .done)
  }

  // MARK: - New-schema record encodes without legacy fields

  @Test func newRecordsEncodeOnlyVariantSchema() throws {
    var record = ExportRecord(id: "x", year: 2025, month: 1, relPath: "2025/01/")
    record.variants[.original] = ExportVariantRecord(
      filename: "X.JPG", status: .done, exportDate: Date(), lastError: nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)
    let topLevel = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])

    // Record-level keys must not include legacy flat fields — those belong inside the nested
    // per-variant record.
    let keys = Set(topLevel.keys)
    #expect(keys == ["id", "year", "month", "relPath", "variants"])
    #expect(topLevel["variants"] is [String: Any])
  }
}
