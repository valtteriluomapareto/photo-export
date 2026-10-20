import Foundation

/// Runtime probe used by destination-manager tests that materialise a real
/// folder under `TestScratch` (in the temporary directory, inside the app's
/// sandbox container when signed) and then exercise `ExportDestinationManager`'s
/// security-scope path.
///
/// `URL.startAccessingSecurityScopedResource()` is documented to return
/// `true` (and be a no-op) for URLs that aren't security-scoped. The CI
/// macOS runner honours that documented behaviour; some local dev
/// macOS builds (observed on macOS 15.6.1, the integration-branch
/// maintainer's machine) return `false` instead, which trips the
/// post-#92 bail-out in `ExportDestinationManager.validate(url:)`. The
/// production fix is correct — we don't want to weaken the bail — but
/// the consequence is that two tests added by #96 fail locally despite
/// passing on CI.
///
/// `bareTmpRejectsScopeStart()` does a single one-shot probe: create a
/// throwaway temp directory, call `startAccessingSecurityScopedResource()`,
/// record the result, clean up. `true` means we're on a machine where the
/// API returns `false` for bare in-container URLs and the dependent tests
/// should be skipped. `false` (the common case) means the tests run
/// normally.
enum BareTmpScopeProbe {
  static func bareTmpRejectsScopeStart() -> Bool {
    let probe = TestScratch.directory("BareTmpScopeProbe")
    try? FileManager.default.createDirectory(
      at: probe, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: probe) }

    let started = probe.startAccessingSecurityScopedResource()
    if started { probe.stopAccessingSecurityScopedResource() }
    return !started
  }
}
