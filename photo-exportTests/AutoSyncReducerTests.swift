import Foundation
import Testing

@testable import Photo_Export

/// Phase 2 (auto-sync plan): pure reducer for the AutoSync state machine. Tests are
/// single-event-in / state+effects-out — call `AutoSyncReducer.reduce`, assert the
/// returned `State` and effect list. No timers, no actor isolation, no I/O.
///
/// First slice: input-gating events (enabled, destination, scope, version, import).
/// Subsequent slices add `photosChanged` / `debounceFired` / run-lifecycle / retry
/// scheduling.
struct AutoSyncReducerTests {

  // MARK: - Helpers

  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func safeDestination(_ tag: String = "dest-A") -> DestinationSnapshot {
    DestinationSnapshot(
      fingerprint: .makeHigh(
        volumeUUIDString: "uuid-\(tag)",
        volumeRootPath: nil,
        relativePathFromVolumeRoot: "/\(tag)",
        standardizedPath: "/Volumes/\(tag)"
      ),
      isAvailable: true,
      safety: .safe
    )
  }

  private func enabledStateWithSafeDestinationAndScope() -> AutoSyncReducer.State {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    return state
  }

  // MARK: - Initial state

  @Test func initialStateIsDisabled() {
    #expect(AutoSyncReducer.State.initial.current == .disabled)
  }

  // MARK: - enabledChanged

  @Test func enableWithNoDestinationBlocksOnDestinationMissing() {
    var state = AutoSyncReducer.State.initial
    state.scopeSelection = AutoExportScopeSelection(timeline: true)

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    #expect(next.current == .blocked(.destinationMissing))
    #expect(effects.isEmpty)
  }

  @Test func enableWithNoScopesBlocksOnNoScopesSelected() {
    var state = AutoSyncReducer.State.initial
    state.destination = safeDestination()

    let (next, _) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    #expect(next.current == .blocked(.noScopesSelected))
  }

  @Test func enableWithSafeDestinationAndScopeSchedulesAppLaunch() {
    var state = AutoSyncReducer.State.initial
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, favorites: true)

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(true), in: state, now: now)

    let fireAt = now.addingTimeInterval(10)
    #expect(next.current == .scheduled(reason: .appLaunch, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.appLaunch, fireAt: fireAt)])
  }

  @Test func disableFromAnyStateReturnsToDisabled() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, _) = AutoSyncReducer.reduce(.enabledChanged(false), in: state, now: now)

    #expect(next.enabled == false)
    #expect(next.current == .disabled)
  }

  // MARK: - destinationChanged

  @Test func destinationUnmountWhileEnabledTransitionsToWaiting() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let unmounted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    let (next, _) = AutoSyncReducer.reduce(.destinationChanged(unmounted), in: state, now: now)

    #expect(next.current == .waiting(.destinationUnavailable))
  }

  @Test func destinationClearedTransitionsToBlockedDestinationMissing() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let (next, _) = AutoSyncReducer.reduce(
      .destinationChanged(.none), in: state, now: now)

    #expect(next.current == .blocked(.destinationMissing))
  }

  @Test func unsafeDestinationTransitionsToBlockedUnsafe() {
    var state = enabledStateWithSafeDestinationAndScope()

    let unsafe = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .unsafeNeedsConfirmation
    )
    let (next, _) = AutoSyncReducer.reduce(.destinationChanged(unsafe), in: state, now: now)

    #expect(next.current == .blocked(.destinationUnsafe))
  }

  @Test func migrationConflictAlsoBlocksUnsafe() {
    var state = enabledStateWithSafeDestinationAndScope()

    let conflicted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .unsafeMigrationConflict
    )
    let (next, _) = AutoSyncReducer.reduce(
      .destinationChanged(conflicted), in: state, now: now)

    #expect(next.current == .blocked(.destinationUnsafe))
  }

  /// #127: a network-share remount drifts the fingerprint but keeps the stable id. The reducer
  /// must keep keying on the stable id so the destination's accumulated dirty work is preserved,
  /// not orphaned under a new key.
  @Test func remountWithDriftedFingerprintKeepsStableIdAndPreservesDirty() {
    let stableId = "stable-S"
    let fpMountA = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/backup",
      standardizedPath: "/Volumes/mount-A/backup")
    let fpMountB = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/backup",
      standardizedPath: "/Volumes/mount-B/backup")
    #expect(fpMountA.id != fpMountB.id)

    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    state.destination = DestinationSnapshot(
      stableId: stableId, fingerprint: fpMountA, isAvailable: true, safety: .safe)
    state.current = .idle
    var dirty = AutoSyncDirtyState.empty
    var scopeState = dirty.scope(.timeline)
    scopeState.recordPendingAssetId("asset-1", costCap: AutoSyncReducer.targetedAssetCostCap)
    dirty.setScope(.timeline, scopeState)
    state.dirtyStateByDestination[stableId] = dirty

    let drifted = DestinationSnapshot(
      stableId: stableId, fingerprint: fpMountB, isAvailable: true, safety: .safe)
    let (next, effects) = AutoSyncReducer.reduce(.destinationChanged(drifted), in: state, now: now)

    #expect(next.destination.id == stableId)
    #expect(
      next.dirtyStateByDestination[stableId]?.scope(.timeline).pendingAssetIds == ["asset-1"])
    // A same-stable-id metadata refresh (availability + safety unchanged) is not new work: no
    // spurious debounce, and the state stays idle.
    #expect(effects.isEmpty)
    #expect(next.current == .idle)
    #expect(next.destination.fingerprint == fpMountB)  // metadata refreshed
  }

  /// Swapping to a *different* destination while the prior one was unavailable schedules
  /// `.destinationSelected` (3s), not `.destinationBecameAvailable` (reserved for the SAME stable
  /// id returning). Keys the classification on stableId.
  @Test func swappingDestinationWhileUnavailableSchedulesDestinationSelected() {
    var state = enabledStateWithSafeDestinationAndScope()
    let fpA = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/a", standardizedPath: "/Volumes/A/a")
    let fpB = DestinationFingerprint.makeLow(
      volumeRootPath: nil, relativePathFromVolumeRoot: "/b", standardizedPath: "/Volumes/B/b")
    state.destination = DestinationSnapshot(
      stableId: "id-A", fingerprint: fpA, isAvailable: false, safety: .safe)
    state.current = .waiting(.destinationUnavailable)

    let restored = DestinationSnapshot(
      stableId: "id-B", fingerprint: fpB, isAvailable: true, safety: .safe)
    let (next, effects) = AutoSyncReducer.reduce(
      .destinationChanged(restored), in: state, now: now)

    let fireAt = now.addingTimeInterval(3)
    #expect(next.current == .scheduled(reason: .destinationSelected, fireAt: fireAt))
    #expect(effects.contains(.scheduleDebounce(.destinationSelected, fireAt: fireAt)))
  }

  /// The unavailable invariant's published shape — `stableId == nil` while `isAvailable == true`
  /// — blocks on `.destinationMissing` (the id guard precedes the availability guard). Pins the
  /// guard order so a future reorder can't silently change behavior.
  @Test func nilStableIdWithAvailableTrueBlocksOnDestinationMissing() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle
    let snap = DestinationSnapshot(
      stableId: nil, fingerprint: nil, isAvailable: true, safety: .safe)

    let (next, _) = AutoSyncReducer.reduce(.destinationChanged(snap), in: state, now: now)

    #expect(next.current == .blocked(.destinationMissing))
  }

  // MARK: - scopeSelectionChanged

  @Test func clearingAllScopesBlocksOnNoScopesSelected() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle

    let (next, _) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection()), in: state, now: now)

    #expect(next.current == .blocked(.noScopesSelected))
  }

  @Test func enablingNewScopeSchedulesScopeChange() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection()
    state.current = .blocked(.noScopesSelected)

    let (next, effects) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(albums: true)),
      in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.current == .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.scopeSelectionChanged, fireAt: fireAt)])
    #expect(next.scopeSelection.includes(.albums))
  }

  // MARK: - importStateChanged

  @Test func importActiveTransitionsToWaiting() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, _) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: true), in: state, now: now)

    #expect(next.current == .waiting(.importActive))
    #expect(next.importActive)
  }

  @Test func importDoneReturnsToIdle() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.importActive = true
    state.current = .waiting(.importActive)

    let (next, _) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: false), in: state, now: now)

    #expect(next.current == .idle)
    #expect(next.importActive == false)
  }

  // MARK: - versionSelectionChanged

  @Test func versionSelectionChangeSchedulesDebounce() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, effects) = AutoSyncReducer.reduce(
      .versionSelectionChanged(.editedWithOriginals), in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.versionSelection == .editedWithOriginals)
    #expect(next.current == .scheduled(reason: .versionSelectionChanged, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.versionSelectionChanged, fireAt: fireAt)])
  }

  @Test func versionSelectionUnchangedIsNoOp() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.versionSelection = .editedWithOriginals
    state.current = .idle

    let (next, effects) = AutoSyncReducer.reduce(
      .versionSelectionChanged(.editedWithOriginals), in: state, now: now)

    #expect(next.current == .idle)
    #expect(effects.isEmpty)
  }

  // MARK: - convertHEICToJPEGChanged (issue #47)

  /// Flipping the toggle reschedules AutoSync at the same 2s debounce as
  /// `versionSelectionChanged`. Without this, AutoSync would sit idle on
  /// the user's toggle flip until the next photos-change / app-launch.
  @Test func convertHEICToJPEGChangeSchedulesDebounce() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, effects) = AutoSyncReducer.reduce(
      .convertHEICToJPEGChanged(true), in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.convertHEICToJPEG == true)
    #expect(next.current == .scheduled(reason: .convertHEICToJPEGChanged, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.convertHEICToJPEGChanged, fireAt: fireAt)])
  }

  /// Idempotent flips (toggle landing back on the value it was already at —
  /// e.g. rapid double-click on the toolbar) must not reschedule.
  @Test func convertHEICToJPEGUnchangedIsNoOp() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.convertHEICToJPEG = true
    state.current = .idle

    let (next, effects) = AutoSyncReducer.reduce(
      .convertHEICToJPEGChanged(true), in: state, now: now)

    #expect(next.current == .idle)
    #expect(effects.isEmpty)
  }

  // MARK: - debounceFired → running → idle

  @Test func debounceFiredFromScheduledStartsRun() {
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(10)
    state.current = .scheduled(reason: .appLaunch, fireAt: fireAt)

    let (next, effects) = AutoSyncReducer.reduce(
      .debounceFired(.appLaunch), in: state, now: fireAt)

    #expect(next.current == .running(reason: .appLaunch))
    #expect(effects.count == 1)
    if case .startRun(let spec) = effects[0] {
      #expect(spec.source == .autoSync)
      #expect(spec.visibility == .background)
      #expect(spec.reason == .appLaunch)
      #expect(spec.selection == .edited)
      // .autoExport scope carries the current selection.
      if case .autoExport(let scopes) = spec.scope {
        #expect(scopes == state.scopeSelection)
      } else {
        Issue.record("Expected .autoExport scope, got \(spec.scope)")
      }
    } else {
      Issue.record("Expected .startRun effect, got \(effects[0])")
    }
  }

  @Test func staleDebounceFiredIsIgnored() {
    // Scheduled with .appLaunch, but the firing event names a different reason —
    // typical of a debounce that was cancelled and replaced after the user toggled
    // a scope. Honor only the reason matching the current schedule.
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(10)
    state.current = .scheduled(reason: .appLaunch, fireAt: fireAt)

    let (next, effects) = AutoSyncReducer.reduce(
      .debounceFired(.scopeSelectionChanged), in: state, now: fireAt)

    #expect(next.current == .scheduled(reason: .appLaunch, fireAt: fireAt))
    #expect(effects.isEmpty)
  }

  @Test func runCompletionReturnsToIdle() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .running(reason: .appLaunch)
    state.exportRunState = .idle  // Run finished — exporter signals idle.

    let (next, effects) = AutoSyncReducer.reduce(
      .exportRunStateChanged(.idle), in: state, now: now)

    #expect(next.current == .idle)
    // No re-schedule on run completion — only events that introduce new work do.
    #expect(effects.isEmpty)
  }

  // MARK: - Cancel-on-transition-out

  @Test func unmountWhileScheduledCancelsDebounce() {
    var state = enabledStateWithSafeDestinationAndScope()
    let fireAt = now.addingTimeInterval(2)
    state.current = .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt)

    let unmounted = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    let (next, effects) = AutoSyncReducer.reduce(
      .destinationChanged(unmounted), in: state, now: now)

    #expect(next.current == .waiting(.destinationUnavailable))
    #expect(effects == [.cancelDebounce(.scopeSelectionChanged)])
  }

  @Test func remountAfterUnmountSchedulesDestinationBecameAvailable() {
    // Was scheduled when drive went away, transitioned to .waiting. When the same
    // drive comes back, schedule with .destinationBecameAvailable (the appropriate
    // 3s debounce).
    var state = enabledStateWithSafeDestinationAndScope()
    let unavailable = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: false,
      safety: .safe
    )
    state.destination = unavailable
    state.current = .waiting(.destinationUnavailable)

    let restored = DestinationSnapshot(
      fingerprint: state.destination.fingerprint,
      isAvailable: true,
      safety: .safe
    )
    let (next, effects) = AutoSyncReducer.reduce(.destinationChanged(restored), in: state, now: now)

    let fireAt = now.addingTimeInterval(3)
    #expect(next.current == .scheduled(reason: .destinationBecameAvailable, fireAt: fireAt))
    #expect(effects == [.scheduleDebounce(.destinationBecameAvailable, fireAt: fireAt)])
  }

  @Test func disablingWhileScheduledCancelsDebounce() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let (next, effects) = AutoSyncReducer.reduce(.enabledChanged(false), in: state, now: now)

    #expect(next.current == .disabled)
    #expect(effects == [.cancelDebounce(.appLaunch)])
  }

  @Test func newTriggerDuringScheduledReplacesDebounce() {
    // Was scheduled with .appLaunch (10s); user changes scopes — replace with
    // .scopeSelectionChanged (2s). Plan: "the most recent scheduling wins" via
    // cancel-then-schedule.
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let newScopes = AutoExportScopeSelection(timeline: true, favorites: true)
    let (next, effects) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(newScopes), in: state, now: now)

    let fireAt = now.addingTimeInterval(2)
    #expect(next.current == .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt))
    #expect(
      effects == [
        .cancelDebounce(.appLaunch),
        .scheduleDebounce(.scopeSelectionChanged, fireAt: fireAt),
      ])
  }

  // MARK: - photosChanged

  @Test func photosChangedWhenDisabledIsIgnored() {
    let state = AutoSyncReducer.State.initial  // enabled = false
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedWithNoDestinationIsIgnored() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedWithNoSelectedScopesIsIgnored() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-1"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.dirtyStateByDestination.isEmpty)
    #expect(effects.isEmpty)
  }

  @Test func photosChangedAccumulatesDirtyAssetIds() {
    let state = enabledStateWithSafeDestinationAndScope()
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a", "b"],
      updatedLocalIdentifiers: ["c"],
      observedAt: now
    )

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    #expect(dirty?.scope(.timeline).pendingAssetIds == ["a", "b", "c"])
    #expect(dirty?.lastUpdatedAt == now)

    let fireAt = now.addingTimeInterval(30)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: fireAt))
    // persistDirtyState + scheduleDebounce expected. (No nextToken in event so no
    // advancePersistentChangeToken effect.)
    #expect(effects.contains(.scheduleDebounce(.photosChanged, fireAt: fireAt)))
    #expect(
      effects.contains(where: {
        if case .persistDirtyState(_, let did) = $0 { return did == destId }
        return false
      }))
  }

  @Test func photosChangedAccumulatesDirtyEvenWhenDestinationUnavailable() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.destination = DestinationSnapshot(
      fingerprint: state.destination.fingerprint, isAvailable: false, safety: .safe)
    state.current = .waiting(.destinationUnavailable)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["asset-x"], observedAt: now)

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    #expect(next.dirtyStateByDestination[destId]?.scope(.timeline).pendingAssetIds == ["asset-x"])
    // State stays .waiting — we accumulate dirty state but don't try to run.
    #expect(next.current == .waiting(.destinationUnavailable))
  }

  @Test func photosChangedRollsOverToFullReconciliationAtCostCap() {
    let state = enabledStateWithSafeDestinationAndScope()
    let cap = AutoSyncReducer.targetedAssetCostCap
    let ids = Set((0..<(cap + 1)).map { "asset-\($0)" })
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ids, observedAt: now)

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    let timelineScope = dirty?.scope(.timeline)
    #expect(timelineScope?.pendingFullReconciliation == true)
    #expect(timelineScope?.pendingAssetIds.isEmpty == true)
  }

  @Test func photosChangedWithCollectionChangesMarksAlbumsForPlacementReconciliation() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, albums: true)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a"],
      collectionChangesPresent: true,
      observedAt: now
    )

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    #expect(dirty?.scope(.albums).pendingPlacementReconciliation == true)
    #expect(dirty?.scope(.timeline).pendingPlacementReconciliation == false)
  }

  /// Same as the `.albums` placement-reconciliation rule, but for shared albums:
  /// PhotoKit doesn't tell us which album class changed, so any collection-level
  /// mutation must mark both album-shaped scopes dirty when they're selected.
  @Test func photosChangedWithCollectionChangesMarksSharedAlbumsForReconciliation() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(sharedAlbums: true)

    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: [],
      collectionChangesPresent: true,
      observedAt: now
    )

    let (next, _) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    let dirty = next.dirtyStateByDestination[destId]
    #expect(dirty?.scope(.sharedAlbums).pendingPlacementReconciliation == true)
  }

  /// An `.autoExport(scopes)` umbrella summary clears dirty for every scope in
  /// its selection that's *still* enabled in the current state. Regression for
  /// `AutoSyncReducer.coveredScopes`'s set-intersect on the umbrella case —
  /// the user could have toggled a scope off between dispatch and completion,
  /// and the reducer must not blanket-clear scopes the user no longer wants.
  ///
  /// Setup: an autoSync run was dispatched with `[timeline, sharedAlbums]`
  /// selected. Between dispatch and completion the user turned off
  /// `.sharedAlbums`. The completion event clears `.timeline` dirty (still
  /// selected) but leaves `.sharedAlbums` dirty (no longer selected — the
  /// user's intent overrides the past dispatch).
  @Test func autoExportUmbrellaCompletionIntersectsWithCurrentSelection() {
    var state = enabledStateWithSafeDestinationAndScope()
    // Current selection: only .timeline. The dispatched run carried .timeline +
    // .sharedAlbums.
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    let destId = state.destination.id!
    var dirty = AutoSyncDirtyState.empty
    var timelineDirty = ScopeDirtyState()
    timelineDirty.pendingFullReconciliation = true
    var sharedDirty = ScopeDirtyState()
    sharedDirty.pendingFullReconciliation = true
    dirty.setScope(.timeline, timelineDirty)
    dirty.setScope(.sharedAlbums, sharedDirty)
    state.dirtyStateByDestination[destId] = dirty

    let dispatchSelection = AutoExportScopeSelection(
      timeline: true, sharedAlbums: true)
    let context = ExportRunContext(
      source: .autoSync,
      visibility: .background,
      scope: .autoExport(dispatchSelection),
      selection: state.versionSelection,
      startedAt: now
    )
    let summary = ExportRunSummary(
      context: context, endedAt: now, enqueuedCount: 1, completedCount: 1,
      failedCount: 0, skippedCount: 0, cancelReason: nil, result: .completed)

    // `autoSyncRunCompleted` is the autoSync-source counterpart of
    // `manualFullExportCompleted`; both route through the same `coveredScopes`
    // helper but the autoSync variant is where the umbrella matters in
    // production.
    let (next, _) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: state, now: now)
    let nextDirty = next.dirtyStateByDestination[destId]

    // .timeline cleared (still selected); .sharedAlbums preserved (user
    // toggled it off between dispatch and completion).
    #expect(nextDirty?.scope(.timeline).pendingFullReconciliation == false)
    #expect(nextDirty?.scope(.sharedAlbums).pendingFullReconciliation == true)
  }

  /// A completed manual `.allSharedAlbumsFull` run clears the `.sharedAlbums`
  /// scope's dirty state but leaves `.albums` and other scopes untouched. Regression
  /// guard for the `coveredScopes` mapping.
  @Test func manualSharedAlbumsRunClearsSharedAlbumsDirtyOnly() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(albums: true, sharedAlbums: true)
    let destId = state.destination.id!
    var dirty = AutoSyncDirtyState.empty
    var albumsDirty = ScopeDirtyState()
    albumsDirty.pendingFullReconciliation = true
    var sharedDirty = ScopeDirtyState()
    sharedDirty.pendingFullReconciliation = true
    dirty.setScope(.albums, albumsDirty)
    dirty.setScope(.sharedAlbums, sharedDirty)
    state.dirtyStateByDestination[destId] = dirty

    let context = ExportRunContext(
      source: .manual,
      visibility: .userVisible,
      scope: .allSharedAlbumsFull,
      selection: state.versionSelection,
      startedAt: now
    )
    let summary = ExportRunSummary(
      context: context,
      endedAt: now,
      enqueuedCount: 1,
      completedCount: 1,
      failedCount: 0,
      skippedCount: 0,
      cancelReason: nil,
      result: .completed
    )

    let (next, _) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let nextDirty = next.dirtyStateByDestination[destId]
    #expect(nextDirty?.scope(.sharedAlbums).pendingFullReconciliation == false)
    #expect(nextDirty?.scope(.albums).pendingFullReconciliation == true)
  }

  @Test func photosChangedAdvancesTokenWhenEventCarriesOne() {
    let state = enabledStateWithSafeDestinationAndScope()
    let token = Data([0x01, 0x02, 0x03])
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a"], observedAt: now, nextToken: token)

    let (_, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    #expect(effects.contains(.advancePersistentChangeToken(token, destinationId: destId)))
  }

  // MARK: - Regression: review-round bug fixes

  /// Codex P1: photosChanged arriving while .running used to be lost. Dirty was
  /// persisted and triggerReason set, but the .running branch returned early before
  /// scheduling. On run completion, triggerReason was nil and the reducer dropped
  /// to .idle, abandoning the new dirty work.
  @Test func photosChangedDuringRunSchedulesAfterCompletion() {
    var state = enabledStateWithSafeDestinationAndScope()
    let runContext = ExportRunContext(
      source: .autoSync, visibility: .background, reason: .appLaunch,
      scope: .autoExport(state.scopeSelection), selection: state.versionSelection)
    state.exportRunState = ExportRunState(
      activeContext: runContext, isManualActive: false, isAutoSyncActive: true)
    state.current = .running(reason: .appLaunch)

    // Photos change arrives mid-run.
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["mid-run-asset"], observedAt: now)
    let (afterPhotos, _) = AutoSyncReducer.reduce(
      .photosChanged(event), in: state, now: now)
    #expect(afterPhotos.current == .running(reason: .appLaunch))
    let destId = state.destination.id!
    #expect(
      afterPhotos.dirtyStateByDestination[destId]?.scope(.timeline)
        .pendingAssetIds == ["mid-run-asset"])

    // Run completes successfully — autoSyncRunCompleted clears dirty + persists summary.
    let summary = ExportRunSummary(
      context: runContext, endedAt: now,
      enqueuedCount: 1, completedCount: 1, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed)
    let (afterCompletion, effects) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: afterPhotos, now: now)
    // Dirty cleared by the run-completion handler (.completed result).
    #expect(afterCompletion.dirtyStateByDestination[destId]?.scope(.timeline).isEmpty == true)
    // persistDirtyState + persistRunSummary were emitted during the clear.
    #expect(
      effects.contains(where: { effect in
        if case .persistDirtyState = effect { return true } else { return false }
      }))
  }

  /// Codex P2: non-dirty triggers (appLaunch, scope change, version change) used
  /// to be silently lost when they arrived while AutoSync was waiting on import or
  /// a manual export. The pendingTriggerReason field preserves them; the resume
  /// hook fires the saved trigger when the blocker resolves.
  @Test func scopeChangeWhileImportingResumesAfterImportCompletes() {
    var state = AutoSyncReducer.State.initial
    state.enabled = true
    state.destination = safeDestination()
    state.scopeSelection = AutoExportScopeSelection(timeline: true)
    state.importActive = true
    state.current = .waiting(.importActive)

    // User adds a new scope while import is running. With my fix, the trigger is
    // saved as pendingTriggerReason; recompute lands in .waiting (blocked).
    let (afterScope, scopeEffects) = AutoSyncReducer.reduce(
      .scopeSelectionChanged(AutoExportScopeSelection(timeline: true, favorites: true)),
      in: state, now: now)
    #expect(afterScope.current == .waiting(.importActive))
    #expect(afterScope.pendingTriggerReason == .scopeSelectionChanged)
    // No schedule effects — we're still waiting.
    #expect(
      !scopeEffects.contains(where: {
        if case .scheduleDebounce = $0 { return true } else { return false }
      }))

    // Import finishes. Resume hook should re-fire the saved trigger.
    let (afterImport, importEffects) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: false), in: afterScope, now: now)

    let fireAt = now.addingTimeInterval(2)  // .scopeSelectionChanged delay
    #expect(afterImport.current == .scheduled(reason: .scopeSelectionChanged, fireAt: fireAt))
    #expect(afterImport.pendingTriggerReason == nil)  // consumed
    #expect(importEffects.contains(.scheduleDebounce(.scopeSelectionChanged, fireAt: fireAt)))
  }

  /// Codex P1: a failed/cancelled/interrupted run must NOT clear dirty state —
  /// pending IDs need to remain queued for retry.
  @Test func failedRunPreservesDirtyState() {
    var state = enabledStateWithSafeDestinationAndScope()
    let runContext = ExportRunContext(
      source: .autoSync, visibility: .background, reason: .appLaunch,
      scope: .autoExport(state.scopeSelection), selection: state.versionSelection)
    state.current = .running(reason: .appLaunch)
    let destId = state.destination.id!
    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("preserve-me", costCap: 500)
    var dirty = AutoSyncDirtyState()
    dirty.setScope(.timeline, scope)
    state.dirtyStateByDestination[destId] = dirty

    let summary = ExportRunSummary(
      context: runContext, endedAt: now,
      enqueuedCount: 1, completedCount: 0, failedCount: 1, skippedCount: 0,
      cancelReason: nil, result: .failed)
    let (next, effects) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: state, now: now)

    #expect(
      next.dirtyStateByDestination[destId]?.scope(.timeline).pendingAssetIds == ["preserve-me"])
    // persistRunSummary fires; persistDirtyState does NOT (no mutation).
    #expect(
      effects.contains(where: { effect in
        if case .persistRunSummary = effect { return true } else { return false }
      }))
    #expect(
      !effects.contains(where: { effect in
        if case .persistDirtyState = effect { return true } else { return false }
      }))
  }

  @Test func cancelledAndInterruptedRunsPreserveDirtyState() {
    let runContext = ExportRunContext(
      source: .autoSync, visibility: .background, reason: .appLaunch,
      scope: .autoExport(AutoExportScopeSelection(timeline: true)), selection: .edited)

    for result in [ExportRunResult.cancelled, .interrupted] {
      var state = enabledStateWithSafeDestinationAndScope()
      let destId = state.destination.id!
      var scope = ScopeDirtyState()
      scope.recordPendingAssetId("preserve-me", costCap: 500)
      var dirty = AutoSyncDirtyState()
      dirty.setScope(.timeline, scope)
      state.dirtyStateByDestination[destId] = dirty

      let summary = ExportRunSummary(
        context: runContext, endedAt: now,
        enqueuedCount: 0, completedCount: 0, failedCount: 0, skippedCount: 0,
        cancelReason: nil, result: result)
      let (next, _) = AutoSyncReducer.reduce(
        .autoSyncRunCompleted(summary), in: state, now: now)

      #expect(
        next.dirtyStateByDestination[destId]?.scope(.timeline).pendingAssetIds == ["preserve-me"],
        "Expected dirty preserved for \(result)")
    }
  }

  /// Codex P1: if photosChanged accumulates dirty BEFORE a run starts (e.g. during
  /// import or while waiting on destination), and the blocker resolves with dirty
  /// still present, schedule a debounce so the work doesn't sit forever.
  @Test func resumeFromImportSchedulesWhenDirtyExists() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.importActive = true
    state.current = .waiting(.importActive)
    let destId = state.destination.id!
    var dirty = AutoSyncDirtyState()
    var scope = ScopeDirtyState()
    scope.recordPendingAssetId("pending-during-import", costCap: 500)
    dirty.setScope(.timeline, scope)
    state.dirtyStateByDestination[destId] = dirty

    let (next, effects) = AutoSyncReducer.reduce(
      .importStateChanged(isImporting: false), in: state, now: now)

    let fireAt = now.addingTimeInterval(30)
    #expect(next.current == .scheduled(reason: .photosChanged, fireAt: fireAt))
    #expect(effects.contains(.scheduleDebounce(.photosChanged, fireAt: fireAt)))
  }

  /// Codex P1: a debounce firing while a manual export is active must NOT start a
  /// run — single-active-run gate. environmentAllowsRun checks `!isManualActive`.
  @Test func manualExportActiveBlocksAutoSyncRun() {
    var state = enabledStateWithSafeDestinationAndScope()
    let manualContext = ExportRunContext(
      source: .manual, visibility: .userVisible,
      scope: .timelineFullLibrary, selection: .edited)
    state.exportRunState = ExportRunState(
      activeContext: manualContext, isManualActive: true, isAutoSyncActive: false)
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let (next, effects) = AutoSyncReducer.reduce(
      .debounceFired(.appLaunch), in: state, now: now.addingTimeInterval(10))

    // No startRun emitted — gate refused. State should reflect the manual block.
    #expect(
      !effects.contains(where: { effect in
        if case .startRun = effect { return true } else { return false }
      }))
  }

  /// Regression for the issue-#69-era crash: a multi-scope AutoSync fan-out
  /// holds `activeRunContext` across scopes. The work-preservation hook can
  /// land the reducer back in `.scheduled` while scope #2's `runExport` is
  /// still suspended (its `activeRunContext` is set). A subsequent
  /// `debounceFired` must NOT emit `.startRun` in that window — doing so trips
  /// `ExportManager.runExport`'s "at most one active run" precondition. The
  /// gate is `environmentAllowsRun` checking `!isAutoSyncActive`.
  @Test func autoSyncRunInFlightBlocksDebounceFiredFromStartingNewRun() {
    var state = enabledStateWithSafeDestinationAndScope()
    let autoSyncContext = ExportRunContext(
      source: .autoSync, visibility: .background,
      scope: .favoritesFull, selection: .edited)
    state.exportRunState = ExportRunState(
      activeContext: autoSyncContext, isManualActive: false, isAutoSyncActive: true)
    state.current = .scheduled(reason: .photosChanged, fireAt: now.addingTimeInterval(30))

    let (_, effects) = AutoSyncReducer.reduce(
      .debounceFired(.photosChanged), in: state, now: now.addingTimeInterval(30))

    #expect(
      !effects.contains(where: { effect in
        if case .startRun = effect { return true } else { return false }
      }),
      "debounceFired while an AutoSync run is in flight must not start a second run")
  }

  /// When a manual export starts, AutoSync transitions to `.waiting(.manualExportActive)`
  /// and any active debounce is cancelled.
  @Test func manualExportActiveTransitionsToWaiting() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let manualContext = ExportRunContext(
      source: .manual, visibility: .userVisible,
      scope: .timelineFullLibrary, selection: .edited)
    let manualRunState = ExportRunState(
      activeContext: manualContext, isManualActive: true, isAutoSyncActive: false)
    let (next, effects) = AutoSyncReducer.reduce(
      .exportRunStateChanged(manualRunState), in: state, now: now)

    #expect(next.current == .waiting(.manualExportActive))
    #expect(effects.contains(.cancelDebounce(.appLaunch)))
  }

  /// Reducer agent #1: enabledChanged(true) must guard against state.enabled == true.
  /// A republished settings observation should not cancel-and-replace an active
  /// debounce.
  @Test func enabledChangedTrueWhileAlreadyEnabledIsNoOp() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let (next, effects) = AutoSyncReducer.reduce(
      .enabledChanged(true), in: state, now: now)

    #expect(next.current == state.current)
    #expect(effects.isEmpty)
  }

  /// Reducer agent #3: destinationChanged with an identical snapshot must not fire a
  /// redundant `.destinationSelected` schedule.
  @Test func destinationChangedWithIdenticalSnapshotIsNoOp() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .scheduled(
      reason: .appLaunch, fireAt: now.addingTimeInterval(10))

    let (next, effects) = AutoSyncReducer.reduce(
      .destinationChanged(state.destination), in: state, now: now)

    #expect(next.current == state.current)
    #expect(effects.isEmpty)
  }

  /// Codex P2: photosChanged with only deleted ids and no collection signal
  /// must not schedule a run — deleted IDs are non-export work.
  @Test func deletedOnlyPhotosChangeDoesNotScheduleRun() {
    let state = enabledStateWithSafeDestinationAndScope()
    let event = PhotoLibraryPersistentChangeEvent(
      deletedLocalIdentifiers: ["deleted-1", "deleted-2"], observedAt: now)

    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.current == .idle)  // No schedule.
    #expect(
      !effects.contains(where: { effect in
        if case .scheduleDebounce(.photosChanged, _) = effect { return true } else { return false }
      }))
  }

  /// Codex P2: collection-only changes when Albums is NOT selected must not schedule
  /// — there's nothing in scope that needs reconciliation.
  @Test func collectionOnlyChangeWithoutAlbumsScopeDoesNotScheduleRun() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(timeline: true)  // Albums OFF

    let event = PhotoLibraryPersistentChangeEvent(
      collectionChangesPresent: true, observedAt: now)
    let (next, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    #expect(next.current == .idle)
    #expect(
      !effects.contains(where: { effect in
        if case .scheduleDebounce(.photosChanged, _) = effect { return true } else { return false }
      }))
  }

  /// Token must still advance even when the event produces no export work — the
  /// cursor needs to move so we don't refetch the same range.
  @Test func tokenAdvancesEvenForNoOpEvents() {
    let state = enabledStateWithSafeDestinationAndScope()
    let token = Data([0xAA, 0xBB])
    let event = PhotoLibraryPersistentChangeEvent(
      deletedLocalIdentifiers: ["d"], observedAt: now, nextToken: token)

    let (_, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    #expect(effects.contains(.advancePersistentChangeToken(token, destinationId: destId)))
  }

  // MARK: - photosChangeFetchFailed → fallback

  @Test func tokenExpiredSchedulesFallbackReconciliation() {
    let state = enabledStateWithSafeDestinationAndScope()

    let (next, effects) = AutoSyncReducer.reduce(
      .photosChangeFetchFailed(.tokenExpired), in: state, now: now)

    let fireAt = now.addingTimeInterval(120)
    #expect(next.current == .scheduled(reason: .photosChangeFallback, fireAt: fireAt))
    #expect(effects.contains(.scheduleDebounce(.photosChangeFallback, fireAt: fireAt)))

    let destId = state.destination.id!
    #expect(
      next.dirtyStateByDestination[destId]?.scope(.timeline).pendingFullReconciliation == true)
  }

  @Test func tokenInvalidAndDetailsUnavailableAlsoScheduleFallback() {
    let state = enabledStateWithSafeDestinationAndScope()

    for failure in [
      PhotoLibraryPersistentChangeFetchError.tokenInvalid,
      .detailsUnavailable,
    ] {
      let (next, effects) = AutoSyncReducer.reduce(
        .photosChangeFetchFailed(failure), in: state, now: now)

      let fireAt = now.addingTimeInterval(120)
      #expect(
        next.current == .scheduled(reason: .photosChangeFallback, fireAt: fireAt),
        "Expected fallback schedule for \(failure)")
      #expect(effects.contains(.scheduleDebounce(.photosChangeFallback, fireAt: fireAt)))
    }
  }

  @Test func fetchFailedWhenDisabledIsIgnored() {
    let state = AutoSyncReducer.State.initial  // enabled = false

    let (next, effects) = AutoSyncReducer.reduce(
      .photosChangeFetchFailed(.tokenExpired), in: state, now: now)

    #expect(next.current == .disabled)
    #expect(effects.isEmpty)
  }

  // MARK: - Effect ordering contract (plan: persist before token advance)

  /// Plan §"Photo Library Changes": "Advance the token only after a dirty event has
  /// been durably recorded." The reducer returns persistDirtyState BEFORE
  /// advancePersistentChangeToken in the effects list; the runner is required to
  /// process effects in list order. Pinned by exact equality (not `.contains`).
  @Test func photosChangedEmitsPersistBeforeTokenAdvance() {
    let state = enabledStateWithSafeDestinationAndScope()
    let token = Data([0x01])
    let event = PhotoLibraryPersistentChangeEvent(
      insertedLocalIdentifiers: ["a"], observedAt: now, nextToken: token)

    let (_, effects) = AutoSyncReducer.reduce(.photosChanged(event), in: state, now: now)

    let destId = state.destination.id!
    // Find the indices to assert order without depending on the schedule effect's position.
    let persistIdx = effects.firstIndex(where: { effect in
      if case .persistDirtyState(_, let did) = effect, did == destId { return true }
      return false
    })
    let tokenIdx = effects.firstIndex(where: { effect in
      if case .advancePersistentChangeToken(_, let did) = effect, did == destId { return true }
      return false
    })
    #expect(persistIdx != nil)
    #expect(tokenIdx != nil)
    if let persistIdx, let tokenIdx {
      #expect(
        persistIdx < tokenIdx, "persistDirtyState must come before advancePersistentChangeToken")
    }
  }

  // MARK: - Idempotence (plan §"State Reducer" dispatch contract)

  @Test func sameEventAppliedTwiceIsIdempotentForCurrentState() {
    let state = enabledStateWithSafeDestinationAndScope()
    let event = AutoSyncEvent.scopeSelectionChanged(
      AutoExportScopeSelection(timeline: true, favorites: true))

    let (first, _) = AutoSyncReducer.reduce(event, in: state, now: now)
    let (second, _) = AutoSyncReducer.reduce(event, in: first, now: now)

    #expect(first.current == second.current)
    #expect(first.scopeSelection == second.scopeSelection)
  }

  // MARK: - Unhandled events do not crash

  @Test func eventsNotYetWiredDoNotCrash() {
    var state = enabledStateWithSafeDestinationAndScope()
    state.current = .idle  // Pin current so we can compare against the reducer's output.

    let unhandledEvents: [AutoSyncEvent] = [
      .retryTimerFired
    ]

    for event in unhandledEvents {
      let (next, effects) = AutoSyncReducer.reduce(event, in: state, now: now)
      #expect(next.current == .idle)
      #expect(effects.isEmpty)
    }
  }

  // MARK: - manualFullExportCompleted (Phase 3)

  /// Builds a manual run summary at `scope` that just completed cleanly.
  private func manualFullSummary(
    scope: ExportRunScope,
    selection: ExportVersionSelection = .edited,
    result: ExportRunResult = .completed,
    source: ExportRunSource = .manual
  ) -> ExportRunSummary {
    ExportRunSummary(
      context: ExportRunContext(
        source: source, visibility: .userVisible,
        scope: scope, selection: selection),
      endedAt: now,
      enqueuedCount: 1, completedCount: 1,
      failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: result
    )
  }

  /// Builds a state with seeded pending-asset dirty work for the given scope so a
  /// "did the full export clear it?" assertion has something to clear.
  private func stateWithDirty(
    in scope: AutoExportLibraryScope,
    selectedScopes: AutoExportScopeSelection
  ) -> AutoSyncReducer.State {
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = selectedScopes
    state.current = .idle
    let destId = state.destination.id!
    var dirty = AutoSyncDirtyState.empty
    var scopeState = dirty.scope(scope)
    _ = scopeState.recordPendingAssetId("seed-1", costCap: 100)
    scopeState.pendingFullReconciliation = true
    dirty.setScope(scope, scopeState)
    state.dirtyStateByDestination[destId] = dirty
    return state
  }

  @Test func manualTimelineFullClearsTimelineDirtyWhenSelected() {
    let state = stateWithDirty(
      in: .timeline, selectedScopes: AutoExportScopeSelection(timeline: true))
    let summary = manualFullSummary(scope: .timelineFullLibrary)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let destId = state.destination.id!
    let cleared = next.dirtyStateByDestination[destId]?.scope(.timeline)
    #expect(cleared?.pendingAssetIds.isEmpty == true)
    #expect(cleared?.pendingFullReconciliation == false)
    #expect(
      effects.contains(where: {
        if case .persistDirtyState(_, let did) = $0, did == destId { return true }
        return false
      }))
  }

  @Test func manualAllAlbumsFullClearsAlbumsDirty() {
    let state = stateWithDirty(
      in: .albums, selectedScopes: AutoExportScopeSelection(albums: true))
    let summary = manualFullSummary(scope: .allAlbumsFull)

    let (next, _) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let cleared = next.dirtyStateByDestination[state.destination.id!]?.scope(.albums)
    #expect(cleared?.pendingFullReconciliation == false)
  }

  @Test func manualFavoritesFullClearsFavoritesDirty() {
    let state = stateWithDirty(
      in: .favorites, selectedScopes: AutoExportScopeSelection(favorites: true))
    let summary = manualFullSummary(scope: .favoritesFull)

    let (next, _) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let cleared = next.dirtyStateByDestination[state.destination.id!]?.scope(.favorites)
    #expect(cleared?.pendingFullReconciliation == false)
  }

  @Test func manualFullExportFailedDoesNotClearDirty() {
    let state = stateWithDirty(
      in: .timeline, selectedScopes: AutoExportScopeSelection(timeline: true))
    let summary = manualFullSummary(scope: .timelineFullLibrary, result: .failed)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let untouched = next.dirtyStateByDestination[state.destination.id!]?.scope(.timeline)
    #expect(untouched?.pendingFullReconciliation == true)
    #expect(effects.isEmpty)
  }

  @Test func manualFullExportFromAutoSyncSourceDoesNotClearDirty() {
    // .manualFullExportCompleted carrying an autoSync-sourced summary is a misroute
    // — should not clear dirty state. (autoSyncRunCompleted is the right path.)
    let state = stateWithDirty(
      in: .timeline, selectedScopes: AutoExportScopeSelection(timeline: true))
    let summary = manualFullSummary(scope: .timelineFullLibrary, source: .autoSync)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let untouched = next.dirtyStateByDestination[state.destination.id!]?.scope(.timeline)
    #expect(untouched?.pendingFullReconciliation == true)
    #expect(effects.isEmpty)
  }

  @Test func manualFullExportSelectionMismatchDoesNotClearDirty() {
    var state = stateWithDirty(
      in: .timeline, selectedScopes: AutoExportScopeSelection(timeline: true))
    state.versionSelection = .editedWithOriginals  // current selection
    let summary = manualFullSummary(
      scope: .timelineFullLibrary, selection: .edited)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let untouched = next.dirtyStateByDestination[state.destination.id!]?.scope(.timeline)
    #expect(untouched?.pendingFullReconciliation == true)
    #expect(effects.isEmpty)
  }

  @Test func manualTargetedAssetsRunDoesNotClearDirty() {
    // Targeted runs only process the listed ids; pending assets *not* in the set
    // remain pending, so the "full reconciliation clear" rule must not fire.
    let state = stateWithDirty(
      in: .timeline, selectedScopes: AutoExportScopeSelection(timeline: true))
    let summary = manualFullSummary(scope: .timelineAssets(["seed-1"]))

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let untouched = next.dirtyStateByDestination[state.destination.id!]?.scope(.timeline)
    #expect(untouched?.pendingFullReconciliation == true)
    #expect(effects.isEmpty)
  }

  @Test func autoSyncRunCompletedWithFailuresEmitsRecordRetryFailures() {
    let state = enabledStateWithSafeDestinationAndScope()
    let destId = state.destination.id!
    let placement = ExportPlacement.timeline(year: 2025, month: 6)
    let failure = ExportRunFailureDetail(
      assetId: "asset-1", placement: placement, variant: .original,
      category: .iCloudTransient, errorSignature: "NSURLErrorDomain:-1009",
      localizedDescription: "Not connected to the internet.",
      failedAt: now)
    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .timelineFullLibrary, selection: .edited),
      endedAt: now,
      enqueuedCount: 1, completedCount: 0,
      failedCount: 1, skippedCount: 0,
      cancelReason: nil, result: .failed,
      failures: [failure]
    )

    let (_, effects) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: state, now: now)

    #expect(
      effects.contains(.recordRetryFailures([failure], destinationId: destId)))
  }

  @Test func autoSyncRunCompletedWithNoFailuresDoesNotEmitRecordRetryFailures() {
    let state = enabledStateWithSafeDestinationAndScope()
    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .timelineFullLibrary, selection: .edited),
      endedAt: now,
      enqueuedCount: 5, completedCount: 5,
      failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed
    )

    let (_, effects) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: state, now: now)

    #expect(
      !effects.contains(where: {
        if case .recordRetryFailures = $0 { return true }
        return false
      }))
  }

  @Test func autoSyncRunCompletedClearsOnlyTheScopeTheSummaryCovers() {
    // Manager fans out `.autoExport(scopes)` into per-scope full runs and
    // dispatches one autoSyncRunCompleted per scope. A timeline-only summary
    // must not touch favorites dirty — favorites' own run will handle that.
    var state = enabledStateWithSafeDestinationAndScope()
    state.scopeSelection = AutoExportScopeSelection(timeline: true, favorites: true)
    let destId = state.destination.id!
    var dirty = AutoSyncDirtyState.empty
    var timelineState = dirty.scope(.timeline)
    timelineState.pendingFullReconciliation = true
    dirty.setScope(.timeline, timelineState)
    var favoritesState = dirty.scope(.favorites)
    favoritesState.pendingFullReconciliation = true
    dirty.setScope(.favorites, favoritesState)
    state.dirtyStateByDestination[destId] = dirty

    let summary = ExportRunSummary(
      context: ExportRunContext(
        source: .autoSync, visibility: .background, reason: .appLaunch,
        scope: .timelineFullLibrary, selection: .edited),
      endedAt: now,
      enqueuedCount: 1, completedCount: 1,
      failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed
    )

    let (next, _) = AutoSyncReducer.reduce(
      .autoSyncRunCompleted(summary), in: state, now: now)

    let cleared = next.dirtyStateByDestination[destId]!
    #expect(cleared.scope(.timeline).pendingFullReconciliation == false)
    // Favorites untouched — its own per-scope run will clear it.
    #expect(cleared.scope(.favorites).pendingFullReconciliation == true)
  }

  @Test func manualFullExportClearingDirtyCancelsStaleScheduledPhotosDebounce() {
    // Scenario: a `.photosChanged` event accumulated dirty work and scheduled
    // the 30s debounce. Before the timer fires the user runs a manual full
    // timeline export. manualFullExportCompleted clears the dirty work for
    // timeline; without this guard, the recompute pass would preserve the
    // stale `.scheduled(.photosChanged, …)` and fire an export with nothing
    // to do once the timer expires.
    var state = enabledStateWithSafeDestinationAndScope()
    let destId = state.destination.id!
    let fireAt = now.addingTimeInterval(30)
    state.current = .scheduled(reason: .photosChanged, fireAt: fireAt)
    var dirty = AutoSyncDirtyState.empty
    var scopeState = dirty.scope(.timeline)
    _ = scopeState.recordPendingAssetId("seed-1", costCap: 100)
    dirty.setScope(.timeline, scopeState)
    state.dirtyStateByDestination[destId] = dirty

    let summary = manualFullSummary(scope: .timelineFullLibrary)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    #expect(next.current == .idle)
    #expect(effects.contains(.cancelDebounce(.photosChanged)))
  }

  @Test func nonPhotosScheduledDebouncePreservedAcrossManualExport() {
    // The cancel-stale-debounce path is gated to photos-related reasons. A
    // `.scheduled(.appLaunch, …)` waiting for the post-launch quiet window
    // shouldn't be cancelled by a manual export — it isn't gated on dirty
    // state.
    var state = enabledStateWithSafeDestinationAndScope()
    let destId = state.destination.id!
    let fireAt = now.addingTimeInterval(10)
    state.current = .scheduled(reason: .appLaunch, fireAt: fireAt)
    var dirty = AutoSyncDirtyState.empty
    var scopeState = dirty.scope(.timeline)
    scopeState.pendingFullReconciliation = true
    dirty.setScope(.timeline, scopeState)
    state.dirtyStateByDestination[destId] = dirty

    let summary = manualFullSummary(scope: .timelineFullLibrary)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    #expect(next.current == .scheduled(reason: .appLaunch, fireAt: fireAt))
    #expect(!effects.contains(.cancelDebounce(.appLaunch)))
  }

  @Test func manualTimelineFullDoesNotClearWhenTimelineNotSelected() {
    // User is auto-syncing favorites only; a manual *timeline* full export
    // shouldn't touch the favorites dirty state. (And it can't clear timeline,
    // since timeline isn't selected.)
    let state = stateWithDirty(
      in: .favorites, selectedScopes: AutoExportScopeSelection(favorites: true))
    let summary = manualFullSummary(scope: .timelineFullLibrary)

    let (next, effects) = AutoSyncReducer.reduce(
      .manualFullExportCompleted(summary), in: state, now: now)

    let untouched = next.dirtyStateByDestination[state.destination.id!]?.scope(.favorites)
    #expect(untouched?.pendingFullReconciliation == true)
    #expect(effects.isEmpty)
  }
}
