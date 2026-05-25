import SwiftUI

/// Debug-only deterministic counter for SwiftUI body re-evaluations.
///
/// A SwiftUI `View`'s `body` is recomputed whenever SwiftUI's struct-diff
/// decides the view depends on something that changed (state, environment,
/// observed objects, bindings). Counting body invocations is the cheapest
/// deterministic probe for "did this view's invalidation graph fire?" — much
/// less noisy than `_printChanges()` and stable across runs, which is what
/// the smoothness work in `docs/project/plans/ui-smoothness-plan.md` Phase 0
/// needs to compare before/after Observation migration.
///
/// Wiring at a call site (`MonthContentView`, `TimelineSidebarView`, …):
///
/// ```swift
/// var body: some View {
///   contentView
///     .measureBodyInvalidations("MonthContentView")
/// }
/// ```
///
/// Reading from a test or a debug REPL:
///
/// ```swift
/// BodyInvalidationCounter.shared.count(for: "MonthContentView")
/// BodyInvalidationCounter.shared.reset()
/// ```
///
/// The counter and modifier are compiled away entirely in Release builds —
/// `measureBodyInvalidations(_:)` returns `self` with no recorded side
/// effect, and the type is unavailable. Production binaries pay nothing.
#if DEBUG
  @MainActor
  final class BodyInvalidationCounter {
    static let shared = BodyInvalidationCounter()

    private var countsByKey: [String: Int] = [:]

    private init() {}

    func record(_ key: String) {
      countsByKey[key, default: 0] += 1
    }

    func count(for key: String) -> Int {
      countsByKey[key] ?? 0
    }

    func snapshot() -> [String: Int] {
      countsByKey
    }

    func reset() {
      countsByKey.removeAll()
    }
  }
#endif

extension View {
  /// Records a body invalidation under `key` every time the host view's body
  /// is evaluated. No-op in Release builds.
  func measureBodyInvalidations(_ key: String) -> Self {
    #if DEBUG
      BodyInvalidationCounter.shared.record(key)
    #endif
    return self
  }
}
