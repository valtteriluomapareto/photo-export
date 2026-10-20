import Foundation

/// Missing child targets return false; verification failures throw. Valid file links
/// are followed. Async seams let tests suspend probes without blocking an executor.
protocol ReconciliationFileChecking: Sendable {
  func isFile(atPath path: String) async throws -> Bool
  func validateRoot(atPath path: String) async throws
}

extension ReconciliationFileChecking {
  /// Whether any of `paths` is a regular file. Stops at the first one found; checks `root` before
  /// answering no, so an unreadable folder throws instead of reading as empty.
  func containsAnyFile(_ paths: [String], root: URL) async throws -> Bool {
    for path in paths {
      try Task.checkCancellation()
      if try await isFile(atPath: path) { return true }
    }
    try Task.checkCancellation()
    try await validateRoot(atPath: root.path)
    return false
  }
}
