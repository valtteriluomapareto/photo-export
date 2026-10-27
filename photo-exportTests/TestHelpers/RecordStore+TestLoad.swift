import Foundation

@testable import Photo_Export

extension ExportRecordStore {
  func configureAndWait(for destinationId: String?) async {
    beginConfigure(for: destinationId)
    await waitUntilSettled()
  }
}

extension CollectionExportRecordStore {
  func configureAndWait(for destinationId: String?) async {
    beginConfigure(for: destinationId)
    await waitUntilSettled()
  }
}
