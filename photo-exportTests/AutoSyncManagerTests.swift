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

  // MARK: - Per-destination state load on destinationChanged

  @Test func destinationChangeLoadsPersistedDirtyState() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let destId = safeDestination().id!
    var seeded = AutoSyncDirtyState.empty
    var timelineScope = seeded.scope(.timeline)
    timelineScope.recordPendingAssetId("seeded-asset", costCap: 500)
    seeded.setScope(.timeline, timelineScope)
    try? builder.dirtyStore.save(seeded, destinationId: destId)
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))

    manager.attach(to: builder.environment)
    builder.destination.subject.send(safeDestination())

    // Pushing a photos event for *new* asset ids should accumulate on top of the
    // seeded state, not overwrite it. If the load failed, the new ids would
    // entirely replace `seeded-asset`.
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ["new-asset"],
        observedAt: builder.clock.now()
      ))

    let stored = builder.dirtyStore.load(destinationId: destId)
    #expect(stored.scope(.timeline).pendingAssetIds.contains("seeded-asset"))
    #expect(stored.scope(.timeline).pendingAssetIds.contains("new-asset"))
  }

  @Test func destinationChangeLoadsPersistedRunSummary() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let destId = safeDestination().id!
    let priorSummary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .autoExport(AutoExportScopeSelection(timeline: true)),
        selection: .edited
      ),
      endedAt: Date(),
      enqueuedCount: 12, completedCount: 12, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed
    )
    try? builder.runSummaryStore.save(priorSummary, destinationId: destId)

    manager.attach(to: builder.environment)
    builder.destination.subject.send(safeDestination())

    #expect(manager.lastRunSummary == priorSummary)
  }

  @Test func destinationClearedDropsLastRunSummary() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    let destId = safeDestination().id!
    let priorSummary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .autoExport(AutoExportScopeSelection(timeline: true)),
        selection: .edited
      ),
      endedAt: Date(),
      enqueuedCount: 1, completedCount: 1, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed
    )
    try? builder.runSummaryStore.save(priorSummary, destinationId: destId)
    manager.attach(to: builder.environment)
    builder.destination.subject.send(safeDestination())
    #expect(manager.lastRunSummary == priorSummary)

    builder.destination.subject.send(.none)

    #expect(manager.lastRunSummary == nil)
  }

  @Test func runCompletionPersistsRunSummaryToStore() async {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    builder.clock.advance(by: 10)
    await Task.yield()
    await Task.yield()

    let destId = safeDestination().id!
    let saved = builder.runSummaryStore.load(destinationId: destId)
    #expect(saved != nil)
    #expect(saved?.context.source == .autoSync)
  }

  @Test func photosChangeAdvancesPerDestinationToken() {
    let manager = AutoSyncManager()
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(safeDestination())
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    manager.attach(to: builder.environment)

    let opaqueToken = Data([0xDE, 0xAD, 0xBE, 0xEF])
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(
        insertedLocalIdentifiers: ["asset-1"],
        observedAt: builder.clock.now(),
        nextToken: opaqueToken
      ))

    let destId = safeDestination().id!
    #expect(builder.perDestinationTokenStore.load(destinationId: destId) == opaqueToken)
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
