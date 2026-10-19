/// Runs `body`, then awaits `cleanup`, also when `body` throws.
///
/// A `defer` cannot await, so a teardown started from one as a `Task` may still be running
/// after the test has ended, while later tests run. This finishes `cleanup` itself before the
/// test returns. A cleanup that releases a gate should also await the work the gate held
/// (with `finished(_:)`, so a test's time limit still unwinds it) before removing the folders
/// that work writes to.
func withCleanup(
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws -> Void,
  cleanup: () async -> Void
) async rethrows {
  do {
    try await body()
  } catch {
    await cleanup()
    throw error
  }
  await cleanup()
}
