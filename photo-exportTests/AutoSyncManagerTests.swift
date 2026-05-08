import Combine
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 2 (auto-sync plan): integration tests for `AutoSyncManager`. Wires the pure
/// reducer to fake providers; asserts the live state transitions and effect dispatch
/// correctly. The pure reducer's behavior is covered by `AutoSyncReducerTests`; this
/// suite covers the manager's wiring (publisher subscriptions, debounce timer
/// scheduling, run dispatch, persistence).
@MainActor
struct AutoSyncManagerTests {

  private func safeDestination() -> DestinationSnapshot {
    DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "uuid-A",
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/dest",
        standardizedPath: "/Volumes/A/dest"
      ),
      isAvailable: true,
      safety: .safe
    )
  }

  // MARK: - Initial state

  @Test func managerStartsDisabledBeforeAttach() {
    let manager = AutoSyncManager()
    #expect(manager.state == .disabled)
  }

  @Test func attachWithDisabledFlagStaysDisabled() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    // userDefaults default for AutoSync.enabled is false → manager stays disabled.

    manager.attach(to: builder.environment)

    #expect(manager.state == .disabled)
  }

  @Test func attachWithEnabledFlagAndSafeDestinationSchedulesAppLaunch() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))

    manager.attach(to: builder.environment)

    if case .scheduled(.appLaunch, _) = manager.state {
      // OK
    } else {
      Issue.record("Expected .scheduled(.appLaunch, …), got \(manager.state)")
    }
  }

  // MARK: - setEnabled

  @Test func setEnabledTrueTransitionsAndPersists() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)
    #expect(manager.state == .disabled)

    manager.setEnabled(true)

    #expect(builder.userDefaults.bool(forKey: AutoSyncManager.enabledDefaultsKey))
    if case .scheduled(.appLaunch, _) = manager.state { /* ok */
    } else {
      Issue.record("Expected .scheduled after enable, got \(manager.state)")
    }
  }

  // MARK: - Debounce → run dispatch

  @Test func scheduledDebounceFiresRunAfterClockAdvance() async {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    // Advance past the 10s appLaunch debounce.
    builder.clock.advance(by: 10)
    // Yield to let the Task wrapping runExport begin.
    await Task.yield()

    #expect(builder.exportRunner.receivedContexts.count == 1)
    let ctx = builder.exportRunner.receivedContexts[0]
    #expect(ctx.source == .autoSync)
    #expect(ctx.visibility == .background)
    #expect(ctx.reason == .appLaunch)
    if case .autoExport(let scopes) = ctx.scope {
      #expect(scopes.includes(.timeline))
    } else {
      Issue.record("Expected .autoExport scope, got \(ctx.scope)")
    }
  }

  // MARK: - Photos changes → dirty state persistence

  @Test func photosChangedPersistsDirtyStateThroughTheStore() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    // Manager is now in .scheduled(.appLaunch, …) — push a photos event.
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1", "asset-2"],
      observedAt: builder.clock.now()
    )
    builder.photos.push(event)

    let destId = safeDestination().id!
    let stored = builder.dirtyStore.load(destinationId: destId)
    #expect(stored.scope(.timeline).pendingAssetIds == ["asset-1", "asset-2"])
  }

  // MARK: - Cancellation

  @Test func disablingCancelsScheduledDebounce() async {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    manager.setEnabled(false)
    #expect(manager.state == .disabled)

    // Advance past where the debounce would have fired — no run should start.
    builder.clock.advance(by: 60)
    await Task.yield()

    #expect(builder.exportRunner.receivedContexts.isEmpty)
  }

  // MARK: - Idempotent attach

  @Test func attachIsIdempotent() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()

    manager.attach(to: builder.environment)
    manager.attach(to: builder.environment)
    manager.attach(to: builder.environment)

    // No crash, state is sane.
    #expect(manager.state == .disabled)
  }
}
