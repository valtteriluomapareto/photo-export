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

extension JSONLRecordFile {
  func load() async -> LoadResult {
    let inputs = readInputs
    let result = await runDetached(priority: .userInitiated) { inputs.decode(inputs.read()) }
    adoptLogSeparator(result.needsLogSeparator)
    adoptReplaySize(operationCount: result.ops.count, bytes: result.replayBytes)
    return result
  }
}
