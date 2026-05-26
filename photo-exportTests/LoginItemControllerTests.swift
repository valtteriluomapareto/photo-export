import Foundation
import Observation
import Testing

@testable import Photo_Export

/// Coverage for `LoginItemController`. The class wraps `SMAppService.mainApp`,
/// so most behaviour is driven by the real system service and is not testable
/// in isolation. This file pins the `@Observable` tracking contract added in
/// Phase 2 of the Observation migration — a future refactor that breaks the
/// macro instrumentation on `status` (an accidental `@ObservationIgnored`,
/// swapping the class back to plain `class`) would fail this test instead of
/// silently disabling the toggle's reactivity in the Settings UI.
///
/// See `docs/reference/observation-migration-recipe.md` §"Verify that the
/// macro actually instrumented the property".
@MainActor
struct LoginItemControllerTests {

  /// Direct `withObservationTracking` rather than `ObservationCounter`:
  /// the counter's async resume path can't distinguish "tracking
  /// registered but no fire" from "tracking never registered", so a
  /// regression that removed `@Observable` would surface as a timeout
  /// either way. Using the raw primitive with a synchronous assertion
  /// after a known mutation is the tighter check.
  ///
  /// The mutation has to produce a *value change* — the Observation
  /// framework's tracking observers are notified on willSet only when the
  /// new value differs from the old (the macro itself fires willSet
  /// unconditionally, but `withObservationTracking` deduplicates by
  /// value). Forcing the change by calling `unregister()` after a fresh
  /// init in a test environment, where `SMAppService.mainApp` is not
  /// available, transitions `status` from its `.notFound`/`.unknown`
  /// post-init value to whatever the failed-unregister path produces —
  /// the relevant invariant for this test is just *that* a transition
  /// fires the observer.
  @Test func statusMutationFiresTrackedObserver() {
    let controller = LoginItemController()
    let initial = controller.status

    var observedChange = false
    withObservationTracking {
      _ = controller.status
    } onChange: {
      observedChange = true
    }

    // Force a value different from `initial` via the type-level enum, so
    // the test doesn't depend on what `SMAppService` returns in the test
    // host environment.
    let next: LoginItemController.Status = (initial == .enabled) ? .notFound : .enabled
    controller.setStatusForObservationTracking(next)

    #expect(observedChange,
      "@Observable macro must instrument `status` so the Settings toggle re-renders on transitions")
  }
}
