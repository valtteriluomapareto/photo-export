import Foundation

@main
struct GenerateLegacy {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let store = ExportRecordStore(baseDirectoryURL: root)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    store.configure(for: "A")
    store.markInProgress(
      assetId: "shared", year: 2024, month: 4, relPath: "2024/04/", filename: "OLD.JPG")
    store.markFailed(assetId: "shared", error: "Legacy retry", at: date)
    store.markExported(
      assetId: "deleted", year: 2024, month: 4, relPath: "2024/04/", filename: "DELETE.JPG",
      exportedAt: date)
    store.markInProgress(
      assetId: "interrupted", year: 2024, month: 4, relPath: "2024/04/", filename: "PARTIAL.JPG")
    // Exercise the released threshold and snapshot writer without changing source.
    for _ in 0..<1000 {
      store.markExported(
        assetId: "snapshot-only", year: 2024, month: 4, relPath: "2024/04/", filename: "SNAP.JPG",
        exportedAt: date)
    }
    store.flushForTesting()
    store.markExported(
      assetId: "shared", year: 2024, month: 4, relPath: "2024/04/", filename: "REPLAY.JPG",
      exportedAt: date)
    store.remove(assetId: "deleted")
    store.markExported(
      assetId: "log-only", year: 2024, month: 4, relPath: "2024/04/", filename: "LOG.JPG",
      exportedAt: date)
    store.markInProgress(
      assetId: "raw-failure", year: 2024, month: 4, relPath: "2024/04/", filename: "FAIL.JPG")
    store.markFailed(assetId: "raw-failure", error: "Legacy disk error", at: date)
    store.flushForTesting()
    store.configure(for: "B")
    store.markInProgress(
      assetId: "shared", year: 2030, month: 1, relPath: "2030/01/", filename: "OTHER.JPG")
    store.markFailed(assetId: "shared", error: "Other destination", at: date)
    store.flushForTesting()
  }
}
