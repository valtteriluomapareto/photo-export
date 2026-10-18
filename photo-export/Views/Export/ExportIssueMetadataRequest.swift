import Foundation

/// View-local lookup identity; derived from records, never from enriched rows.
struct ExportIssueMetadataRequest: Equatable, Sendable {
  let destinationId: String?
  let libraryRevision: Int
  let assetIds: [String]
  let filenameAssetIds: Set<String>

  init(destinationId: String?, libraryRevision: Int, rows: [ExportIssue]) {
    self.destinationId = destinationId
    self.libraryRevision = libraryRevision
    assetIds = Set(rows.map(\.assetId)).sorted()
    filenameAssetIds = Set(
      rows.filter { ExportIssue.nonemptyFilename($0.filename) == nil }.map(\.assetId))
  }

  /// Nil discards a cancelled request, including any partially read batch.
  @MainActor
  func load(using service: any PhotoLibraryService) async -> [String: ExportIssue.AssetMetadata]? {
    var result: [String: ExportIssue.AssetMetadata] = [:]
    for (index, id) in assetIds.enumerated() {
      if index.isMultiple(of: 32) { await Task.yield() }
      guard !Task.isCancelled else { return nil }
      let date = service.fetchAssetDescriptor(for: id)?.creationDate
      guard !Task.isCancelled else { return nil }
      let filename =
        filenameAssetIds.contains(id) ? service.assetDetails(for: id)?.originalFilename : nil
      result[id] = ExportIssue.AssetMetadata(creationDate: date, originalFilename: filename)
    }
    await Task.yield()
    return Task.isCancelled ? nil : result
  }
}
