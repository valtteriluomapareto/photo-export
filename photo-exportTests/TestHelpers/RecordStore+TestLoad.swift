import Foundation

@testable import Photo_Export

extension ExportRecordStore {
  func configureAndWait(for destinationId: String?) async {
    beginConfigure(for: destinationId)
    await waitUntilSettled()
  }

  func checkpointHistory() async throws {
    await requestHistoryCheckpoint(force: true)?.value
    try await flush()
  }
}

extension CollectionExportRecordStore {
  func configureAndWait(for destinationId: String?) async {
    beginConfigure(for: destinationId)
    await waitUntilSettled()
  }

  func checkpointHistory() async throws {
    await requestHistoryCheckpoint(force: true)?.value
    try await flush()
  }
}
