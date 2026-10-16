import Foundation

struct AutoSyncMetadataCorruption: Error, LocalizedError {
  let url: URL
  var errorDescription: String? { "Auto Export metadata is invalid at \(url.path)." }
}

/// Shared read/preserve/replace policy for dirty and retry JSON only.
struct AutoSyncJSONFile<Value: Codable> {
  let url: URL
  let fileManager: FileManager
  let io: any AutoSyncMetadataFileIO

  func load() throws -> Value? {
    guard let data = try io.readIfPresent(at: url) else { return nil }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      throw AutoSyncMetadataCorruption(url: url)
    }
  }

  func save(_ value: Value) throws {
    // Preflight even direct saves: neither inaccessible nor corrupt history may
    // be silently overwritten. Copy captured bytes; leave the source until commit.
    if let original = try io.readIfPresent(at: url),
      (try? JSONDecoder().decode(Value.self, from: original)) == nil
    {
      let sibling = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
      try io.preserve(original, at: sibling)
    }
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try io.writeAtomically(encoder.encode(value), to: url)
  }
}
