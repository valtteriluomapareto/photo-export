import Foundation
import Testing

@testable import Photo_Export

/// Bounded episodes exercise public manager inputs and pure reducer contracts.
/// No filesystem-crash, variant-execution, or exhaustive-state-space claim.
@MainActor
struct AutoSyncGeneratedSequenceTests {
  private static let seeds: [UInt64] = [1, 7, 42, 0xA11CE, 0x5EED, 0xDEAD_BEEF]
  private let allScopes = AutoExportScopeSelection(
    timeline: true, favorites: true, albums: true, sharedAlbums: true)

  private func destination(_ id: String) -> DestinationSnapshot {
    DestinationSnapshot(stableId: id, fingerprint: nil, isAvailable: true, safety: .safe)
  }

  private func attach(_ builder: FakeAutoSyncEnvironmentBuilder) -> AutoSyncManager {
    builder.userDefaults.set(true, forKey: AutoSyncManager.enabledDefaultsKey)
    builder.destination.subject.send(destination("A"))
    builder.scopes.subject.send(AutoExportScopeSelection(timeline: true))
    let manager = AutoSyncManager()
    manager.attach(to: builder.environment)
    return manager
  }

  @Test(arguments: seeds)
  func savedTokensNeverAcknowledgeUnpersistedObservedWork(seed: UInt64) {
    let builder = FakeAutoSyncEnvironmentBuilder()
    let manager = attach(builder)
    defer { manager.setEnabled(false) }
    var generator = SequenceGenerator(seed: seed)
    var trace = SequenceTrace(seed: seed)
    var active = "A"
    var observed: [String: Set<String>] = ["A": [], "B": []]
    // Mandatory prefix: successful save, failed save, token-only, B, B work, A,
    // then recovery. Random tails explore additional cross-event combinations.
    let prefix = [1, 2, 3, 0, 1, 0, 1]
    for step in 0..<48 {
      let action = step < prefix.count ? prefix[step] : generator.pick(4)
      let other = active == "A" ? "B" : "A"
      let otherDirty = builder.dirtyStore.load(destinationId: other)
      let otherToken = builder.perDestinationTokenStore.load(destinationId: other)
      if action == 0 {
        active = other
        trace.append("\(step): select \(active)")
        builder.destination.subject.send(destination(active))
      } else {
        let token = Data([UInt8(step + 1)])
        let oldToken = builder.perDestinationTokenStore.load(destinationId: active)
        let work = action != 3
        let id = "asset-\(step)"
        if work { observed[active, default: []].insert(id) }
        if action == 2 {
          builder.dirtyStore.nextSaveError = InMemoryAutoSyncStoreError("generated")
        }
        trace.append("\(step): \(active) \(work ? id : "token-only") saveFailure=\(action == 2)")
        builder.photos.push(
          PhotoLibraryPersistentChangeEvent(
            insertedLocalIdentifiers: work ? [id] : [],
            deletedLocalIdentifiers: work ? [] : ["deleted"],
            observedAt: builder.clock.now(), nextToken: token))
        let saved = builder.dirtyStore.load(destinationId: active).scope(.timeline)
        if builder.perDestinationTokenStore.load(destinationId: active) != oldToken {
          #expect(
            saved.pendingFullReconciliation
              || observed[active, default: []].isSubset(of: saved.pendingAssetIds), "\(trace)")
        }
        #expect(builder.dirtyStore.load(destinationId: other) == otherDirty, "\(trace)")
        #expect(
          builder.perDestinationTokenStore.load(destinationId: other) == otherToken, "\(trace)")
      }
    }
    // Force successful progress for both destinations after every generated tail.
    for id in ["A", "B"] {
      builder.destination.subject.send(destination(id))
      observed[id, default: []].insert("final-\(id)")
      let token = Data([id == "A" ? 250 : 251])
      trace.append("final successful \(id)")
      builder.photos.push(
        PhotoLibraryPersistentChangeEvent(
          insertedLocalIdentifiers: ["final-\(id)"], observedAt: builder.clock.now(),
          nextToken: token))
      #expect(
        builder.dirtyStore.load(destinationId: id).scope(.timeline).pendingAssetIds == observed[id],
        "\(trace)")
      #expect(builder.perDestinationTokenStore.load(destinationId: id) == token, "\(trace)")
    }
    #expect(
      builder.exportRunner.receivedContexts.isEmpty, "The export clock remains stopped. \(trace)")
  }

  @Test(arguments: seeds)
  func ownedRunBoundariesKeepPostStartChangesAndRejectStaleCompletion(seed: UInt64) {
    var generator = SequenceGenerator(seed: seed)
    for episode in 0..<16 {
      var trace = SequenceTrace(seed: seed)
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      let scope = AutoExportLibraryScope.allCases[
        generator.pick(AutoExportLibraryScope.allCases.count)]
      let source: ExportRunSource = generator.pick(2) == 0 ? .autoSync : .manual
      let context = ExportRunContext(
        runId: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", episode + 1))")!,
        source: source, visibility: .userVisible, scope: scope.fullRunScope, selection: .edited,
        startedAt: now)
      var state = AutoSyncReducer.State.initial
      state.enabled = true
      state.current = .idle
      state.destination = destination("A")
      state.scopeSelection = allScopes
      func apply(_ event: AutoSyncEvent, _ label: String) {
        trace.append("episode \(episode) \(label)")
        state = AutoSyncReducer.reduce(event, in: state, now: now).0
      }
      func start(_ run: ExportRunContext) {
        if source == .autoSync {
          apply(.exportRunStarted(run, destinationId: "A"), "start A \(run.runId)")
        } else {
          apply(
            .exportRunStateChanged(
              ExportRunState(activeContext: run, isManualActive: true, isAutoSyncActive: false)),
            "manual start A \(run.runId)")
        }
      }
      apply(
        .photosChanged(
          PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: ["same"], observedAt: now)),
        "pre-start same")
      start(context)
      // Always repeat the same ID at the same timestamp after start: set equality
      // alone cannot establish whether the run covers this later change.
      apply(
        .photosChanged(
          PhotoLibraryPersistentChangeEvent(updatedLocalIdentifiers: ["same"], observedAt: now)),
        "post-start same")
      var expectedPostStartIds: Set<String> = ["same"]
      var expectedFullReconciliation = false
      var expectedPlacementReconciliation = false
      for index in 0..<generator.pick(6) {
        if generator.pick(3) == 0 {
          expectedFullReconciliation = true
          apply(.photosChangeFetchFailed(.detailsUnavailable), "post-start fallback \(index)")
        } else {
          let id = "later-\(index)"
          let collectionChange = generator.pick(2) == 0
          expectedPostStartIds.insert(id)
          expectedPlacementReconciliation = expectedPlacementReconciliation || collectionChange
          apply(
            .photosChanged(
              PhotoLibraryPersistentChangeEvent(
                updatedLocalIdentifiers: [id],
                collectionChangesPresent: collectionChange, observedAt: now)),
            "post-start change \(index)")
        }
      }
      if generator.pick(2) == 0 {
        apply(.versionSelectionChanged(.editedWithOriginals), "include originals on")
        apply(.versionSelectionChanged(.edited), "restore run selection")
      }
      if generator.pick(2) == 0 {
        // Toggle a different scope, leaving the scope under test selected.
        let narrower = AutoExportScopeSelection(
          timeline: scope != .favorites, favorites: scope == .favorites,
          albums: true, sharedAlbums: true)
        apply(.scopeSelectionChanged(narrower), "scope setting changed")
        apply(.scopeSelectionChanged(allScopes), "restore all scopes")
      }
      let mode = episode % 4
      if mode == 1 || mode == 2 {
        apply(.destinationChanged(destination("B")), "select B; abandon A")
        apply(
          .photosChanged(
            PhotoLibraryPersistentChangeEvent(insertedLocalIdentifiers: ["B-only"], observedAt: now)
          ), "B change")
        if mode == 2 { apply(.destinationChanged(destination("A")), "return A") }
      } else if mode == 3 {
        let replacement = ExportRunContext(
          runId: UUID(
            uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", episode + 101))")!,
          source: source, visibility: .userVisible, scope: scope.fullRunScope, selection: .edited,
          startedAt: now)
        start(replacement)
      }
      let before = state.dirtyStateByDestination
      let boundaryBefore = state.runDirtyBoundary
      apply(.exportRunStateChanged(.idle), "idle before summary")
      let outcome = [ExportRunResult.completed, .cancelled, .interrupted, .failed][episode / 4]
      let summary = ExportRunSummary(
        context: context, endedAt: now,
        enqueuedCount: 1, completedCount: outcome == .completed ? 1 : 0,
        failedCount: outcome == .failed ? 1 : 0, skippedCount: 0,
        cancelReason: outcome == .cancelled ? .userCancelled : nil, result: outcome)
      apply(
        source == .autoSync
          ? .autoSyncRunCompleted(summary, destinationId: "A")
          : .manualFullExportCompleted(summary), "finish original A \(context.runId): \(outcome)")
      if mode == 0 {
        let pending = state.dirtyStateByDestination["A"]?.scope(scope)
        #expect(
          pending?.pendingFullReconciliation == true
            || expectedPostStartIds.isSubset(of: pending?.pendingAssetIds ?? []), "\(trace)")
        if expectedFullReconciliation {
          #expect(pending?.pendingFullReconciliation == true, "\(trace)")
        }
        if expectedPlacementReconciliation && (scope == .albums || scope == .sharedAlbums) {
          #expect(pending?.pendingPlacementReconciliation == true, "\(trace)")
        }
      } else {
        #expect(state.dirtyStateByDestination == before, "\(trace)")
        #expect(state.runDirtyBoundary == boundaryBefore, "\(trace)")
      }
      #expect(state.dirtyStateByDestination["B"] == before["B"], "\(trace)")
    }
  }

  @Test(arguments: seeds)
  func retrySequencesRespectDeadlinesAndBlockersWithoutImmediateLoops(seed: UInt64) async throws {
    var generator = SequenceGenerator(seed: seed)
    var remaining = ["none", "manual", "import", "disabled", "unselected", "destination"]
    while !remaining.isEmpty {
      let blocker = remaining.remove(at: generator.pick(remaining.count))
      var trace = SequenceTrace(seed: seed)
      let builder = FakeAutoSyncEnvironmentBuilder()
      let delay = [30.0, 45.0, 120.0][generator.pick(3)]
      var retry = AutoSyncRetryState.empty
      retry.recordFailure(
        scope: blocker == "unselected" ? .favorites : .timeline,
        assetId: "retry", variant: .original, category: .photoKitTransient,
        errorSignature: "same", at: builder.clock.now(),
        nextEligibleAt: builder.clock.now().addingTimeInterval(delay))
      try builder.retryStore.save(retry, destinationId: "A")
      let manager = attach(builder)
      builder.clock.advance(by: 10)
      let launch = try #require(manager.activeRunFanOutTask, "\(trace)")
      await launch.value
      trace.append("\(blocker): startup drained; deadline +\(delay)")
      defer { manager.setEnabled(false) }
      switch blocker {
      case "manual":
        builder.exportRunner.subject.send(
          ExportRunState(activeContext: nil, isManualActive: true, isAutoSyncActive: false))
      case "import": builder.importing.subject.send(true)
      case "disabled": manager.setEnabled(false)
      case "destination": builder.destination.subject.send(.none)
      default: break
      }
      builder.clock.advance(by: delay - 10 - 0.25)
      trace.append("just before deadline")
      #expect(
        builder.exportRunner.receivedContexts.filter { $0.reason == .retryBackoff }.isEmpty,
        "\(trace)")
      builder.clock.advance(by: 0.25)
      // TestClock defers newly scheduled callbacks until the next advance:
      // due retry timer, then its immediate run debounce.
      builder.clock.advance(by: 0)
      builder.clock.advance(by: 0)
      if let task = manager.activeRunFanOutTask { await task.value }
      trace.append("at deadline while \(blocker)")
      let expectedAtDeadline = blocker == "none" ? 1 : 0
      #expect(
        builder.exportRunner.receivedContexts.filter { $0.reason == .retryBackoff }.count
          == expectedAtDeadline, "\(trace)")
      switch blocker {
      case "manual": builder.exportRunner.subject.send(.idle)
      case "import": builder.importing.subject.send(false)
      case "disabled": manager.setEnabled(true)
      case "destination": builder.destination.subject.send(destination("A"))
      default: break
      }
      builder.clock.advance(by: 0)
      builder.clock.advance(by: 0)
      if let task = manager.activeRunFanOutTask { await task.value }
      trace.append("block released")
      let expected = blocker == "unselected" ? 0 : 1
      #expect(
        builder.exportRunner.receivedContexts.filter { $0.reason == .retryBackoff }.count
          == expected, "\(trace)")
      for step in 0..<5 {
        builder.clock.advance(by: 0)
        if let task = manager.activeRunFanOutTask { await task.value }
        trace.append("zero-time advance \(step)")
        #expect(
          builder.exportRunner.receivedContexts.filter { $0.reason == .retryBackoff }.count
            == expected, "\(trace)")
      }
    }
  }
}

private struct SequenceGenerator {
  private var value: UInt64
  init(seed: UInt64) { value = seed }
  mutating func pick(_ count: Int) -> Int {
    value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((value >> 32) % UInt64(count))
  }
}

private struct SequenceTrace: CustomStringConvertible {
  let seed: UInt64
  private var actions: [String] = []
  init(seed: UInt64) { self.seed = seed }
  mutating func append(_ action: String) { actions.append(action) }
  var description: String { "seed=\(seed); " + actions.suffix(64).joined(separator: " → ") }
}
