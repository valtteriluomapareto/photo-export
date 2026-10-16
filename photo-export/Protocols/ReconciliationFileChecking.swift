/// Reconciliation's detached file probe. Kept async so tests can suspend a probe
/// without blocking the cooperative executor. Implementations preserve the existing
/// fileExists && !isDirectory semantics, including symbolic links.
protocol ReconciliationFileChecking: Sendable {
  func isFile(atPath path: String) async -> Bool
}
