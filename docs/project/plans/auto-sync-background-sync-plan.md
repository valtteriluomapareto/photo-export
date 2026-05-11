# Auto-Sync and Background Sync Plan

Date: 2026-05-08
Status: In progress (last status update 2026-05-11, second snapshot)

## Implementation Status

Snapshot of where each phase stands. Update alongside the implementation — the table is the contract for "what's done"; the code is the contract for "how it's done."

| Phase | Status | Notes |
|-------|--------|-------|
| **Phase 0a** Pure Refactor Foundations | ✅ Complete | Awaitable `runExport`, fingerprint identity, lifecycle coordinator, destination loss interruption. |
| **Phase 0b** Locking and Safety | 🟡 Safety scan in | **Done:** destination safety scan + `unsafeNeedsConfirmation` state + per-destination confirmation store + UI banner / confirm dialog. **Missing:** advisory locking (still gated by the spike — multi-instance behavior remains undefined). |
| **Phase 0 Test Infrastructure** | ✅ Complete | `TestClock`, fakes for all four AutoSync protocols, in-memory dirty/retry/run-summary/per-destination-token stores. |
| **Phase 1** Photos Change Tracking | 🟡 Mostly complete | Token storage, `PHPhotoLibraryChangeObserver` adapter, three-way error mapping, dirty state with cost-cap rollover, fallback debounce, storm control all in. **Missing:** "limited-access status copy/state" — reducer has the blocked reasons but nothing dispatches them. |
| **Phase 2** AutoSync State Machine | ✅ Complete | Reducer + manager + protocols, all six publisher subscriptions, per-destination persistence (dirty / retry / lastRunSummary / lastDurablyRecordedToken). |
| **Phase 3** Retry and Run Policy | ✅ Complete | **Slice A:** `manualFullExportCompleted` clears compatible dirty. **Slice B:** failure classifier maps `Error` to `AutoSyncFailureCategory`; manager records into `AutoSyncRetryState`. **Slice C:** exponential backoff (30 s → 2 m → 10 m → 1 h → 6 h cap) + enqueue-time eligibility check skips ineligible variants as `skippedCount`. Manual retry override (UI affordance) still pending. |
| **Phase 4** UI | 🟡 Substantial progress | **Done:** Settings scene (Auto Export + Export Issues tabs, resizable, live-updating countdown), main-window status pill (always visible), menu bar item (`MenuBarExtra`), `runNow()`, migration-conflict recovery sheet, safety-confirmation banner + dialog, `Open at login` (SMAppService), manual-export confirmation sheet (supersedes AutoSync run), manual Retry action in Issues tab. **Missing:** completion/failure notifications (UNUserNotificationCenter), Dock badge, Ignore action in Issues tab, first-toggle-on hand-off, VoiceOver labels. |
| **Phase 5** Verification and Docs | ❌ Not started | Reducer-contract tests largely already exist via Phase 2 work, but the structured Phase 5 audit + docs pass hasn't been done. |

Branch tips: `auto-sync-phase-0a` (Phase 0a), `auto-sync-phase-2` (adds Phase 1 + 2), `auto-sync-phase-3` (adds Phase 3 Slice A), `auto-sync-phase-4` (cumulative tip — Phase 3 Slices A+B+C, all Phase 4 work so far).

## Summary

Simple auto-sync is feasible without a new process, but it should not be implemented as "call `startExportAll()` whenever something changes." The safe version needs a few foundations first:

- a `DestinationFingerprint` value type wrapping the existing stable `destinationId` so identity-confidence and migration-conflict are first-class instead of implicit,
- an awaitable export-run API with run context, export scope, and result reporting,
- Photos persistent-change tracking that drives targeted asset re-evaluation where possible,
- an auto-sync state reducer with a pure `reduce(event, state) -> (state, [effect])` surface so timing and side effects are testable without wall-clock waits,
- per-record-store and per-destination advisory locking validated under sandboxed direct *and* App Store builds (treated as a required spike, not an assumed primitive),
- injectable `Clock` plumbed through `ExportManager`, `ExportDestinationManager`, and `AutoSyncManager` so debounce, retry, and run-gating behavior are unit-testable,
- retry/backoff and destination-unavailable behavior that are distinct from manual cancel.

The chosen background-sync path is two-step: launch-at-login (`SMAppService.mainApp`) ships with MVP so Auto Export runs whenever the user is logged in, and a LaunchAgent (`SMAppService.agent(plistName:)`) ships in a later version for true closed-app coverage. The login-item helper option is intentionally skipped — it would force IPC and App Group migration without buying closed-app coverage that the LaunchAgent does not already provide.

The product model is **Auto Export** as an explicit operating mode, not a hidden background behavior. The main window exposes a simple "Enable Auto Export" toggle; the detailed configuration belongs in a native macOS Settings window. Manual export actions remain enabled while Auto Export is on, but they route through the same single-active-run gate as automatic runs: starting a manual export while an Auto Export run is active prompts the user to run the manual export now (cancelling the auto run with explicit cause) and re-evaluate Auto Export afterward. This matches the additive pattern Apple uses (Time Machine *Back Up Now* alongside *Back Up Automatically*; Photos *Import* alongside *iCloud Photos*). The app still exposes Auto Export-specific controls for status, Export Now, pause/cancel where supported, and issue recovery.

User-facing terminology is fixed: **Auto Export** for the mode, **Export Now** for the on-demand action. "Sync" is reserved for internal/code identifiers because the feature is one-way export, not bidirectional reconciliation.

## Current App Fit

The app already has useful building blocks:

- `ExportManager` can scan the library and enqueue only missing required variants for the current destination and version selection.
- `ExportDestinationManager` restores a security-scoped bookmark, validates reachability/writability, and observes `NSWorkspace.didMountNotification` / `NSWorkspace.didUnmountNotification`.
- `PhotoLibraryManager` registers as a `PHPhotoLibraryChangeObserver`, but currently only invalidates caches when the library changes.
- `ExportRecordStore` and `CollectionExportRecordStore` isolate timeline and collection export history by destination and recover interrupted in-progress variants after restart.

The current APIs are not enough for auto-sync as-is:

- `ExportManager.startExportAll()` is fire-and-forget, user-visible, and mutates toolbar/progress state. Auto-sync needs a run context and an awaitable result.
- `destinationId` was previously derived from bookmark data (which can change when a stale bookmark is re-saved). The collections-export Phase 0 work replaced this with a hash of `volumeUUID || U+0000 || volumeRelativePath`, so the same folder produces the same id across stale-bookmark refreshes; auto-sync should adopt this `destinationId` directly rather than re-derive it from bookmarks.
- `PHPhotoLibraryChangeObserver` can fire for many changes that do not require a library-wide export scan. Auto-sync needs persistent-change tracking, targeted asset re-evaluation, and backpressure before it falls back to full reconciliation. Note: the collections feature now also surfaces a `PhotoLibraryManager.libraryRevision` published counter and a `CollectionCountCache` actor that is invalidated on the same observer callback — both are useful prior art for auto-sync's targeted invalidation work.

## Scope for Simple Auto-Sync

### Goals

- Add explicit user opt-in for automatic export.
- Automatically export missing assets when:
  - the app launches and the saved destination is available,
  - the selected destination becomes reachable/writable again,
  - Photos reports inserted or updated asset identifiers,
  - a destination is newly selected and passes safety checks,
  - the selected auto-export scopes change in a way that creates new required work,
  - the export-version selection changes in a way that creates new required work.
- Let the user choose which surfaces Auto Export maintains:
  - Timeline (`YYYY/MM/`),
  - Favorites (`Collections/Favorites/`),
  - Albums (`Collections/Albums/...`, all surfaced user albums).
- Reuse the existing timeline and collection record stores so auto-sync never overwrites existing files and only exports missing required variants.
- Keep manual export actions available while Auto Export is enabled. Both manual and automatic runs go through the same single-active-run gate; if the user starts a manual export while an automatic run is in flight, prompt to supersede the auto run.
- Keep Auto Export status and progress separate from manual toolbar messages so background/no-op runs do not flash manual "already exported" banners.
- Make automatic runs observable through `os.Logger`, compact UI state, and persisted last-run summaries.
- Keep the first version process-local: launch-at-login is allowed (same main app, started at login), but no helper, no LaunchAgent, no closed-app wakeup.

### Non-Goals

- Running after the user quits the app.
- Waking the app when no app/helper process is running.
- Detecting whether an already-exported edited photo changed and replacing the prior export.
- Building a conflict-resolution system for deleted, moved, or manually edited destination files.
- Automatically deleting files when an asset is removed from Favorites, removed from an album, or deleted from Photos.
- Per-album Auto Export selection in MVP. The first version uses one "Albums" scope that covers all surfaced user albums; per-album include/exclude can be added later if the Settings UI needs it.
- Adding a cloud-backup service or networking.
- Using `BGTaskScheduler`; the macOS SDK marks the BackgroundTasks scheduler unavailable on macOS.
- Preventing iCloud downloads or gating on network type. Automatic export is expected to download originals when PhotoKit needs to fetch them.

### Safety Invariants

These are load-bearing rules for the entire app, not just auto-sync. Future features must argue against them explicitly to override.

- **The app does not delete user-visible files.** It does not delete exported files on the destination drive, and it does not mutate the user's Photos library (read-only Photos access enforced by entitlement). This holds for every flow: re-exports use collision-suffixed filenames rather than overwriting, Import is a reconcile-from-destination rebuild rather than a sync-down, cancellation only stops new work, and destination switches never touch the prior destination.
- **The only files the app removes are internal:** atomic-write `.tmp` siblings before rename to the real filename; JSONL log compaction debris; and per-destination AutoSync metadata files (`dirtyState.json`, `retryState.json`, `lastRunSummary.json`, `lastDurablyRecordedToken.data`) when the user explicitly clears state from settings. None of these are user content.
- **When destination state blocks app functionality, the resolution path is user action, not app cleanup.** A non-empty destination with no matching records → user confirms "use this destination's contents as-is" via the safety scan UX. A migration conflict between legacy and current ID directories → user picks which records to keep (or runs Import to reconcile from the destination's actual contents) before the app GCs the redundant *internal* directory. The app surfaces the conflict, the user resolves it; the app does not silently choose for them.
- "Automatically deleting files when an asset is removed from Favorites, removed from an album, or deleted from Photos" (already a Non-Goal above) is a special case of this invariant. It is listed separately because it is the most natural feature a contributor might propose adding; the broader invariant rules out the entire class.

## Product Behavior

### User-Facing Model

Add a main-window mode toggle:

> Enable Auto Export

Recommended default: off.

When enabled, the app exports to the currently selected destination using the configured Auto Export scopes and the existing export-version setting:

- `Edited` mode: one user-visible version per asset.
- `Edited with originals` mode: edited assets also get the `_orig` companion.

Auto Export scopes:

- `Timeline`: maintain the normal `YYYY/MM/` library export.
- `Favorites`: maintain the synthetic Favorites export under `Collections/Favorites/`.
- `Albums`: maintain every surfaced user album under `Collections/Albums/...`.

At least one scope must be selected before Auto Export can be enabled. If the user disables every scope in Settings while Auto Export is enabled, Auto Export enters a blocked `noScopesSelected` state and does not run until a scope is selected again.

Manual export actions remain enabled when Auto Export is on. The single-active-run gate (see "Run Ownership Model") guarantees one run at a time: if the user invokes Export Month/Year/All/Favorites/Album while an automatic run is active, the app shows a sheet — *"Auto Export is running. Run this export now and resume Auto Export afterward?"* — and on confirm the automatic run is superseded with `cancelReason: .supersededByManualRun`. After the manual run finishes, the auto-sync reducer re-evaluates and schedules another run if work is still pending. The app exposes Auto Export-specific actions in addition to the existing manual ones:

- `Export Now` (formerly "Sync Now"),
- pause or cancel the current automatic run if the implementation supports those controls,
- open Export Issues for failures that require user action,
- disable Auto Export.

`Include originals` remains a configuration input rather than a manual export action. Changing it while Auto Export is enabled schedules a reconciliation for the selected scopes after the normal debounce.

If the destination is disconnected, auto-sync waits. When the drive containing the selected destination is mounted again and the folder is reachable/writable, auto-sync schedules a run after a short debounce.

If Photos access is limited, auto-sync applies only to the visible limited library. Settings/status copy must say this explicitly; "new photos" means new photos visible to this app. Detection is straightforward: `PHPhotoLibrary.authorizationStatus(for: .readWrite)` reports `.limited` distinctly from `.authorized`, and `PHPhotoLibraryChangeObserver` fires when the user expands or narrows the selection. The total size of the user's actual library is intentionally not exposed by Apple, so copy must avoid implying we can quantify the gap.

Expanding limited Photos access on macOS is done by the user in System Settings → Privacy & Security → Photos. macOS does not expose the iOS `presentLimitedLibraryPicker(from:)` API — `PhotosUI/PHPhotoLibrary+PhotosUISupport.h` is iOS / visionOS only. The app must therefore deep-link to System Settings rather than offering an in-app picker; auto-sync never invokes a picker because there is none to invoke.

A non-empty limited library should run Auto Export normally with the limited-access notice visible — blocking on `limitedPhotosAccess` is reserved for the case where the limited set is empty (nothing visible to export). Limited access is a deliberate user choice, not an error state.

Auto-sync may download originals from iCloud because the export feature is intended to produce a complete local backup. This is allowed regardless of the current connectivity type. Do not add Wi-Fi-only, hotspot, low-data-mode, or destination-type gates in MVP. State this in settings/docs, but treat it as expected behavior rather than a blocker.

### Settings UX

Use a native macOS `Settings` scene with tabs, similar in shape to Mail settings. Do not build settings as an in-window navigation destination.

Initial tabs:

- **Auto Export**: master enable state, scope checkboxes (`Timeline`, `Favorites`, `Albums`), current destination summary, limited-library notice (see below), iCloud-download copy, last run summary, and `Export Now`.
- **Export Issues**: automatic export failures grouped by destination/scope/asset, retry status, next eligible retry time, actions to retry, ignore/suppress an issue, or reveal diagnostics. This tab can start sparse but should be the home for retry/ignore UX so the main window does not accumulate failure-management controls.
- **Export Options**: reserved for future configuration that is broader than Auto Export, such as more detailed version/export behavior. If there are not enough settings at first, ship the first two tabs and add this tab only when it has real controls.

The Auto Export tab gets two distinct background-related settings:

> Open Photo Export at login

Ships in MVP via `SMAppService.mainApp`. Status copy distinguishes `.enabled`, `.requiresApproval`, and `.notRegistered`/`.notFound`. Copy must be explicit that this only helps while Photo Export is running — quitting the app stops Auto Export until the next login.

`Open Photo Export at login` is an **independent** setting from Auto Export enablement; either can be on without the other. The Auto Export tab surfaces a non-blocking inline hint suggesting login launch when Auto Export is enabled but the login item is not registered, but does not auto-enable the login item.

> Run Auto Export when Photo Export is closed

Ships later via a LaunchAgent. This setting must remain hidden or disabled until the LaunchAgent implementation lands. Its status copy distinguishes "registered and enabled", "requires approval", and "not registered".

### Limited-Library Notice

When `PHPhotoLibrary.authorizationStatus(for: .readWrite)` is `.limited`, the Auto Export tab shows a persistent notice above the scope checkboxes:

> **Limited Photos access.** Photo Export only sees photos you've selected to share. Auto Export covers only those photos — new photos elsewhere in your library will not be exported. Use System Settings to change which photos are shared.
>
> [Open Privacy & Security in System Settings]

- macOS does not expose `presentLimitedLibraryPicker(from:)` — that API lives in `PhotosUI/PHPhotoLibrary+PhotosUISupport.h`, which is iOS / visionOS only. The notice therefore offers a single action that opens System Settings → Privacy & Security → Photos via `x-apple.systempreferences:com.apple.preference.security?Privacy_Photos`.
- The notice updates live: registering as a `PHPhotoLibraryChangeObserver` covers both authorization-status transitions and limited-selection changes.
- Mirror a compact version of the notice in the main window when Auto Export is enabled with `.limited` access, so the gap is visible without opening Settings.
- Copy must not imply the app can count assets it cannot see; do not say "X photos hidden from Photo Export" or similar.

### Launch-at-login Behavior

When `Open Photo Export at login` is enabled and the OS launches the app at login, the app starts without showing the main window. The `NSStatusItem` (see Phase 4) is visible immediately so the user can see Auto Export status and access Export Now / Open Issues / Open Settings from the menu bar. Manual launch from Finder/Dock continues to show the main window as today.

Detection: at finish-launching time, check whether the launch was a system background launch (the launch context exposed by `SMAppService` / LaunchServices) and skip the main-window presentation when true. The activation policy stays `.regular` — the app is not an `LSUIElement`. Users can re-open the main window from the Dock or status item at any time.

While Auto Export is enabled, closing the main window keeps the app running (`applicationShouldTerminateAfterLastWindowClosed = false` for that mode) so Auto Export continues. Quitting from the application menu stops Auto Export until the next launch. Settings copy must state this trade-off so users understand that close-window ≠ quit when Auto Export is on.

### First-Run UX

Offer the setting after the user has:

1. granted Photos access,
2. selected an export destination,
3. completed the initial manual export or explicitly opted into auto-sync.

Do not silently enable auto-sync just because a destination exists.

For an existing non-empty destination with no matching record store, block automatic runs until the user imports existing backup state or confirms that this destination is safe for auto-sync. Import Existing Backup is currently timeline-oriented; if Auto Export includes Favorites or Albums and the destination already contains collection folders/files without collection records, require explicit confirmation until a collection import/adoption flow exists.

The main window's `Enable Auto Export` toggle is visible before the user has opened Settings, but the **first** time the user toggles it on, the app always opens Settings → Auto Export and leaves the toggle in an indeterminate/off state until the user confirms scopes there. This kills the "silently enabled with zero scopes" case and matches Apple's first-time-activation pattern (Time Machine *Set Up Backup Disk…*, Mail *Add Account…*). After the user has saved a valid configuration once, the toggle behaves as a true one-click switch. Toggling on while the destination is non-empty without records still requires explicit import/confirmation before any export starts.

### State Model

Keep current state separate from history.

Current state:

- `disabled`
- `waiting(reason)`
- `idle`
- `scheduled(reason, fireAt)`
- `blocked(reason)`
- `running(runId, reason)`

Reasons:

- `photosAccessMissing`
- `limitedPhotosAccess` (only when the limited set is empty; non-empty limited libraries run normally with the limited-access notice visible)
- `destinationMissing`
- `destinationUnavailable`
- `destinationUnsafe`
- `noScopesSelected`
- `manualExportActive`
- `importActive`
- `retryBackoff`

History:

- `lastRunSummary`
- `lastFailureSummary`
- `lastNoOpSummary`
- `lastRelevantPhotosChangeAt`
- `lastDestinationAvailableAt`

Do not model `lastRunCompleted` or `lastRunFailed` as current states. They are persisted summaries displayed alongside the current state.

## Phase 0: Blocking Foundations

These must land before any automatic trigger can start exports. Phase 0 splits into two sub-phases driven by where unknowns live:

- **Phase 0a (pure refactor, no sandbox surprises):** `DestinationFingerprint` value type and identity-confidence surfacing, decoupling fingerprint changes from `cancelAndClear()`, the app-bootstrap/lifecycle-coordinator move, run-context/awaitable-run API, single-active-run ownership, destination-loss interruption, and `Clock` injection through `ExportManager` / `ExportDestinationManager` / `AutoSyncManager`.
- **Phase 0b (gated by spike, may reshape design):** two-tier advisory locking (record-store + destination), making manual export and `startImport()` obey the destination lock, destination safety scan, and persisted safety/confirmation state. The advisory-lock viability spike (see "Required Spikes Before Implementation") gates this sub-phase — if `flock` does not work across sandboxed direct + App Store builds, the lock design must change before MVP acceptance criterion #13 is achievable.

### Stable Destination Identity

`ExportDestinationManager.computeDestinationId` already produces `SHA256(volumeUUID || U+0000 || volumeRelativePath)`, `ExportDestinationManager.legacyDestinationId(from:)` exists, and `ExportRecordsDirectoryCoordinator` already performs the legacy → stable rename and returns a `.conflict` result when both directories exist. The remaining work is to:

1. Promote `destinationId` derivation into a `DestinationFingerprint` value type so identity-confidence and migration-conflict are first-class instead of implicit.
2. Surface the existing `.conflict` coordinator result to the UI as a recoverable blocked state — currently it returns through the coordinator without a user-visible recovery path.
3. Decouple destination *id* changes from `ExportManager.cancelAndClear()` so a same-fingerprint stale-bookmark refresh does not interrupt active work. The unconditional cancel currently wired in `photo_exportApp.swift:53-57` is the real Phase 0 destination-wiring blocker; the App Bootstrap refactor and fingerprint-aware destination transitions are therefore the same change and must land together (both in Phase 0a).

Proposed model:

```swift
struct DestinationFingerprint: Codable, Hashable {
  let schemaVersion: Int
  let volumeUUIDString: String?
  let volumeRootPath: String?
  let relativePathFromVolumeRoot: String
  let standardizedPath: String
  let identityConfidence: DestinationIdentityConfidence
}

/// In-memory hints collected at fingerprint computation time. Never persisted —
/// `fileResourceIdentifierKey` and `volumeIdentifierKey` are not stable across launches
/// and only support same-session comparisons and diagnostics.
struct LiveDestinationIdentityHints {
  let fileResourceIdentifier: String?
  let volumeIdentifier: String?
}
```

Implementation notes:

- Read resource values for the destination folder using keys such as `volumeUUIDStringKey`, `volumeURLKey`, `canonicalPathKey`, `fileResourceIdentifierKey`, and `volumeIdentifierKey`.
- Normalize the folder URL with `standardizedFileURL`.
- Produce the record-store id from stable identity components:
  - if `volumeUUIDString` and a relative path from `volumeURLKey` are available, hash `schemaVersion + volumeUUIDString + relativePathFromVolumeRoot`,
  - otherwise fall back to the canonical/standardized path and mark the identity confidence as low.
- `fileResourceIdentifierKey` and `volumeIdentifierKey` are useful same-session comparison hints captured into `LiveDestinationIdentityHints`. They are not persistent across restarts and must not be encoded into `DestinationFingerprint` or used as the primary record-store identity.
- Keep `standardizedPath` in the fingerprint for diagnostics, display, and low-confidence fallback.
- Keep bookmark data as access material only, not identity.
- After this change, `ExportDestinationManager.destinationId` is the stable fingerprint hash. The old bookmark-data hash becomes private migration input only and should disappear from the public API.
- Store the last successful fingerprint next to the bookmark only on explicit folder selection and confirmed stale-bookmark refresh. Routine mount/unmount validation can recompute a transient fingerprint for comparison, but must not overwrite the persisted fingerprint automatically.
- If a stale bookmark is re-saved but resolves to the same fingerprint, keep the same record store.
- If a folder appears to have moved but persistent identity components still match, migrate transparently. Same-session resource identifiers can support diagnostics but are not enough on their own for durable migration.
- If the app cannot prove the new resolved folder is the same destination, block auto-sync and ask for confirmation/import.
- Low-confidence path-based identities may be used for manual export, but automatic first-run export requires an empty destination or explicit user confirmation.

Migration:

- On first launch after this change, read the saved bookmark data before any code path can resolve a stale bookmark and mutate `UserDefaults`.
- Compute the legacy destination id with the old algorithm: `SHA256(bookmarkData)`.
- Resolve the bookmark under security scope, compute the new stable fingerprint, and derive the new destination id.
- If `<storeRoot>/<legacyId>/` exists and `<storeRoot>/<newStableId>/` does not, rename/move the legacy directory to the stable id.
- If both legacy and stable directories exist, do not merge automatically. Enter a visible migration-conflict state: block auto-sync, log a diagnostic, and show recovery options in settings such as importing existing backup state, keeping the stable store, or exporting diagnostics for support.
- A migration conflict must not silently disable auto-sync forever; it needs a user-visible recovery path.

Destination transitions must be fingerprint-aware:

- A stale-bookmark refresh that resolves to the same stable fingerprint is not a true destination change.
- Same-fingerprint refreshes must not call `cancelAndClear()`, reconfigure the record store, or interrupt active work.
- Only a true stable destination id change cancels export work and reconfigures `ExportRecordStore`.
- The existing destination-id `onChange` wiring in `PhotoExportApp` must move to a coordinator-level destination snapshot that compares stable fingerprints, not raw bookmark-derived ids.

### Destination Safety Model

Define "non-empty existing backup" concretely.

Ignore:

- `.DS_Store`,
- hidden `.photo-export*` lock/metadata files,
- empty directories.

Treat as non-empty/unsafe for automatic first run:

- any non-hidden file under a `YYYY/MM/` directory,
- any non-hidden file under `Collections/Favorites/` or `Collections/Albums/`,
- any recognized image or video file under the destination root,
- any existing Photo Export sidecar/record metadata added in the future.

Detection should reuse `BackupScanner`'s `YYYY/MM` enumeration for known timeline backup layout, add a lightweight collection-folder scan for `Collections/Favorites/` and `Collections/Albums/`, and use `UniformTypeIdentifiers` for root-level image/video detection instead of maintaining a hand-written extension list. The scan only decides whether auto-sync can start automatically; it is not a replacement for the existing import/matching flow.

Persist per destination:

```swift
struct DestinationAutoSyncSafetyRecord: Codable {
  let destinationId: String
  let confirmedForAutoSyncAt: Date?
  let confirmationKind: ConfirmationKind
  let firstSeenContentSummary: DestinationContentSummary
}
```

Automatic runs are allowed only when:

- every selected auto-export scope has a configured compatible record store state, or
- the destination is empty by the rules above, or
- the user confirmed/imported the existing destination for auto-sync.

Scope-specific notes:

- `Timeline` uses `ExportRecordStore` and may be unblocked by Import Existing Backup.
- `Favorites` and `Albums` use `CollectionExportRecordStore`. Import Existing Backup does not currently adopt collection files, so pre-existing collection files require explicit confirmation unless/until a collection import flow is added.
- If only `Timeline` is selected, collection-folder contents should still be included in the safety summary but should not block timeline-only auto export after the user confirms the destination's collection contents are intentionally out of scope.

### Awaitable Export Runs

Add an export-run abstraction before wiring auto-sync.

```swift
enum ExportRunSource: String, Codable {
  case manual
  case autoSync
}

enum ExportRunVisibility: String, Codable {
  case userVisible
  case background
}

struct ExportRunContext: Equatable, Codable {
  let runId: UUID
  let source: ExportRunSource
  let visibility: ExportRunVisibility
  let reason: AutoSyncReason?
  let scope: ExportRunScope
  let selection: ExportVersionSelection
  let startedAt: Date
}

struct ExportRunSummary: Equatable, Codable {
  let context: ExportRunContext
  let endedAt: Date
  let enqueuedCount: Int
  let completedCount: Int
  let failedCount: Int
  let skippedCount: Int
  let cancelReason: ExportCancelReason?
  let result: ExportRunResult
}

enum AutoExportLibraryScope: String, Codable, CaseIterable {
  case timeline
  case favorites
  case albums
}

struct AutoExportScopeSelection: Equatable, Codable {
  var timeline: Bool
  var favorites: Bool
  var albums: Bool
}

enum ExportRunScope: Equatable, Codable {
  case timelineFullLibrary
  case timelineAssets(Set<String>)
  case favoritesFull
  case favoritesAssets(Set<String>)
  case allAlbumsFull
  case allAlbumsAssets(Set<String>)
  case autoExport(AutoExportScopeSelection)
}

/// Snapshot of the export manager's run state, observed by `AutoSyncManager` to drive
/// reducer events without polling.
struct ExportRunState: Equatable {
  let activeContext: ExportRunContext?
  let isManualActive: Bool
  let isAutoSyncActive: Bool
}
```

Export API direction:

- Add `runExport(context:) async -> ExportRunSummary`.
- Keep manual start methods as `.manual` / `.userVisible` wrappers:
  - `startExportAll()` → `.timelineFullLibrary`,
  - `startExportFavorites()` → `.favoritesFull`,
  - `startExportAllAlbums()` → `.allAlbumsFull`,
  - month/year/individual album wrappers remain user-visible manual scopes.
- Add targeted paths for asset identifiers so Photos persistent changes do not force `availableYears()` plus full-year scans for every relevant change.
- Auto Export runs use `.autoSync` / `.background` and either one `.autoExport(scopeSelection)` context or a sequence of scope-specific contexts emitted by `AutoSyncManager`. The summary must preserve which selected scopes were evaluated.
- User-visible runs may reset toolbar progress counters and show empty-run messages.
- Background runs must not clear manual toolbar messages or flash "Everything in this destination is already exported."
- Export errors currently logged internally should flow into the run summary.
- Export jobs still re-fetch descriptors/resources immediately before writing; targeted IDs are only a scheduling optimization, not a guarantee that the asset still exists or needs export.

### Run Ownership Model

MVP should use a single active run gate, not mixed per-run queues.

Rules:

- `ExportManager` has at most one active `ExportRunContext`.
- `pendingJobs`, progress counters, `currentJobAssetId`, `currentJobVariant`, and `queuedCountsByPlacementId` belong to that active run.
- `runExport(context:)` resolves when that active run reaches a terminal state: completed, failed, cancelled, interrupted-for-destination-loss, or superseded.
- Manual and auto-sync jobs are not interleaved in the same queue for MVP. Per-job `runId` ownership can be introduced later if true concurrent/mixed queues are needed.
- MVP does not add `PHAssetResourceManager` request cancellation.
- Manual export and Auto Export coexist; the single-active-run gate enforces one run at a time. If a manual export is requested while an auto-sync run is active, the app prompts the user; on confirm, the export manager waits for any in-flight write to finish or fail, supersedes the auto-sync run with `cancelReason: .supersededByManualRun`, and starts the manual run.
- If auto-sync wants to run while a manual export or import is active, `AutoSyncManager` marks itself dirty and re-evaluates after manual work drains. It does not enqueue work inside `ExportManager`.
- If another manual run is requested while a manual run is active, preserve current UI gating: reject/disable the request rather than queueing a second manual run.
- `runNow()` requested while a manual run is active follows the same dirty-and-re-evaluate path as any other auto-sync trigger: it does not supersede the manual run.
- Disabling Auto Export while an automatic run is active asks whether to stop after the current file or let the current run finish. MVP picks one default behavior (let the current file finish, then stop), but the choice must be explicit and testable.

This keeps the awaitable API honest: a run summary describes one exclusive run, not whatever happened to be in the shared queue.

### Destination Loss Interruption

Add destination-loss handling distinct from `cancelAndClear()`.

Required behavior:

- `interruptForDestinationUnavailable()` stops starting new jobs and clears in-memory auto-sync pending jobs.
- An in-flight `PHAssetResourceManager.writeData` may still complete or fail because MVP has no cancellation plumbing.
- If the in-flight write fails due to destination loss, mark it as interrupted/transient rather than permanent.
- The interrupted run resolves with `cancelReason: .destinationUnavailable`.
- Release the destination lock as part of interruption: close the lock file descriptor, remove or mark the diagnostic metadata file as stale, and persist dirty state before resolving the run summary. The OS-on-process-death release is a safety net, not the primary path.
- Persist the interrupted scope as dirty auto-sync state. When the same destination becomes available again, revalidate identity and safety, then start a fresh targeted or full reconciliation. The record store skips work already completed before interruption.
- Manual cancel remains explicit and destructive for the current queue.

## Proposed Architecture

### Protocol Boundaries

`AutoSyncManager` should depend on narrow protocols, not concrete app managers.

```swift
@MainActor
protocol AutoSyncExportRunning: AnyObject {
  var runState: ExportRunState { get }
  func runExport(context: ExportRunContext) async -> ExportRunSummary
}

@MainActor
protocol DestinationAvailabilityProviding: AnyObject {
  var destinationId: String? { get }
  var canExportNow: Bool { get }
  var identityConfidence: DestinationIdentityConfidence { get }
  var safetyState: DestinationSafetyState { get }
}

@MainActor
protocol PhotoLibraryChangeProviding: AnyObject {
  var authorizationStatus: PHAuthorizationStatus { get }
  var latestPersistentChangeEvent: PhotoLibraryPersistentChangeEvent? { get }
}

@MainActor
protocol AutoExportScopeProviding: AnyObject {
  var scopeSelection: AutoExportScopeSelection { get }
}
```

Production managers should conform directly where that keeps dependencies clean. Use adapters only when direct conformance would leak unrelated API or create awkward ownership. Tests should exercise the auto-sync policy with fake protocols, not real PhotoKit or filesystem work.

### AutoSyncManager Shape

Prefer subscription-driven re-evaluation over public "notify me this happened" entry points.

Responsibilities:

- own opt-in state,
- subscribe to source state changes,
- reduce events into `AutoSyncState`,
- debounce and coalesce triggers,
- ask the export runner to start a background run,
- persist last-run summary and per-destination auto-sync metadata.

Avoid a broad API such as `destinationAvailabilityChanged`, `photosLibraryChanged`, and `exportWorkStateChanged`. The manager should expose a small surface:

```swift
@MainActor
final class AutoSyncManager: ObservableObject {
  @Published private(set) var state: AutoSyncState
  @Published private(set) var lastRunSummary: ExportRunSummary?

  func attach(to environment: AutoSyncEnvironment)
  func setEnabled(_ enabled: Bool)
  func runNow()
}

struct AutoSyncEnvironment {
  let exportRunner: any AutoSyncExportRunning
  let destination: any DestinationAvailabilityProviding
  let photos: any PhotoLibraryChangeProviding
  let scopes: any AutoExportScopeProviding
  let timelineRecordStore: ExportRecordStore
  let collectionRecordStore: CollectionExportRecordStore
  let userDefaults: UserDefaults
  let clock: any Clock
}
```

`runNow()` (user-facing label: **Export Now**) semantics:

- Bypasses the auto-sync enabled flag and debounce delay. This makes the menu/action useful even when scheduled auto-sync is off.
- Honors Photos authorization, limited-library scope, configured Auto Export scopes, destination availability, destination safety, destination identity confidence, destination locks, and active manual/import work.
- Bypasses transient retry timers for `photoKitTransient`, `iCloudTransient`, and `unknown` failures.
- Does not bypass hard retry blockers such as `destinationPermission`, `destinationNoSpace`, `assetMissing`, or stable `resourceMissing`. Users need an explicit normal manual export or "Retry Failed" action for those.
- If a destination lock is held by another exporter, surface that to the user immediately as a UI message ("Another exporter is using this destination") rather than entering the silent `blocked(otherExporterActive)` state used for scheduled triggers.
- Uses auto-sync visibility/status, not toolbar empty-run messages.
- During an active manual run, `runNow()` defers like any other auto-sync trigger: it does not supersede the manual run.

### State Reducer

The reducer has an explicit pure signature so tests can assert state and effects from a single call:

```swift
struct AutoSyncReducer {
  static func reduce(_ event: AutoSyncEvent, in state: AutoSyncState, clock: any Clock) -> (AutoSyncState, [AutoSyncEffect])
}

enum AutoSyncEffect {
  case scheduleDebounce(AutoSyncReason, fireAt: Date)
  case cancelDebounce(AutoSyncReason)
  case scheduleRetryTimer(fireAt: Date)
  case cancelRetryTimer
  case startRun(ExportRunContext)
  case persistDirtyState(AutoSyncDirtyState, destinationId: String)
  case persistRunSummary(ExportRunSummary)
  case advancePersistentChangeToken(Data, destinationId: String)
}
```

Events:

- `enabledChanged(Bool)`
- `destinationChanged(DestinationSnapshot)` where the snapshot includes destination id, availability, identity confidence, and safety state
- `safetyStateChanged(DestinationSafetyState)` if safety is updated independently of destination identity or availability
- `photosChanged(PhotoLibraryPersistentChangeEvent)`
- `scopeSelectionChanged(AutoExportScopeSelection)`
- `versionSelectionChanged(ExportVersionSelection)`
- `exportRunStateChanged(ExportRunState)`
- `importStateChanged(isImporting: Bool)`
- `debounceFired(AutoSyncReason)`
- `retryTimerFired`
- `manualFullExportCompleted(ExportRunSummary)`

Dispatch contract:

- The reducer is invoked synchronously, once per event, with no mutation in flight.
- Effects are returned as a list and dispatched by an effect runner *after* the reducer returns.
- The effect runner serializes dispatch: only one event is in flight at a time. Events produced by an effect (e.g., `exportRunStateChanged` from `startRun`) are queued and processed after the current event's effects complete.
- Timer cancellation is itself an effect (`cancelDebounce`, `cancelRetryTimer`); the reducer never side-effects timers directly.

This keeps reducer tests as deterministic single-event-in / state+effects-out assertions, and makes property-observer-driven side effects illegal by construction.

### App Bootstrap

Do not add launch auto-sync work to `ContentView.task` or a view `.task` in `PhotoExportApp`.

Current store configuration is view-scoped and can rerun if scenes/windows are recreated. Before auto-sync, move app bootstrapping into a single app/coordinator object:

- create managers in `PhotoExportApp.init`,
- create an `AppLifecycleCoordinator` or similar process-lifetime `@StateObject`,
- configure `ExportRecordStore` once per destination identity,
- attach `AutoSyncManager` once,
- make repeated coordinator attachment idempotent so multi-window scene recreation is a no-op,
- keep views declarative and focused on presentation.

## Trigger and Debounce Rules

Use concrete debounce values by reason:

- app launch: 10 seconds after the app coordinator finishes initial destination/store configuration,
- destination selected: 3 seconds after successful validation and safety check,
- destination became available: 3 seconds after false-to-true `canExportNow`,
- auto-export scope selection changed: 2 seconds,
- export-version selection changed: 2 seconds,
- Photos persistent changes with inserted/updated asset identifiers: 30 seconds after the last relevant change,
- persistent-change token expired, details unavailable, or collection membership changes cannot be targeted cheaply: 2-minute quiet window before full reconciliation,
- manual "Export Now": no debounce after guard checks.

Backpressure:

- never run more than one auto-sync export at a time,
- if manual export/import is active, mark auto-sync dirty and re-evaluate after the work drains,
- cap full-library reconciliation from Photos-change fallback to at most once per 30 minutes. Targeted runs for inserted/updated IDs are not subject to this cap because they re-evaluate a bounded set of asset IDs,
- targeted persistent-change runs can happen more often because they re-evaluate a bounded set of asset IDs instead of scanning all years.
- album-scope reconciliation can be more expensive than timeline targeted re-evaluation; apply the full-reconciliation cap to all-albums fallback runs unless measurement proves a cheaper targeted album-membership path.

Pending reason expiry:

- `destinationBecameAvailable`, `destinationSelected`, `scopeSelectionChanged`, and `versionSelectionChanged` stay pending until handled or explicitly superseded.
- Photos-change dirty flags expire after a successful auto-sync or manual full export.
- A manual month/year/favorites/album export does not clear a full-library pending reason; it only delays re-evaluation.
- A manual full export for a scope clears pending auto-sync work only for the same destination, selection, and compatible scope. For example, manual timeline Export All clears pending `Timeline` auto export, but not pending `Favorites` or `Albums` work.

## Photo Library Changes

Persistent changes are MVP, not a later optimization.

Implementation direction:

- Token storage is split: a single **global** `currentToken` (the latest token observed by the change observer) plus a **per-destination** `lastDurablyRecordedToken` snapshot stored alongside that destination's dirty state. The global token tracks what the observer has seen; the per-destination snapshot tracks what each destination's record store and dirty state have durably consumed. Both use secure coding in App Support, not `UserDefaults`.
- The global token is global because the Photos library is the same regardless of destination. The per-destination snapshot is needed because dirty state is per-destination and switching destinations otherwise leaves the new destination's record-keeping inconsistent with the global token position.
- On first auto-sync enable for a destination, snapshot the global `currentToken` as that destination's `lastDurablyRecordedToken` and schedule one full reconciliation for every selected scope. The existing library may already contain missing assets that destination has not exported.
- When auto-sync resumes for a destination (app launch, drive reconnect, destination switch, re-enable after disable), fetch persistent changes between that destination's `lastDurablyRecordedToken` and the current global token. If the destination's token is missing or expired, schedule the bounded full-reconciliation fallback.
- A destination switch is therefore *not* a full-reconciliation forcing event by itself; it just resumes from that destination's last-known position.
- If auto-sync is disabled while the app is running, the global token may still advance (to avoid token expiration), but per-destination snapshots only advance after a successful run or no-op classification for that destination.
- On `PHPhotoLibraryChangeObserver`, fetch persistent changes since the global token, durably record dirty IDs / full-reconciliation intent for every destination whose `lastDurablyRecordedToken` is at or behind the previous global position, then advance the global token. If the app crashes between the durable record and the global-token advance, the next launch sees the same range.
- Use `changeDetailsForObjectType(.asset)` and collect `insertedLocalIdentifiers` and `updatedLocalIdentifiers`.
- For album auto export, also inspect persistent changes for collection/collection-list object types that represent album creation, deletion, rename, folder movement, or membership changes. Verify the exact PhotoKit object-type behavior during implementation; if membership changes cannot be targeted reliably, collapse to a debounced all-albums reconciliation.
- Treat deleted asset IDs as non-export work for MVP. Do not delete exported files or records automatically.
- Do not assume Photos tells us whether an asset update is "content" vs "favorite/metadata". Persistent object details expose inserted/updated/deleted identifiers, not export-byte semantics.
- For inserted/updated asset IDs, schedule targeted runs for selected scopes where targeting is reliable:
  - `Timeline` → `.timelineAssets(ids)`,
  - `Favorites` → `.favoritesAssets(ids)`, where the export path re-checks whether each asset is currently visible in Favorites and skips non-favorites,
  - `Albums` (MVP) → mark all albums dirty and schedule `.allAlbumsFull` after the album debounce. Targeted album-membership exporting (resolving which albums an asset belongs to and writing only those) is intentionally deferred past MVP — it requires PhotoKit behavior verification (see Open Risks) and the bounded all-albums path is correct, just less efficient.
- Collection-only changes are no longer always ignorable. If only `Timeline` is selected, ignore collection-only changes. If `Albums` is selected, treat album/folder membership or placement changes as pending all-albums reconciliation (MVP does not target individual albums). If `Favorites` is selected and no asset details changed, do not run Favorites unless measurement shows Photos reports favorite changes through a non-asset channel.
- Distinguish three failure modes from `fetchPersistentChanges(since:)` and route each explicitly: token-expired, token-invalid, and details-unavailable. All three reset the affected destination's `lastDurablyRecordedToken` to the current global position and schedule one bounded full reconciliation for the affected selected scopes; logs and Export Issues distinguish them so we can tell whether the OS is recycling tokens too aggressively or our handling has a bug.
- While the destination is unavailable or an auto-sync run was interrupted for destination loss, the global token may advance but the per-destination snapshot only advances after dirty IDs/full-reconciliation intent have been durably recorded for that destination. Accumulate changed asset IDs in the destination's dirty state; if the set exceeds the targeting cost limit, collapse it to one pending full reconciliation for the destination.

This avoids a full `availableYears()` / `fetchAssets()` scan for every Photos notification in the timeline case while staying honest about what the persistent-change API can and cannot prove. Album auto export is inherently less targeted until album-membership change behavior is measured; plan for a coarser debounced all-albums path first, then optimize.

Targeting rules:

- Do not ship an unjustified magic threshold. Use a tunable implementation constant backed by measurement, and prefer a cost model once enough data exists: targeted estimate = changed ID count times recent per-descriptor re-evaluation cost; full estimate = recent full-reconciliation scan cost. Collapse to full reconciliation only when targeted work is likely to be slower or when a hard safety cap is exceeded.
- Cost estimates use the median of the last 10 measurements per category and scope (`Timeline`, `Favorites`, `Albums`) to keep threshold decisions stable across noisy single samples.
- The initial hard cap should be high enough for common batch imports and vacation imports; validate it with manual/performance tests before release.
- Above the threshold/cost limit, collapse to a bounded full reconciliation for the affected selected scope, not necessarily every scope.
- If more targeted events arrive while a targeted run is active, union the ID sets and re-evaluate after the run completes.
- If a manual full export completes for the same destination, selection, and compatible scope, clear pending targeted and full-library dirty flags for that scope only.

## Destination Availability

Build on `ExportDestinationManager`'s existing `NSWorkspace` mount/unmount observers.

Changes:

- expose `refreshAvailability()` for explicit validation,
- observe `isAvailable` / `isWritable` at the auto-sync layer and detect false-to-true there,
- do not add a separate `availabilityChangeCounter`,
- include mounted volume URL/path from `NSWorkspace` notifications in logs,
- on unmount, call the destination-loss interruption path for auto-sync runs instead of `cancelAndClear()`.

Before running again after mount:

1. resolve the stored bookmark,
2. recompute the stable destination fingerprint,
3. verify it matches the interrupted run's destination id or the current configured destination id,
4. re-check safety state,
5. start a fresh reconciliation from persisted dirty state or block.

## Export-Version Changes

Changing `Include originals` is an explicit MVP trigger.

Rules:

- If auto-sync is enabled and the destination is safe, changing from `Edited` to `Edited with originals` schedules auto-sync after 2 seconds.
- Changing from `Edited with originals` to `Edited` does not delete previously exported `_orig` companions; it only changes future completion requirements.
- The run context snapshots the export-version selection and Auto Export scope selection at run start.
- Selection changes while a run is active wait until the current run drains, then re-evaluate.

## Retry and Failure Policy

Auto-sync should not retry every non-`.done` variant forever on every launch/change.

Add failure categories to the export path or an auto-sync retry store:

- `destinationUnavailable`
- `destinationPermission`
- `destinationNoSpace`
- `assetMissing`
- `resourceMissing`
- `photoKitTransient`
- `iCloudTransient`
- `unknown`

Persisted retry-state sketch:

```swift
struct AutoSyncRetryState: Codable {
  /// Outer key: scope/placement key — `"timeline"`, `"favorites"`, or `"album:<placementId>"`.
  /// Middle key: assetId. Inner key: `ExportVariant.rawValue`.
  /// Placement-first nesting is required so a failure in one album does not suppress retries
  /// for the same asset in another album, in Favorites, or in Timeline.
  var entriesByPlacement: [String: [String: [String: RetryEntry]]]
}

struct RetryEntry: Codable, Equatable {
  let category: AutoSyncFailureCategory
  let errorSignature: String
  let attemptCount: Int
  let firstFailedAt: Date
  let lastFailedAt: Date
  let nextEligibleAt: Date?
}
```

Retry counts are scoped to `scope/placement + assetId + variant + category + errorSignature`. Timeline can use a timeline scope key; collection exports need placement awareness so a failure in one album does not suppress a different album or Favorites. A materially different error signature resets the retry entry so a resolved disk-space error does not keep blocking a later transient PhotoKit failure.

Initial automatic retry policy:

- Retry `photoKitTransient`, `iCloudTransient`, and `unknown` with exponential backoff.
- Retry `destinationUnavailable` only after destination availability changes to available.
- Do not automatically retry `destinationPermission`, `destinationNoSpace`, `assetMissing`, or stable `resourceMissing` until the user runs a manual retry or the relevant state changes.
- Cap automatic attempts per scope/placement + asset + variant + error signature.
- Persist retry state per destination, scope/placement, asset, and variant.

Export Issues "Retry Failed" or a normal manual export after disabling Auto Export can override backoff.

Retry evaluation belongs at enqueue time. The export runner should ask whether each missing asset/variant is currently eligible before creating a job; ineligible variants count as `skippedCount` with a retry reason in the run summary. This keeps auto-sync from starting a run that only churns known blocked failures.

## Dirty State

Persist per-destination dirty state so accumulated work survives interruption, restart, and disable/enable cycles.

Persisted shape:

```swift
struct AutoSyncDirtyState: Codable {
  /// Keyed by `AutoExportLibraryScope.rawValue` so the persisted JSON shape stays explicit.
  var scopes: [String: ScopeDirtyState]

  var lastUpdatedAt: Date
}

struct ScopeDirtyState: Codable {
  /// Asset IDs that have a pending targeted re-evaluation for this destination/selection.
  /// Bounded by the targeting cost cap; collapses to `pendingFullReconciliation = true` when
  /// adding the next ID would exceed the cap. Inline-bounded so memory and disk size stay
  /// bounded during long unmounts.
  var pendingAssetIds: Set<String>

  /// True when a token-expired/details-unavailable fallback or an over-cap targeted set
  /// requires a bounded full reconciliation for this destination/selection/scope.
  var pendingFullReconciliation: Bool

  /// For albums, true when membership, rename, or folder changes require all-albums
  /// reconciliation rather than asset-id targeting.
  var pendingPlacementReconciliation: Bool
}
```

Bookkeeping rules:

- Adding an asset ID checks the targeting cost cap for the affected scope inline. If it would exceed, the manager replaces that scope's set with `pendingFullReconciliation = true` and clears `pendingAssetIds`.
- A successful targeted run removes its asset IDs from that scope on completion, and only records token advancement after dirty state has been written.
- A successful full reconciliation clears `pendingAssetIds`, `pendingFullReconciliation`, and `pendingPlacementReconciliation` for that scope.
- A manual full export for the same destination/selection/scope clears compatible dirty flags as part of the existing pending-reason expiry rules.
- Persistent change events that arrive while the destination is unavailable accumulate into the affected scope's `pendingAssetIds`, with the inline cap rule still applying.
- Switching the selected destination retains the previous destination's dirty state. The state is GC'd only when the destination's record store is deleted or the user explicitly clears auto-sync state from settings.

Token authority for this dirty state lives in the sibling file `lastDurablyRecordedToken.data` per destination — the dirty-state struct deliberately does not carry its own token field, so there is exactly one source of truth. The two files are written atomically as a pair: dirty-state changes are flushed first, then the token snapshot, then the global `currentToken` advances. If a crash interrupts the pair mid-write, the next launch detects inconsistency by comparing file modification timestamps and rolls back the affected destination to "force full reconciliation" rather than trusting a half-advanced token.

## Multi-Instance and Locking

Auto-sync should add locking before automatic writes.

Required locks:

- a per-record-store advisory lock around JSONL append/snapshot/compaction,
- a destination-level advisory lock such as `.photo-export.lock` under the selected export root while an export run is active.

The destination lock reduces duplicate-output risk across:

- two instances of the same app,
- direct and App Store builds pointed at the same destination,
- a future LaunchAgent plus main app, once closed-app sync ships.

If the destination lock cannot be acquired, auto-sync enters `blocked(otherExporterActive)` and retries later. Manual export should show a clearer message.

Locking design:

- Prefer POSIX advisory locks (`flock`/`fcntl`) on open file descriptors held for the lifetime of the critical section. Do not use `NSDistributedLock`; stale lock files are too easy to misinterpret.
- The record-store lock lives under the app-support record-store directory and is held for each append/compaction operation.
- The destination lock lives under the selected export root, is acquired under security-scoped access, and is held for the whole export run.
- Write diagnostic metadata into the destination lock file before locking or immediately after acquiring it: app bundle id, process id, run id, destination id, and timestamp. This is for user support only; the advisory lock is the authority.
- If the process dies, the OS releases the advisory lock. A leftover lock file without an active lock must not block future exports.
- Manual export and import should obey the same destination lock policy so automatic and manual paths have one concurrency model.

## Persistence Keys

Use namespaced keys/file names and separate global from destination-scoped state. Per-destination state lives as a sibling tree to the existing record stores (`ExportRecords/<destinationId>/...`), under `AutoSync/destinations/<destinationId>/`.

Global `UserDefaults`:

- `AutoSync.enabled`
- `AutoSync.scopeSelection`

Global App Support:

- `AutoSync.lastGlobalStateVersion`
- `AutoSync/photo-library-change-token.data` — the global `currentToken` observed by the change observer.

Per-destination App Support state:

- `AutoSync/destinations/<destinationId>/safetyRecord.json`
- `AutoSync/destinations/<destinationId>/lastRunSummary.json`
- `AutoSync/destinations/<destinationId>/retryState.json`
- `AutoSync/destinations/<destinationId>/dirtyState.json`
- `AutoSync/destinations/<destinationId>/lastDurablyRecordedToken.data` — the per-destination token snapshot used to compute persistent-change deltas after destination switches and resume.

When a destination's record store is deleted (user clears auto-sync state from settings, or the destination is removed and the user confirms the cleanup), the matching `AutoSync/destinations/<destinationId>/` directory is GC'd. The user preference lives in `UserDefaults`; persistence-critical tokens, safety records, retry state, and run metadata live in App Support.

## Power and iCloud Behavior

The current resource writer sets `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true`, and auto-sync should keep that behavior.

MVP behavior:

- automatic export is allowed to download originals from iCloud,
- do not gate on Wi-Fi, cellular/hotspot detection, Low Data Mode, or destination type,
- explain in settings/docs that automatic export may download iCloud originals,
- do not prevent system sleep,
- use `ProcessInfo.beginActivity(options: [.background, .suddenTerminationDisabled], reason:)` only while an automatic export is active, and always end the activity.

Future optional preferences can tune timing, power, or quiet hours, but they are not required for correctness. Do not add connectivity-based iCloud download blocking unless this product decision changes explicitly.

## Required Spikes Before Implementation

Two unknowns gate Phase 0 and the lock design. Schedule both as 1–3 day spikes during Phase 0a so the answers exist before Phase 0b decisions are made.

### Advisory-lock viability under sandboxed direct + App Store builds

The destination lock claim ("direct and App Store builds pointed at the same destination cannot write concurrently") only holds if both processes can `flock` the same `.photo-export.lock` file under security-scoped access. Validate:

- Both builds can create and `flock` the file at the same selected destination.
- A locked file held by one build correctly blocks the other.
- An exiting/crashing process releases the advisory lock as expected (the sandbox does not strand the FD).
- Different signing identities (Developer ID vs. App Store) do not break the cross-process semantics.

If the spike fails, the lock design must change before MVP. Likely options: a single-process model with launch-at-login serialization (drop the dual-build claim), or a coordinator process. Either changes Phase 0b substantially.

### `DestinationFingerprint` resolution on common volume formats

Validate that `volumeUUIDStringKey` and `volumeURLKey` are populated for at least:

- APFS internal storage,
- APFS external storage,
- exFAT external storage,
- a network/SMB share if the app permits selecting one.

If volume UUID is missing on common formats, the fallback path (low-confidence path-based identity) becomes the primary path on those volumes and the confirmation/import UX must ship in MVP rather than as a fallback.

## Implementation Steps

### Phase 0a: Pure Refactor Foundations

No new behavior shipped to users; these are the load-bearing refactors that the rest of the plan compiles against.

- Promote `destinationId` derivation into a `DestinationFingerprint` value type with `identityConfidence`.
- Surface the existing legacy/stable migration `.conflict` result from `ExportRecordsDirectoryCoordinator` into a recoverable blocked UI state.
- Move bootstrap and destination handling out of `WindowGroup.task` / `onChange` in `photo_exportApp.swift` into a single process-lifetime coordinator. This must land *with* fingerprint-aware destination transitions; splitting them leaves the app in a broken intermediate state.
- Make destination-change handling fingerprint-aware so same-fingerprint bookmark refreshes do not call `cancelAndClear()` or reconfigure the record store.
- Inject `Clock` into `ExportManager`, `ExportDestinationManager`, and the future `AutoSyncManager` so debounce, retry, and run-gating behavior are unit-testable without wall-clock waits.
- Add awaitable `runExport(context:) async -> ExportRunSummary`.
- Add `ExportRunContext`, `ExportRunSource`, `ExportRunVisibility`, and `ExportRunSummary`.
- Add `AutoExportLibraryScope` / `AutoExportScopeSelection`.
- Keep manual export methods as user-visible wrappers over run scopes.
- Add run scopes for timeline, favorites, all albums, and targeted asset IDs.
- Define and implement the single-active-run ownership model for `runExport`, including the manual-supersedes-auto path and the runNow-defers-to-manual path.
- Add destination-loss interruption that records dirty state and starts a fresh reconciliation after the destination returns.

### Phase 0b: Locking and Safety (gated by spike)

Cannot start until the advisory-lock spike confirms cross-build viability. If the spike fails, this sub-phase is redesigned before MVP.

- Add per-record-store and per-destination advisory locks with stale-file-safe semantics.
- Make manual export and `startImport()` acquire the same destination lock policy as auto-sync.
- Implement the destination safety scan (timeline `YYYY/MM`, `Collections/Favorites/`, `Collections/Albums/`, root-level UTType image/video detection) and persisted confirmation/import state.
- Wire `identityConfidence` into the safety gate so low-confidence path-based identities require explicit confirmation before automatic first-run export.

### Phase 0 Test Infrastructure (lands alongside 0a)

These do not exist in the codebase today and are prerequisites for the Phase 5 test list. Build them as Phase 0a lands so reducer/run-level tests are deterministic from day one.

- `TestClock` (replacing wall-clock waits in tests; production code uses an injected `Clock` via `AutoSyncEnvironment` and the export managers).
- `FakePersistentChangeSource` emitting `PhotoLibraryPersistentChangeEvent`s with fabricated tokens, expired-token errors, invalid-token errors, and details-unavailable errors.
- In-memory and temp-dir variants of `AutoSyncDirtyStateStore`, `AutoSyncRetryStateStore`, and per-destination token-snapshot storage.
- `FakeFileLocking` simulating `EWOULDBLOCK`, stale-FD-but-no-active-lock, and cross-process contention. A separate integration target exercises real `flock` between two processes.
- A PhotoKit auth-status fake covering `.notDetermined` / `.denied` / `.limited` / `.authorized` and `.limited`-selection-changed transitions.
- Fakes conforming directly to `AutoSyncExportRunning`, `DestinationAvailabilityProviding`, `PhotoLibraryChangeProviding`, and `AutoExportScopeProviding` from the protocol-boundaries section.

Existing testing patterns to reuse: `photo-exportTests/TestHelpers/AsyncCheckpoint.swift` (deterministic await), `photo-exportTests/TestHelpers/ExportManager+TestWait.swift` (sleep-free wait idiom), and the `Harness`-style temp-dir setup in `ExportManagerPauseResumeTests.swift` (suite-isolated `UserDefaults` + temp record store).

### Phase 1: Photos Change Tracking

- Add persistent-change token storage.
- Add a `PhotoLibraryPersistentChangeEvent` publisher/source.
- Classify asset inserted/updated/deleted ID sets without assuming update semantics.
- Classify collection/album change signals enough to support the `Albums` scope, falling back to debounced all-albums reconciliation when membership changes cannot be targeted.
- Add targeted asset-id scheduling per selected scope with a threshold before full reconciliation.
- Add token-expired/details-unavailable fallback to bounded full reconciliation for affected selected scopes.
- Add storm control: dirty flag, debounce, min interval for full reconciliation.
- Add limited-access status copy/state.

### Phase 2: AutoSync State Machine

- Add protocol-backed `AutoSyncManager`.
- Implement `AutoSyncState`, reasons, reducer, and effect outputs.
- Subscribe to destination, Photos, export, import, scope-selection, and version-selection state through `attach(to:)`.
- Persist global and destination-scoped auto-sync state with namespaced keys.
- Add unit tests for reducer transitions and effect decisions.

### Phase 3: Retry and Run Policy

- Add failure categories or retry-state mapping.
- Implement automatic retry backoff.
- Define manual retry override.
- Ensure auto-sync empty runs update `lastRunSummary` but do not show toolbar empty-run messages.
- Ensure manual full export clears compatible pending auto-sync work by destination, selection, and scope.

### Phase 4: UI

(App-bootstrap refactor moved into Phase 0a — it must land with fingerprint-aware destination transitions to avoid leaving the app in a broken intermediate state.)

- Instantiate and attach `AutoSyncManager` once via the lifecycle coordinator created in Phase 0a.
- Add a native macOS Settings scene with Auto Export and Export Issues tabs.
- Add main-window `Enable Auto Export` toggle. On first toggle-on, open Settings → Auto Export and leave the toggle indeterminate/off until the user confirms scopes there. After the user has saved a valid configuration once, the toggle is a true one-click switch.
- Keep manual export actions enabled while Auto Export is on; route them through the single-active-run gate with a confirmation sheet ("Auto Export is running. Run this export now and resume Auto Export afterward?").
- Show concise main-window status: waiting, scheduled, blocked, running, last run. Mirror a compact limited-library notice and a compact failure summary ("3 photos couldn't export — Review…") that links into Export Issues.
- Add an explicit `Export Now` action in Settings, the main window, and a menu command. This is the user-facing path for bypassing disabled state, debounce, and transient retry timers while still honoring safety and hard blockers.
- Group the Export Issues tab by failure category first (*Destination*, *iCloud*, *Asset missing*, *Permission*), then by scope, then by asset — matches the way Mail's Connection Doctor groups failures by account, not by message.
- Add an `NSStatusItem` (menu bar item) **in MVP** with: Enable/Disable Auto Export, Export Now, current status, Open Issues, Open Settings. Required because launch-at-login starts the app without showing the main window, and `Open Photo Export at login` ships in MVP — without a status item the user has no surface for status or Export Now in that mode.
- Schedule completion/failure notifications via `UNUserNotificationCenter`, gated by a Settings checkbox (default: failures only). Add a Dock badge for the count of unresolved issues.
- Specify VoiceOver labels for the Auto Export status pill so the announced value carries context (for example, "Auto Export waiting, destination disconnected") rather than just "waiting". Make Settings tab navigation reachable via keyboard.
- Add the `Open Photo Export at login` setting via `SMAppService.mainApp` with `.enabled`/`.requiresApproval`/`.notRegistered`/`.notFound` status reporting and a deep link to System Settings → Login Items. On first register, surface an inline explainer that macOS will post a system "'Photo Export' Added" notification, since that notification arrives without app context. On `unregister()`, poll status when the Settings window becomes key (`NSWindow.didBecomeKeyNotification`); if status remains `.enabled`, surface a "Still showing in Login Items? Open Login Items…" hint because System Settings does not notify the app.
- Leave the `Run Auto Export when Photo Export is closed` setting hidden/disabled until the LaunchAgent work lands.

### Phase 5: Verification and Docs

- Reducer-contract tests (single-event-in / state+effects-out):
  - each event type produces the documented `(State, [Effect])` from a known starting state,
  - the same event applied twice is idempotent w.r.t. effects,
  - effects produced by an event do not appear in-place — they are returned in the effect list,
  - timer cancellation is emitted as `cancelDebounce` / `cancelRetryTimer` effects, never side-effected,
  - cross-reason debounce coalescing: a 30-second photos debounce overlapping a 3-second `destinationBecameAvailable` debounce produces the documented merge/precedence outcome,
  - precedence between debounced reasons (`scopeSelectionChanged`, `versionSelectionChanged`, `destinationBecameAvailable`, `photosChanged`) is deterministic.
- Lifecycle and gating tests:
  - disabled auto-sync never runs,
  - unsafe destination blocks automatic runs,
  - stale bookmark re-save does not orphan the record store when fingerprint matches,
  - same-fingerprint bookmark refresh does not cancel active work,
  - legacy bookmark-hash store migrates by computing the old hash from saved bookmark data,
  - legacy/stable store conflict surfaces a recoverable blocked state with a user-visible recovery path,
  - manual export during active auto-sync supersedes with `cancelReason: .supersededByManualRun` and the manual run starts only after in-flight writes drain,
  - `runNow()` during an active manual run defers (dirty + re-evaluate), does not supersede,
  - `runNow()` bypasses debounce/enable state and transient retry timers, but honors safety, hard blockers (`destinationPermission`, `destinationNoSpace`, `assetMissing`, stable `resourceMissing`), and lock contention with a user-visible message,
  - destination false-to-true schedules one run,
  - destination-unavailable interrupts auto-sync with dirty state, not `cancelAndClear()`.
- Persistent-change-tracking tests:
  - collection-only Photos changes do not run export when only Timeline is selected,
  - album/folder changes schedule a bounded all-albums reconciliation when Albums is selected (MVP behavior; targeted per-album reconciliation is not implemented),
  - asset inserted/updated changes schedule targeted asset re-evaluation for selected scopes where targeting is reliable,
  - targeted IDs above the threshold/cost limit collapse to bounded full reconciliation,
  - token-expired, token-invalid, and details-unavailable each route to bounded full reconciliation distinctly (each path has its own log/issue category),
  - global token does *not* advance past a per-destination snapshot until that destination has durably recorded the matching dirty IDs (crash-recovery: durable record fails → next launch re-reads the same range),
  - destination switch resumes from that destination's per-destination token snapshot; missing/expired snapshot triggers full reconciliation,
  - Photos changes while destination is unavailable accumulate per-destination and export after reconnect,
  - corrupt token file falls back to full reconciliation without crashing,
  - Photos changes coalesce within debounce window,
  - scope-selection changes schedule reconciliation for newly enabled scopes,
  - import/manual export blocks auto-sync and re-evaluates later,
  - version-selection change schedules work.
- Retry/backoff tests:
  - each failure category is routed correctly (`destinationUnavailable`, `destinationPermission`, `destinationNoSpace`, `assetMissing`, `resourceMissing`, `photoKitTransient`, `iCloudTransient`, `unknown`),
  - `errorSignature` change resets `attemptCount` so a resolved-then-recurring error is not stuck under the previous attempt count,
  - exponential backoff fires `photoKitTransient` / `iCloudTransient` / `unknown` retries at the documented schedule,
  - `destinationUnavailable` retries only on availability transition, not on a timer,
  - `destinationPermission` / `destinationNoSpace` / `assetMissing` / stable `resourceMissing` are not retried automatically,
  - attempt cap halts further retries until manual override,
  - retry scope keys are independent across `Timeline` / `Favorites` / `Albums` and across albums (a failure in one album does not suppress retry in another or in Favorites),
  - manual "Retry Failed" or a normal manual export overrides backoff,
  - retry evaluation at enqueue time skips ineligible variants and counts them in `skippedCount` with a retry reason in the run summary.
- Dirty-state tests:
  - adding an asset ID at the targeting cost cap rolls over to `pendingFullReconciliation = true` and clears `pendingAssetIds`,
  - successful targeted run removes its IDs from the per-scope set on completion (and only after dirty state is durably written),
  - successful full reconciliation clears `pendingAssetIds`, `pendingFullReconciliation`, and `pendingPlacementReconciliation` for that scope,
  - manual full export clears compatible dirty flags only for the same destination/selection/scope,
  - dirty state for a deleted destination is GC'd when the destination's record store is removed.
- Locking tests:
  - record-store/destination lock contention blocks auto-sync (scheduled trigger → silent `blocked(otherExporterActive)`; Export Now → user-visible message),
  - stale lock file with no active advisory lock does not block future exports,
  - destination lock is released on `interruptForDestinationUnavailable` (FD closed, diagnostic metadata marked stale),
  - two FDs on the same lock from the same process serialize correctly.
- Manual tests:
  - app launch with available destination,
  - app launch with disconnected destination, then reconnect drive,
  - stale bookmark restore,
  - existing non-empty backup with no records,
  - migration conflict (legacy and stable record-store directories both exist) surfaces a recoverable blocked state,
  - enable Auto Export with Timeline only,
  - enable Auto Export with Favorites,
  - enable Auto Export with Albums,
  - attempt to enable Auto Export with no selected scopes (first-enable opens Settings → Auto Export; toggle stays off),
  - add/import a new photo while app is running,
  - toggle album order or collection metadata in Photos and verify no export run when Albums is off,
  - add a photo to an album and verify album auto export when Albums is on,
  - toggle a favorite or other asset metadata and verify at most targeted re-evaluation with no file writes when records are already complete,
  - disconnect drive mid-export, reconnect, and verify a fresh reconciliation exports remaining work,
  - toggle include-originals before auto-sync,
  - limited Photos authorization,
  - iCloud-only asset export,
  - corrupt persistent-change token file (delete or truncate file → next launch falls back to full reconciliation cleanly),
  - destination drive runs out of space mid-run (variants categorized as `destinationNoSpace`, not retried, surfaced in Export Issues),
  - OS-level Photos or Files permission revoked mid-run,
  - very large change batch (~10k inserted IDs) validates the targeting cost cap and full-reconciliation collapse,
  - simultaneous direct + App Store builds against the same destination — only one writes at a time (load-bearing for AC#13),
  - login-item approval revoked via System Settings — Settings tab status reflects the change next time the window becomes key,
  - lock left over from a force-killed prior run does not block future exports.
- Build:
  - `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
  - `xcodebuild -project photo-export.xcodeproj -scheme "photo-export" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`

When behavior changes, update:

- root `README.md`,
- `website/src/content/docs/features.md`,
- `website/src/content/docs/getting-started.md`,
- `website/src/content/docs/roadmap.md` if this replaces or refines a roadmap item.

## Open Risks To Resolve Before Implementation

The two highest-risk unknowns are tracked separately in "Required Spikes Before Implementation" — advisory-lock viability under sandbox/App Store builds, and `DestinationFingerprint` resolution on common volume formats. Both must run before Phase 0b commits.

Remaining risks:

- Define the error-category mapping table from `FileManager`, `PHAssetResourceManager`, security-scope, and PhotoKit errors to retry categories before implementing backoff. A vague `unknown` bucket should be temporary, observable, and capped.
- Benchmark targeted asset re-evaluation against full reconciliation before choosing the targeted/full cutoff. The threshold must be a tunable constant with telemetry/logging, not an unexplained number.
- Auto-exporting albums makes collection changes export-relevant. Verify how Photos persistent changes report album membership, album rename, folder movement, and favorite toggles before promising targeted behavior. If the API does not provide enough detail, ship a coarser all-albums reconciliation with clear debounce/backpressure.
- Decide how targeted export handles assets without `creationDate`. The current year/month export path effectively skips them; targeted auto-sync should either preserve that behavior with an explicit `skippedCount` reason or introduce a separate fallback folder as a deliberate product change.
- Decide how albums handle assets without `creationDate`. Collection exports do not need `YYYY/MM` placement, so the album/favorites path can export these assets even if timeline skips them; that difference should be deliberate and documented.
- Validate `ProcessInfo.beginActivity` options under real long iCloud downloads. It should reduce sudden termination during active export without promising sleep prevention.
- App Store review may ask for clarifying settings copy about what "automatic export" does and when. Opt-in plus existing Photos and user-selected entitlements should make this defensible, but budget time for review questions.

## MVP Acceptance Criteria

- Enabling auto-sync cannot create duplicate exports solely because a bookmark was refreshed (same-fingerprint refresh does not call `cancelAndClear()` and does not produce duplicate enqueues).
- An existing non-empty backup with no matching records cannot auto-export until imported or confirmed.
- Auto Export cannot be enabled with zero selected scopes; the first toggle-on always opens Settings → Auto Export.
- A Photos asset insert/update while the app is running schedules a targeted re-evaluation for selected scopes when the ID set is bounded and the scope supports targeting.
- A Photos asset inserted while the app was closed is detected on next launch through that destination's per-destination token snapshot or the bounded full-reconciliation fallback.
- A collection-only Photos change does not schedule export when only Timeline is selected.
- If Albums is selected, album-relevant changes (asset insert/update, album/folder membership/rename) schedule a bounded all-albums reconciliation in MVP. Targeted per-album reconciliation is post-MVP.
- Favorite toggles are reflected in Favorites Auto Export within the configured debounce window — the criterion is the observable behavior, not which PhotoKit channel reports the change.
- A token-expired, token-invalid, or details-unavailable failure schedules at most one bounded full reconciliation per affected destination in the configured interval, and each path is logged distinctly.
- Disconnecting the destination during an auto-sync run records transient interruption and per-destination dirty state instead of converting every remaining job into permanent failures.
- Auto-sync exposes a current state and persisted per-destination last-run summary; an automatic no-op run leaves the manual toolbar message and progress counters untouched (asserted by snapshot comparison before/after).
- A manual full export for the same destination/selection/scope clears that scope's `pendingAssetIds`, `pendingFullReconciliation`, and `pendingPlacementReconciliation` flags; pending work for other scopes is unaffected.
- Direct and App Store builds pointed at the same destination cannot write concurrently. (Verified by manual two-build test; if the advisory-lock spike fails this becomes a Phase 0b redesign criterion rather than an MVP shipping criterion.)
- A failure categorized as `destinationPermission` or `destinationNoSpace` is not retried automatically until the user takes an explicit action or the relevant state changes.
- Manual export requested during an active auto-sync run prompts to supersede; on confirm, the auto-sync run resolves with `cancelReason: .supersededByManualRun` and the manual run starts only after in-flight writes drain. Jobs from both runs are never mixed in the same `ExportRunContext`.
- `Open Photo Export at login` registers via `SMAppService.mainApp`, opens the app at login when enabled, and Settings reflects `.enabled` / `.requiresApproval` / `.notRegistered` / `.notFound` accurately after the user toggles or revokes the permission via System Settings.
- The reducer is invoked with one event at a time and returns `(State, [Effect])`; effects-from-effects are queued and processed serially. (Verified by reducer-contract tests, not via runtime sampling.)

## Complexity Estimate

After review and re-scoping:

- Required spikes (advisory locking, fingerprint resolution): 2-4 days, parallelizable with Phase 0a,
- Phase 0a foundations (refactor, no new behavior): 1-2 weeks,
- Phase 0b foundations (locking, safety scan — gated by spike outcome): ~1 week if spike succeeds; redesign cost if it fails,
- Phase 0 test infrastructure: 2-3 days, lands alongside 0a,
- Photos persistent changes and storm control: 4-7 days, because album/favorites scopes require extra PhotoKit behavior verification,
- state machine and tests: 3-4 days (the explicit reducer signature and effect-list contract add coverage),
- retry/backoff: 1-2 days,
- UI/bootstrap/docs: 4-6 days, including Settings tabs, status menu bar item, notifications, accessibility labels, and the first-toggle-opens-Settings flow.

Total: roughly **6-7 engineering weeks** for a careful implementation with Timeline, Favorites, and Albums scopes assuming the spikes resolve favorably. If the advisory-lock spike fails or album persistent-change behavior is opaque, expect closer to 8 weeks because Phase 0b is redesigned.

The earlier 4-5 week range was the pre-review estimate and assumed manual-export-disabled UI plus no test-infrastructure prerequisites; both are no longer accurate. The original 4-7 day estimate is only realistic for a naive "debounced `startExportAll()`" implementation. That version is not recommended.

## High-Level Plan: True Closed-App Background Sync

### Feasibility

Possible, but not with `BGTaskScheduler` on macOS. The supported macOS mechanisms are:

- launch the main app at login with `SMAppService.mainApp`,
- bundle a login item helper app,
- bundle a LaunchAgent and register it with `SMAppService.agent(plistName:)`,
- use launchd keys such as `StartOnMount` to wake the agent on filesystem mounts.

### Recommended Path

Two-step: ship launch-at-login with MVP, then add a LaunchAgent for closed-app coverage in a later version.

Launch-at-login is process-local — the same main app started at login. No App Group, no IPC, no cross-process locking. The MVP foundations (stable destination identity, safety scan, awaitable runs, single-active-run gate) carry over unchanged.

The eventual LaunchAgent should be agent-mediated rather than headless: the agent wakes on mount/login, filters quickly, and launches or signals the main app to perform export. Direct headless Photos export from the agent should wait until Photos authorization, security-scoped bookmark access, App Group storage, and cross-process record-store locking are proven in signed sandboxed builds.

Escalation steps:

1. **Launch main app at login** (MVP)
   - **XS**.
   - Uses `SMAppService.mainApp.register()`.
   - Auto Export runs after login and while the app is running.
   - Does not help if the user explicitly quits the app.
   - No new entitlements, no App Group, no IPC.

2. **LaunchAgent with `StartOnMount`** (later version)
   - **XL**.
   - Agent wakes on every filesystem mount and at login, filters for the selected destination, then launches/signals the main app.
   - Requires `SMAppService.agent(plistName:)`, bundled launchd plist, code signing, re-registration on updates, and Login Items approval.
   - Requires App Group migration so the agent and main app share preferences, bookmarks, and record-store state.
   - Adds a "Run Auto Export when Photo Export is closed" section to the Auto Export settings tab.

The login-item helper option is intentionally excluded. It is **L** complexity, costs the same IPC + App Group migration as the LaunchAgent, but does not deliver true closed-app coverage. There is no point on the spectrum where it dominates either endpoint.

Avoid a LaunchDaemon. Photos access and user-selected destinations are per-user, privacy-scoped workflows; root/system-level background work is the wrong fit.

### Architecture Work Required

For launch-at-login (MVP):

- Call `SMAppService.mainApp.register()` from the app lifecycle coordinator on first opt-in, and `unregister()` when the user disables the setting.
- Add status handling for `.enabled`, `.requiresApproval`, `.notRegistered`, and `.notFound`.
- Add UI that explains why login launch is needed and deep-links to System Settings → Login Items when approval is required.
- Detect status changes when the user revokes the permission via System Settings and reflect the change on next launch / when the Settings window opens.
- No new entitlements beyond what the main app already has.

For the LaunchAgent (later version):

- Add an App Group for shared preferences, bookmarks, and record-store state, and migrate existing per-user state into it.
- Prefer agent-wakes-main-app first; avoid direct Photos export in the agent until signed/sandboxed Photos and bookmark behavior is proven.
- If the agent ever exports directly, move export orchestration into shared code and rely on the same destination/record-store locks.
- Give the agent the right sandbox, Photos, bookmark, and app-group entitlements.
- Register/unregister the agent through `SMAppService.agent(plistName:)`.
- Add Settings state for closed-app sync: unavailable/not installed, registered, enabled, requires approval, denied/disabled by user, and last agent wake attempt.
- Add XPC or another narrow IPC mechanism for the agent to signal the main app.
- Handle app updates: launch agents must be re-registered if the plist or executable changes.
- Build CI/signing changes for both direct distribution and App Store builds.

### Closed-App Sync Risks

- App Store review sensitivity around persistent background behavior.
- Agent and main app can race on the same export record files unless locking is in place. Disabling manual controls in the main UI reduces user-driven overlap, but it does not replace cross-process locks.
- Security-scoped bookmark access across processes must be tested under sandboxed, signed builds.
- The agent may not have the same Photos authorization behavior as the main app.
- `StartOnMount` fires for every mounted filesystem, so filtering and debouncing are mandatory.
- If the agent launches the full app invisibly, users need an obvious way to understand and stop that behavior.

### Complexity Estimate

Sizes for the chosen path:

- Launch-at-login (MVP): **XS**.
- LaunchAgent with mount wakeup and agent-mediated sync (later version): **XL**, with the App Group migration as a load-bearing **M** prerequisite.

The XL spread comes from signing, App Group migration, sandbox verification under signed builds, and deciding how much export logic runs outside the main app process. The login-item helper option is **L** in isolation but is excluded from the plan.

## References

- Apple Developer: `SMAppService` for login items, LaunchAgents, and LaunchDaemons.
- Apple Developer: `NSWorkspace.didMountNotification` and `NSWorkspace.didUnmountNotification`.
- Apple Developer: `PHPhotoLibraryChangeObserver`.
- Apple Developer: `PHPhotoLibrary.currentChangeToken` and `fetchPersistentChanges(since:)`.
- Apple Developer: macOS App Sandbox file access and security-scoped bookmarks.
- Local macOS SDK headers: `BackgroundTasks.framework` marks `BGTaskScheduler` and related task requests unavailable on macOS.
- `man launchd.plist`: `StartOnMount` starts a job every time a filesystem is mounted.
