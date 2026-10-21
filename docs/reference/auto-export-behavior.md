# Auto Export behavior contracts

Auto Export is the user-facing name; `AutoSync` is the code vocabulary. This reference
collects the rules previously cited through development phases in source comments.
The excerpts below retain the wording of the archived plan or current source comments;
implementation notes distinguish shipped behavior from historical proposals.

Cancellation, actor isolation, destination identity and collaborator ownership remain in
[architecture conventions](architecture-conventions.md).

## Event dispatch

From the archived plan's [State Reducer](../project/archive/auto-sync-background-sync-plan.md#state-reducer)
dispatch contract:

- The reducer is invoked synchronously, once per event, with no mutation in flight.
- Effects are returned as a list and dispatched by an effect runner *after* the reducer returns.
- The effect runner serializes dispatch: only one event is in flight at a time. Events produced by an effect (e.g., `exportRunStateChanged` from `startRun`) are queued and processed after the current event's effects complete.
- Timer cancellation is itself an effect (`cancelDebounce`, `cancelRetryTimer`); the reducer never side-effects timers directly.

These rules are implemented by [AutoSyncReducer](../../photo-export/AutoSync/AutoSyncReducer.swift)
and [AutoSyncManager](../../photo-export/AutoSync/AutoSyncManager.swift). Policy tests inject
protocol fakes through [AutoSyncEnvironment](../../photo-export/AutoSync/AutoSyncEnvironment.swift).

## Triggers and debounce

From [Trigger and Debounce Rules](../project/archive/auto-sync-background-sync-plan.md#trigger-and-debounce-rules):

- app launch: 10 seconds after the app coordinator finishes initial destination/store configuration,
- destination selected: 3 seconds after successful validation and safety check,
- destination became available: 3 seconds after false-to-true `canExportNow`,
- auto-export scope selection changed: 2 seconds,
- export-version selection changed: 2 seconds,
- Photos persistent changes with inserted/updated asset identifiers: 30 seconds after the last relevant change,
- persistent-change token expired, details unavailable, or collection membership changes cannot be targeted cheaply: 2-minute quiet window before full reconciliation,
- manual "Export Now": no debounce after guard checks.

Implementation boundary: [debounceDelay(for:)](../../photo-export/AutoSync/AutoSyncReducer.swift)
also gives HEIC-conversion changes 2 seconds and retry wakeups zero delay. Collection-only
changes use the ordinary 30-second Photos-change path; the 2-minute fallback applies to
persistent-change fetch failures. Export Now uses a zero-delay timer after the same enabled,
authorization, destination, safety, scope, import and active-run gates. It does not bypass
retry eligibility. The UI uses `AutoSyncState.canRunNow`.

## Dirty state and library changes

From [Photo Library Changes](../project/archive/auto-sync-background-sync-plan.md#photo-library-changes):

> Treat deleted asset IDs as non-export work for MVP. Do not delete exported files or records automatically.

From [Dirty State](../project/archive/auto-sync-background-sync-plan.md#dirty-state):

> Persist per-destination dirty state so accumulated work survives interruption, restart, and disable/enable cycles.

The archived plan also proposed:

> Persistent change events that arrive while the destination is unavailable accumulate into the affected scope's `pendingAssetIds`, with the inline cap rule still applying.

That is not the production disconnect behavior: `ExportDestinationManager` publishes no
active stable id while unavailable, so new change events have no destination to update and
are ignored. Existing dirty work survives; reconnect schedules full-scope reconciliation.
A reducer snapshot that still has an id can accumulate while unavailable, which is a
separate case from the production snapshot. See [destination identity](architecture-conventions.md#destination-identity).

The current reducer records relevant changes for the selected destination while Auto Export
is enabled. Its fixed per-scope cap is 500 IDs; above that cap the pending IDs collapse to full
reconciliation. Disabling does not erase persisted dirty work, but changes observed while
disabled do not add new dirty IDs.

The removed manual-clear comment stated:

> A manual full export for the same destination / selection / scope clears compatible dirty flags.

The current run boundary limits that rule, rather than clearing changes that arrived after
work started. The [AutoSyncReducer](../../photo-export/AutoSync/AutoSyncReducer.swift) run-boundary comment
states:

> A single active run only covers work known at its start. A scope is
> invalidated by every subsequent change, even if its pending ID set is
> unchanged. This is a per-run revision boundary; nothing new is persisted.

`acknowledgeRun` requires the matching run context and destination, a completed result, and
compatible version/scope. It excludes scopes changed after the run started. Targeted scope
cases do not clear full-scope dirty state. Legacy manual UI actions do not emit awaitable
run summaries; see [manual export feedback](architecture-conventions.md#manual-export-feedback).

## Retry and failure policy

From [Retry and Failure Policy](../project/archive/auto-sync-background-sync-plan.md#retry-and-failure-policy):

> Retry counts are scoped to `scope/placement + assetId + variant + category + errorSignature`. Timeline can use a timeline scope key; collection exports need placement awareness so a failure in one album does not suppress a different album or Favorites. A materially different error signature resets the retry entry so a resolved disk-space error does not keep blocking a later transient PhotoKit failure.

> Export Issues "Retry Failed" or a normal manual export after disabling Auto Export can override backoff.

> Retry evaluation belongs at enqueue time. The export runner should ask whether each missing asset/variant is currently eligible before creating a job; ineligible variants count as `skippedCount` with a retry reason in the run summary. This keeps auto-sync from starting a run that only churns known blocked failures.

The current [retry state](../../photo-export/Models/AutoSyncRetryState.swift) resets attempt
history when either category or signature changes. Shared albums have distinct placement
buckets too. Eligibility is checked both while planning and before writing; `skippedCount`
is an asset/job count, and per-variant retry details remain in `AutoSyncRetryState`.
The current [failure policy](../../photo-export/Models/AutoSyncFailureCategory.swift) also
includes collision handling and attempt caps. Explicit Retry clears the selected entry before
requesting Export Now; it does not turn Auto Export on.

## Destination safety

From the existing [confirmation-store](../../photo-export/Protocols/DestinationSafetyConfirmationStore.swift)
contract:

> Once a destination is confirmed it stays confirmed across launches — the
> safety scan only flips a fresh destination ID with pre-existing files
> into `unsafeNeedsConfirmation`. Switching to a destination the user has
> already confirmed in the past is `.safe` without re-prompting.

[DestinationSafetyMonitor](../../photo-export/Destination/DestinationSafetyMonitor.swift)
uses the stable destination id. It requires confirmation when both record stores are empty,
the destination root has a non-hidden entry, and there is no saved confirmation.
[DestinationSnapshotAdapter](../../photo-export/Destination/DestinationSnapshotAdapter.swift)
gives migration conflicts precedence over confirmation. Neither confirmation nor a fingerprint
is a substitute for the [stable destination identity](architecture-conventions.md#destination-identity).

## Persistence and token authority

From [Persistence Keys](../project/archive/auto-sync-background-sync-plan.md#persistence-keys):

> Use namespaced keys/file names and separate global from destination-scoped state. Per-destination state lives as a sibling tree to the existing record stores (`ExportRecords/<destinationId>/...`), under `AutoSync/destinations/<destinationId>/`.

Global preferences are `AutoSync.enabled` and `AutoSync.scopeSelection`. The global Photos
cursor is `AutoSync/photo-library-change-token.data`. Destination files include
`safetyRecord.json`, `lastRunSummary.json`, `retryState.json`, `dirtyState.json` and
`lastDurablyRecordedToken.data`.

The existing [AutoSyncEffect](../../photo-export/Models/AutoSyncEffect.swift) contract states:

> when a `photosChanged` event produces both `persistDirtyState` and
> `advancePersistentChangeToken`, the persist effect is emitted *before* the token
> advance. The runner must also withhold that destination's acknowledgement after
> a failed dirty save, including token-only events in later effect batches. These
> destination snapshots are advisory; the Photos adapter owns an independent global
> fetch cursor, so this ordering does not establish crash-safe PhotoKit replay.

The [per-destination token store](../../photo-export/Protocols/AutoSyncPerDestinationTokenStore.swift)
contract states:

> The token records advisory acknowledgement after dirty-state persistence.
> It is currently loaded but does not drive fetching or resume decisions;
> the PhotoKit adapter owns an independent global cursor.

## Run ownership and presentation

From the archived [Run Ownership Model](../project/archive/auto-sync-background-sync-plan.md#run-ownership-model):

> `ExportManager` has at most one active `ExportRunContext`.

> If auto-sync wants to run while a manual export or import is active, `AutoSyncManager` marks itself dirty and re-evaluates after manual work drains. It does not enqueue work inside `ExportManager`.

> `runNow()` requested while a manual run is active follows the same dirty-and-re-evaluate path as any other auto-sync trigger: it does not supersede the manual run.

From [Awaitable Export Runs](../project/archive/auto-sync-background-sync-plan.md#awaitable-export-runs):

> Background runs must not clear manual toolbar messages or flash "Everything in this destination is already exported."

From [Settings UX](../project/archive/auto-sync-background-sync-plan.md#settings-ux):

> `Open Photo Export at login` is an **independent** setting from Auto Export enablement; either can be on without the other.

The [login controller](../../photo-export/App/LoginItemController.swift) reports system status
through its injected `LoginItemService`; Settings refreshes it when its window becomes key.
The former login-controller comments specified:

> Add the `Open Photo Export at login` setting via `SMAppService.mainApp` with `.enabled`/`.requiresApproval`/`.notRegistered`/`.notFound` status reporting and a deep link to System Settings → Login Items.

> On `unregister()`, poll status when the Settings window becomes key; if status remains `.enabled`, surface a 'Still showing in Login Items? Open Login Items…' hint because System Settings does not notify the app.

These are status/reporting instructions, not a promise of closed-app execution.
Quitting the app stops Auto Export. Manual exports requested during automatic work use the
existing confirmation/supersession path. Detailed cancellation ownership remains in
[architecture conventions](architecture-conventions.md#1-cancellation-contract).

## Historical proposals are not shipped contracts

The removed targeting-cap comment preserved this proposal:

> Use a tunable implementation constant backed by measurement, and prefer a cost model once enough data exists.

The removed environment comment stated this testing requirement:

> Tests should exercise the auto-sync policy with fake protocols, not real PhotoKit or filesystem work.

That requirement is implemented through `AutoSyncEnvironment`; it does not require real
Photos or disk access in reducer-policy tests.

The archived plan remains a decision record. Its proposals for advisory locks, a main-window
mode toggle, Export Now bypassing disabled mode/retry timers, per-destination token replay,
measured targeting cost models, and executing targeted asset-id runs are not current behavior.
In particular, [AutoSyncManager.expand(scope:)](../../photo-export/AutoSync/AutoSyncManager.swift)
fans out selected scopes into full-scope runs; [ExportManager](../../photo-export/Export/ExportManager.swift)
rejects targeted scope cases. The fixed dirty-ID cap is a memory bound, not evidence of a
measured targeting cost model. The run-boundary rule above limits historical wording that a
completed full run clears all dirty state. No archived proposal changes these current contracts.
