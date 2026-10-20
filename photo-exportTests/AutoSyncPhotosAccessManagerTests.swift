import Foundation
import Testing

@testable import Photo_Export

/// The manager refreshes Photos access before each scheduled run and before each scope of
/// a fan-out, so a revoke the app didn't notice blocks the run instead of letting an empty
/// scan acknowledge pending work. A run already exporting is never cancelled.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AutoSyncPhotosAccessManagerTests {
  private let destination = DestinationSnapshot(
    stableId: "access-M", fingerprint: nil, isAvailable: true, safety: .safe)
  private var destinationId: String { destination.id! }

  private func attach(
    _ builder: FakeAutoSyncEnvironmentBuilder,
    scopes: AutoExportScopeSelection = AutoExportScopeSelection(timeline: true)
  ) -> AutoSyncManager {
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination)
    builder.scopes.subject.send(scopes)
    let manager = AutoSyncManager()
    manager.attach(to: builder.environment)
    return manager
  }

  private func change(_ id: String, _ builder: FakeAutoSyncEnvironmentBuilder) {
    builder.photos.push(
      PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: [id], observedAt: builder.clock.now()))
  }

  /// Access revoked while the app stayed in the background leaves the cached flag true.
  /// The refresh before the scheduled run catches it, so nothing runs or is written.
  @Test func backgroundRevokeIsCaughtBeforeTheRunStarts() {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    change("pending", builder)
    guard case .scheduled(.photosChanged, _) = manager.state else {
      Issue.record("Expected a scheduled run, got \(manager.state)")
      return
    }
    builder.photosAuthorization.live = false
    #expect(builder.photosAuthorization.cached)

    builder.clock.advance(by: 30)
    #expect(manager.activeRunFanOutTask == nil)
    #expect(builder.exportRunner.receivedContexts.isEmpty)
    #expect(builder.currentRunStore.saveCount == 0)
    #expect(builder.runSummaryStore.saveCount == 0)
    #expect(manager.state == .blocked(.photosAccessMissing))
    #expect(!builder.photosAuthorization.cached)
    #expect(builder.clock.pendingCount == 0)
    #expect(
      builder.dirtyStore.load(destinationId: destinationId).scope(.timeline).pendingAssetIds
        .contains("pending"))
  }

  /// Access revoked while a scope exports: the next scope's scan would read the cached flag,
  /// find nothing and end `.completed`. The refresh before it stops the fan-out instead.
  @Test func revokeBetweenScopesStopsTheFanOutAndKeepsTheLaterScopesWork() async throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.exportRunner.shouldHang = { $0.scope == .timelineFullLibrary }
    let manager = attach(builder, scopes: AutoExportScopeSelection(timeline: true, favorites: true))
    defer { manager.setEnabled(false) }
    change("pending", builder)
    builder.clock.advance(by: 30)
    let fanOut = try #require(manager.activeRunFanOutTask)
    try #require(await eventually("timeline scope started") {
      builder.exportRunner.receivedContexts.count == 1
    })

    builder.photosAuthorization.live = false
    builder.exportRunner.resumeHung(with: builder.exportRunner.makeDefaultCompletedSummary())
    #expect(await finished(fanOut))

    #expect(builder.exportRunner.receivedContexts.map(\.scope) == [.timelineFullLibrary])
    #expect(builder.runSummaryStore.load(destinationId: destinationId)?.context.scope == .timelineFullLibrary)
    let dirty = builder.dirtyStore.load(destinationId: destinationId)
    #expect(dirty.scope(.timeline).isEmpty)
    #expect(dirty.scope(.favorites).pendingAssetIds.contains("pending"))
    #expect(manager.state == .blocked(.photosAccessMissing))
    #expect(builder.clock.pendingCount == 0)
  }

  /// Losing access mid-run blocks Auto Export but leaves the run to finish; its summary is
  /// still saved.
  @Test func accessLostMidRunNeverCancelsTheRun() async throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.exportRunner.shouldHang = { _ in true }
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    builder.clock.advance(by: 10)
    let fanOut = try #require(manager.activeRunFanOutTask)
    try #require(await eventually("launch run started") {
      builder.exportRunner.receivedContexts.count == 1
    })

    builder.photosAuthorization.live = false
    builder.photosAuthorization.refreshAuthorization()
    #expect(manager.state == .blocked(.photosAccessMissing))
    #expect(builder.exportRunner.cancelAutoSyncRunCalls == 0)

    builder.exportRunner.resumeHung(with: builder.exportRunner.makeDefaultCompletedSummary())
    #expect(await finished(fanOut))
    #expect(builder.exportRunner.cancelAutoSyncRunCalls == 0)
    #expect(builder.runSummaryStore.saveCount == 1)
    #expect(manager.lastRunSummary?.context == builder.exportRunner.receivedContexts.first)
    #expect(manager.state == .blocked(.photosAccessMissing))
    #expect(builder.clock.pendingCount == 0)
  }

  /// Attaching without access blocks at once. The launch run is held, not dropped, and runs
  /// with its own delay once access returns.
  @Test func attachingWithoutAccessHoldsTheLaunchRun() async throws {
    let builder = FakeAutoSyncEnvironmentBuilder()
    builder.photosAuthorization.live = false
    builder.photosAuthorization.refreshAuthorization()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    #expect(manager.state == .blocked(.photosAccessMissing))
    #expect(builder.clock.pendingCount == 0)

    builder.clock.advance(by: 60)
    #expect(manager.activeRunFanOutTask == nil)

    builder.photosAuthorization.live = true
    builder.photosAuthorization.refreshAuthorization()
    #expect(
      manager.state
        == .scheduled(
          reason: .appLaunch,
          fireAt: builder.clock.now().addingTimeInterval(
            AutoSyncReducer.debounceDelay(for: .appLaunch))))
    builder.clock.advance(by: AutoSyncReducer.debounceDelay(for: .appLaunch))
    let launch = try #require(manager.activeRunFanOutTask)
    #expect(await finished(launch))
    #expect(builder.exportRunner.receivedContexts.map(\.reason) == [.appLaunch])
  }
}
