import Foundation
import Testing

@testable import Photo_Export

/// Unit tests for `PhotoLibraryPersistentChangeAdapter.coalescePending` — the pure
/// policy that decides which trigger to use for a follow-up catch-up when multiple
/// triggers arrive while a previous catch-up is in flight.
///
/// Background: with a large library, `fetchPersistentChanges` enumeration can take
/// minutes, during which `photoLibraryDidChange` can fire many times. The adapter
/// coalesces those stacked triggers into at most one follow-up. The choice of
/// trigger affects whether the UI-side bridge fires in `applyCatchUpResult` (the
/// observer path skips the bridge because the manager invalidates its own caches
/// via its own change-observer callback; `.startup` and `.safetyNet` fire it).
struct PhotoLibraryCatchUpCoalesceTests {

  typealias Trigger = PhotoLibraryPersistentChangeAdapter.ReconcileTrigger

  /// No pending trigger ⇒ the incoming one becomes the follow-up.
  @Test func noPendingReturnsIncoming() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(nil, incoming: .observer)
        == .observer)
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(nil, incoming: .safetyNet)
        == .safetyNet)
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(nil, incoming: .startup)
        == .startup)
  }

  /// Observer stacking on observer keeps observer — no need to fire the UI bridge.
  @Test func observerStackedOnObserverKeepsObserver() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.observer, incoming: .observer)
        == .observer)
  }

  /// A `.safetyNet` arriving while `.observer` is pending wins — the safety-net
  /// path *requires* the UI bridge to fire (the manager hasn't observed any
  /// change-observer callback for that path). An observer-only follow-up would
  /// silently drop the safety-net's UI-wake responsibility.
  @Test func safetyNetWinsOverPendingObserver() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.observer, incoming: .safetyNet)
        == .safetyNet)
  }

  /// Same for `.startup`.
  @Test func startupWinsOverPendingObserver() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.observer, incoming: .startup)
        == .startup)
  }

  /// Once a non-observer trigger is pending, a subsequent `.observer` doesn't
  /// downgrade it — the UI-bridge-firing trigger survives.
  @Test func observerDoesNotDowngradePendingSafetyNet() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.safetyNet, incoming: .observer)
        == .safetyNet)
  }

  @Test func observerDoesNotDowngradePendingStartup() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.startup, incoming: .observer)
        == .startup)
  }

  /// Two non-observer triggers stacking: the first one wins. Both fire the UI
  /// bridge, so either is correct; sticking with the first is the cheaper rule
  /// (no replace-with-newer churn).
  @Test func nonObserverPendingSticksAcrossNonObserverIncoming() {
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.safetyNet, incoming: .startup)
        == .safetyNet)
    #expect(
      PhotoLibraryPersistentChangeAdapter.coalescePending(.startup, incoming: .safetyNet)
        == .startup)
  }
}
