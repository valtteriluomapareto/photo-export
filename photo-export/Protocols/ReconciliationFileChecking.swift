/// Missing child targets return false; verification failures throw. Valid file links
/// are followed. Async seams let tests suspend probes without blocking an executor.
protocol ReconciliationFileChecking: Sendable {
  func isFile(atPath path: String) async throws -> Bool
  func validateRoot(atPath path: String) async throws
}
