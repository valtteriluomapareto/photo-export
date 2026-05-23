# Modern SwiftUI Observation Migration Plan

Sibling to [`ui-smoothness-plan.md`](ui-smoothness-plan.md). Goal: migrate the codebase from `ObservableObject` + `@Published` to the `@Observable` macro (available since macOS 14; the codebase targets macOS 15), so SwiftUI gets per-property fine-grained dependency tracking instead of one-dirty-bit-per-object invalidation.

Cross-cutting contracts from [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) — cancellation seam, actor isolation policy, AutoSync seam — must be preserved by every phase. The AutoSync seam in particular needs deliberate bridging (see §AutoSync Bridge below); the rest survives the migration intact.

> **Status:** Draft reviewed in one pass by a SwiftUI specialist, software architect, and senior tester (May 2026). Corrections integrated inline. Key changes from the review pass: the `withObservationTracking` timing explanation was inverted (corrected below); the `CurrentValueSubject` bridge needs an explicit `oldValue` guard inside `didSet` (added below); the granularity-test sketch in §Testing Strategy was broken because `withObservationTracking` is one-shot (corrected with a re-registering helper); Phase 5 should be preceded by a short spike to validate the AutoSync bridge before committing to the full migration; ExportManager migration is now an explicit deferral option rather than mandatory.

---

## Background — Why Migrate

The codebase uses `ObservableObject` + `@Published` throughout (five UI-injected managers plus host-driven collaborators). That model has *coarse-grained* tracking: any view holding the object as `@EnvironmentObject` re-evaluates `body` on *any* `@Published` change, even properties the view doesn't read. The sibling smoothness plan invests substantial effort (Tasks 1.1 and 2.1) in compensating for this — coalescing high-frequency mutations and manually partitioning fat observables to reduce invalidation churn.

`@Observable` (introduced macOS 14 / iOS 17) replaces that with per-property dependency tracking, the same shape as Vue refs / Angular signals. The view tracks which properties its `body` actually read; only mutations to *those specific properties* cause re-evaluation. This obsoletes the "manually partition observables" work and reduces the value of mutation coalescing.

### What's actually different

- **Declaration:** `class X: ObservableObject` with `@Published var foo` → `@Observable class X` with plain `var foo`.
- **Storage in views:** `@StateObject` / `@ObservedObject` → `@State` for `@Observable` types.
- **Injection:** `@EnvironmentObject` → `@Environment(MyType.self)`. Lookup is by type, so types that need disambiguation need wrapper types.
- **Two-way bindings:** `@Binding` to `@Published` works via `$published` projection. With `@Observable`, you need `@Bindable var x: MyType` in the consuming view (or `@Bindable` modifier) before you can write `$x.property`.
- **Combine:** `@Observable` types have **no** `objectWillChange` publisher and **no** `$property` projected publishers. Anything that subscribes via Combine needs an explicit bridge.
- **Observation outside SwiftUI:** `withObservationTracking { read … } onChange: { … }` is the one-shot primitive. SwiftUI re-registers internally; non-SwiftUI consumers (e.g. AutoSync, telemetry) have to re-register manually after each `onChange` fire.
- **Macro-driven:** errors at the boundary can be noisier. Stick to the supported shape; don't get clever with computed properties that wrap private storage.

### What stays the same

- Actor isolation policy: `@Observable @MainActor final class` is fully supported. The actor isolation contract is unaffected.
- The cancellation seam: synchronous `isCurrent(gen)` reads from `@MainActor` contexts continue to work; `@Observable` doesn't change actor semantics.
- View-side patterns: `.task(id:)`, `.onChange(of:)`, `ForEach(id:)`, `@State` for view-local state — all unchanged.

---

## Interaction With the UI Smoothness Plan

The smoothness plan was written assuming the current `ObservableObject` substrate. With `@Observable`, the task list changes shape. Mapping:

| Task | Verdict | Reasoning |
|---|---|---|
| 1.1 Mutation coalescing | **Reduced scope** | `@Observable` removes the "any change invalidates all observers" amplification, so coalescing is no longer needed to protect views that don't read the changed property. Still useful for *single* high-frequency properties whose direct readers can't drop frames (e.g. `mutationCounter` if anything reads it in a hot path; `ExportProgressState.currentAssetFilename` if the progress UI updates on every asset). Keep the `MainActorCoalescer` design; apply it only to demonstrated hotspots, not as a blanket pattern. |
| 1.2 Decoded thumbnail cache | **Unchanged** | Orthogonal to observation. About avoiding decode work inside `body`, regardless of how `body` is invoked. |
| 1.3 Cell-scoped thumbnail cancellation | **Unchanged** | Orthogonal. About PhotoKit request lifecycle. |
| 2.1 Partition observation surfaces | **Obsolete** | This task exists *only* to approximate per-property tracking manually. `@Observable` does it by default. Delete this task from the smoothness plan once Phase 5 (ExportManager migration) lands. |
| 2.2 Progressive `PHFetchResult` enumeration | **Unchanged** | Orthogonal. About fetch shape and main-thread enumeration. The `ForEach(id: \.id)` precondition still applies. |
| 2.3 Off-main `JSONLRecordFile.load()` | **Unchanged** | Orthogonal. About moving JSON decode off main during launch. The `RecordStoreState.loading` precondition still applies. |
| 3.1 Split authoritative state from observable façade | **Reshaped** | The original motivation (avoid mass invalidation on store mutations) goes away with `@Observable`. But the *other* motivation (move record-store work off main) survives. Reshape into "make the record store core off-main and expose a `@Observable` snapshot for SwiftUI." Smaller diff than originally planned. |
| 3.2 Lazy sidebar evaluation | **Unchanged** | Orthogonal. About source-debouncing `libraryRevision`. |

**Net effect on the smoothness plan if this migration lands first:** Task 2.1 disappears entirely, Task 1.1 shrinks to a handful of hotspots, Task 3.1 shrinks to a "move IO off main" plan with no façade indirection.

---

## Migration Roadmap

Seven phases (after the review pass added a bridge spike as Phase 0.5). Order: validate the injection-pattern recipe on a trivial type (Phase 0), then *spike the AutoSync bridge in isolation* (Phase 0.5) so the highest-risk piece fails fast if it's going to fail at all, then progress from leaves to the most-observed types. The full ExportManager migration (Phase 5) is now an explicit *optional* deferral — see Phase 5 for the rationale.

### Phase 0 — Foundation

**Goal:** validate the approach end-to-end on one trivial type before touching anything significant. Also: create the test infrastructure every later phase depends on.

**Prerequisites (must land before any other phase):**

- Create `photo-exportTests/Fixtures/` (does not exist today).
- Build a `FakePhotoLibraryService` bulk-fixture helper that can synthesize a 10k–100k-asset configuration. This is also a UI Smoothness Plan prerequisite — coordinate so it lands once.
- Add the `ObservationCounter` test helper (see §Testing Strategy) so Phase 0+ granularity tests have a deterministic counting primitive.
- Confirm test style: the codebase uses **Swift Testing (`@Test` / `#expect`)**, not XCTest. All new migration tests must follow this style.

**Tasks:**

- Pick a pilot type with **no** Combine consumers and **no** AutoSync touch points. Candidate: `App/WhatsNewState.swift`. It's small, view-local, and has no cross-cutting contracts.
- Migrate it. Before:

  ```swift
  @MainActor final class WhatsNewState: ObservableObject {
      @Published var showWhatsNew = false
  }
  ```

  After:

  ```swift
  @Observable @MainActor final class WhatsNewState {
      var showWhatsNew = false
  }
  ```

- Update its injection sites: `@StateObject` → `@State`, `@EnvironmentObject` → `@Environment(WhatsNewState.self)`, `.environmentObject(state)` → `.environment(state)`.
- Verify the app builds, the existing tests pass, and the What's New view still toggles. If anything broke in a non-obvious way, fix the migration recipe before proceeding.
- Document the recipe (and any gotchas) in `docs/reference/observation-migration-recipe.md` so subsequent phases have a single source of truth.

**Definition of done:** `WhatsNewState` is `@Observable`, the app builds, tests pass, the recipe doc exists.

**Risk:** Low. Worst case is the migration recipe needs refinement before Phase 1.

---

### Phase 0.5 — AutoSync Bridge Spike (fail-fast on the hardest piece)

**Goal:** prove the `CurrentValueSubject` mirror bridge produces the same `exportRunStatePublisher` emission sequence as today's `@Published`-projected version, *before* investing in five phases of migration that assume the bridge works.

**Why this exists.** The original plan ran the highest-risk migration (Phase 5, ExportManager + AutoSync bridge) *last*. That's the wrong risk profile: if the bridge fundamentally doesn't preserve the contract, you'd find out only after the rest of the codebase is already committed to `@Observable`. A 2–3 day isolated spike catches the failure mode before any other phase starts.

**Scope:**

- Create a *scratch* `@Observable` clone of `ExportManager` (in a branch, not landed) that wraps the four AutoSync-tracked properties (`activeRunContext`, `isRunning`, `queueCount`, `isEnqueueingAll`) with `didSet`-backed `CurrentValueSubject` mirrors and rebuilds `exportRunStatePublisher` over them.
- Capture a baseline of emissions from today's `ExportManager.exportRunStatePublisher` against a scripted mutation sequence (see §Testing Strategy for the concrete sequence).
- Run the same scripted sequence against the scratch `@Observable` clone; capture its emissions.
- Compare: emissions must be identical (same `ExportRunState` values in the same order, same `removeDuplicates` collapsing).

**Definition of done:**

- A test (in the scratch branch, not landed) demonstrates emission equivalence between the `@Published` and `@Observable + mirror` shapes against the scripted sequence.
- A short writeup documents any subtle differences found (re-entrancy on the same main-actor scope, ordering when two properties mutate in the same tick, behavior under `Task.yield()` between mutations) so subsequent phases know what to watch for.

**Exit criteria → next step:**

- **Spike passes:** continue with Phases 1–4. Decide for Phase 5 whether to fully migrate ExportManager or defer it (see Phase 5 for the deferral option).
- **Spike fails:** abandon the bridge approach. Two fallback paths exist: (a) keep `ExportManager` as `ObservableObject` indefinitely and migrate everything else (acceptable — see Phase 5 deferral rationale); (b) redesign AutoSync's consumption to use an `AsyncStream` driven by `withObservationTracking` re-registration, which is a larger refactor of `AutoSyncManager` itself and is out of scope here.

**Risk:** Low for the spike itself (it's a scratch branch). High *value* — this is the gating decision for whether Phase 5 is feasible at all.

---

### Phase 1 — Self-contained leaves (no AutoSync, no Combine)

**Goal:** apply the recipe to the simplest managers; surface any unexpected interactions with the codebase's actor isolation and `@MainActor` patterns.

**Targets:**

- `App/LoginItemController.swift` — small, lifecycle-only, no cross-cutting deps.
- `App/AppLifecycleCoordinator.swift` — small, lifecycle-only.
- `Destination/ExportDestinationManager.swift` — larger, but no AutoSync subscription on it. Its `selectedFolderURL` / `isAvailable` / `destinationFingerprint` are read by views and by `ExportDestinationResolver`; verify no Combine sink exists on any of its `@Published` properties before migrating.
- `Destination/DestinationSafetyMonitor.swift` — has a `.receive(on:)` per the smoothness-plan audit; verify it's not on a path that needs preservation.

**Tasks per type:**

1. Grep for `.sink` / `$propertyName` / `objectWillChange` against the target type — confirm no Combine consumer exists. If any does, defer to Phase 5 (because that's where the AutoSync bridge work lands; reuse the same bridge for any other Combine consumer found here).
2. Apply the recipe.
3. Update injection sites. (`grep -rn "EnvironmentObject.*ExportDestinationManager" photo-export/Views/` etc.)
4. Update any two-way bindings: add `@Bindable` declarations where views write back to properties.
5. Run tests; verify all green.

**Definition of done:** all four types are `@Observable`, no Combine sinks broken, tests pass. Recipe doc refined with anything learned.

**Risk:** Medium. `@EnvironmentObject` is widely used; the type-based `@Environment(_:)` lookup may surface accidental shadowing that the name-based pattern didn't.

---

### Phase 2 — UI-local state types

**Goal:** migrate types that exist mainly for view consumption.

**Targets:**

- `ViewModels/MonthViewModel.swift` — read by `MonthContentView` and `CollectionContentView`. After the UI Smoothness Plan's Task 1.2 lands, `thumbnailsById` will have been deleted, leaving a thinner surface to migrate.
- `Models/ExportProgressState.swift` — held by `ExportManager` (~L75), read by `ExportProgressBar` and timeline `MonthRow`. Currently `ObservableObject` with `@Published` properties that fire per-asset during runs (motivation for smoothness Task 1.1).

**Hard ordering requirement — Task 1.2 of the UI Smoothness Plan must land before this phase.** Task 1.2 deletes `MonthViewModel.thumbnailsById`; migrating `MonthViewModel` to `@Observable` while that property still exists means the migration has to handle a property that's about to be removed, then immediately remove it. Either:
- (a) Land smoothness Task 1.2 first, then start Phase 2; or
- (b) Defer `MonthViewModel` from Phase 2 entirely and migrate it as part of Task 1.2's diff, since Task 1.2 already touches the file.

Recommendation: (b). Drop `MonthViewModel` from Phase 2's scope and let it migrate alongside the thumbnail-cache work. Phase 2 then handles only `ExportProgressState`.

**Tasks:**

1. `ExportProgressState` is owned by `ExportManager`. While `ExportManager` is still `ObservableObject`, it can hold an `@Observable` instance as a plain property — *but* the manager won't re-publish changes to the instance. That's actually fine for SwiftUI views (they observe `ExportProgressState` directly via `@Environment` or by being passed an instance), but verify no view currently observes `ExportProgressState` *via* `ExportManager.objectWillChange`. Grep before migrating.
2. (Deferred to Task 1.2.) `MonthViewModel` migration; not in Phase 2's scope per the ordering requirement above.

**Definition of done:** `ExportProgressState` is `@Observable`; per-asset progress UI updates only invalidate the progress bar and the affected row, not the whole observing tree.

**Risk:** Medium. `ExportProgressState`'s observation chain crosses `ExportManager`; if a view observes the wrong thing transitively, granularity won't kick in.

---

### Phase 3 — Record stores

**Goal:** the biggest single payoff. Grid views and sidebars currently re-evaluate on every record append because they observe the whole store; with `@Observable`, they only re-evaluate on the specific record/counter they read.

**Targets:**

- `Records/ExportRecordStore.swift`
- `Records/CollectionExportRecordStore.swift`
- `Records/RecordStoreState.swift` — enum value type, no change needed; just verify it remains the published shape.
- `Records/JSONLRecordFile.swift` — `@MainActor` but not `ObservableObject`. No change.

**Tasks:**

1. **Before migrating**, verify no Combine sink exists on either store's `@Published` properties. AutoSync doesn't observe the stores directly (it observes `ExportManager`'s run-state publisher), so this should be clean — but verify with grep before assuming.
2. Apply the recipe to both stores. `@Published private(set) var state` → `private(set) var state`. The `mutationCounter` property becomes implicitly observed; any direct readers of it in views can drop the explicit dependency.
3. Re-evaluate smoothness Task 1.1 for the stores specifically. After migration, the only views that re-evaluate on a record append are those that read the *specific* record (or aggregate) that changed. Coalescing is no longer needed unless profiling shows a hot path. Strong candidate to delete the `MainActorCoalescer` work for the stores.
4. Re-evaluate smoothness Task 3.1. The "fat published surface" motivation disappears; only the "move IO off main" motivation remains. Pare the task scope.

**Definition of done:**

- Both stores are `@Observable`.
- A new regression test asserts: appending 5,000 records while a view observes `monthSummary(forYear:month:)` triggers re-evaluations only when that specific bucket changes (see §Testing Strategy).
- Smoothness Tasks 1.1 (record-store portion) and 3.1 (façade indirection portion) explicitly de-scoped or deleted from the smoothness plan.

**Risk:** Medium-high. The stores are read from many views and from `ExportManager` itself; subtle behavior changes (e.g. `mutationCounter` becomes ambient instead of explicit) may surprise existing code.

---

### Phase 4 — PhotoLibraryManager

**Goal:** migrate the most-observed signal in the app (`libraryRevision`) and consolidate any `@Published` properties on `PhotoLibraryManager` itself.

**Target:** `PhotoLibrary/PhotoLibraryManager.swift`. Three `@Published` properties: `authorizationStatus`, `isAuthorized`, `libraryRevision`.

**Tasks:**

1. Verify no Combine consumer of these properties exists. `libraryRevision` is observed by views via `.task(id:)` and `.onChange(of:)`; both work with `@Observable` properties unchanged. Verify with grep.
2. Apply the recipe.
3. Re-evaluate smoothness Task 3.2 (lazy sidebar evaluation). Source-debouncing the `libraryRevision` bump is still valuable — `@Observable` makes the invalidation more granular *per view*, but a burst of bumps still wakes the views that *do* read `libraryRevision`. Task 3.2 stays in scope.

**Definition of done:** `PhotoLibraryManager` is `@Observable`; `libraryRevision` observers (sidebar count rows, grids) still receive change notifications correctly; tests pass.

**Risk:** Medium. `libraryRevision` is a wide signal; verify post-migration that all expected refresh paths still fire.

---

### Phase 5 — ExportManager + the AutoSync Bridge *(optional / deferrable)*

**Goal:** the highest-risk migration. `ExportManager` is the AutoSync seam.

**Make-or-defer decision.** After Phases 0.5, 1–4 land, the only remaining `ObservableObject` of consequence is `ExportManager` itself. Before starting Phase 5, capture invalidation counts from the post-Phase-4 baseline and answer: *how much of the smoothness payoff is left on the table by leaving ExportManager as `ObservableObject`?*

- If post-Phase-4 metrics show that ExportManager's coarse invalidation is responsible for ≥20% of the remaining view churn, proceed with Phase 5.
- If <20%, **defer indefinitely.** Keep `ExportManager` as `ObservableObject` + `@Published`; document that the AutoSync seam is the reason. This is a legitimate end state, not a half-finished migration: the seam exists *because* AutoSync needs Combine semantics, and `ObservableObject` is the framework-native shape for that.

The Phase 0.5 spike's outcome also feeds this decision — if the bridge proved fragile in spike, defer is mandatory.

**The AutoSync constraint, restated.** `AutoSync/AutoSyncManager.swift:121` subscribes to `environment.exportRunner.exportRunStatePublisher`, which is built inside `Export/ExportManager.swift:196–209` as:

```swift
Publishers.CombineLatest4($activeRunContext, $isRunning, $queueCount, $isEnqueueingAll)
    .map { ... }
    .removeDuplicates()
    .eraseToAnyPublisher()
```

The `$`-projections come from `@Published` — they don't exist on `@Observable` properties. The bridge must preserve this publisher's behavior (synchronous emission, no `.receive(on:)`, no main-actor hop) because AutoSync depends on it for the synchronous coherence the seam contract requires.

**Bridge design (recommended): `CurrentValueSubject` mirrors per AutoSync-tracked property.** Keep the `@Observable` properties as the source of truth for SwiftUI; mirror them into `CurrentValueSubject`s via `didSet` for the AutoSync-required ones. The `exportRunStatePublisher` is rebuilt over the mirror subjects.

```swift
@Observable @MainActor final class ExportManager {
    var activeRunContext: ExportRunContext? {
        didSet {
            guard activeRunContext != oldValue else { return }
            activeRunContextSubject.send(activeRunContext)
        }
    }
    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            isRunningSubject.send(isRunning)
        }
    }
    // ... and so on for queueCount, isEnqueueingAll

    private let activeRunContextSubject = CurrentValueSubject<ExportRunContext?, Never>(nil)
    private let isRunningSubject = CurrentValueSubject<Bool, Never>(false)
    // ...

    var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> {
        Publishers.CombineLatest4(
            activeRunContextSubject, isRunningSubject, queueCountSubject, isEnqueueingAllSubject
        )
        .map { /* same mapping as today */ }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
```

**The `oldValue` guard is load-bearing.** `CurrentValueSubject.send(_)` emits on *every* call regardless of value equality (unlike `@Published`'s `willSet`, which behaves similarly but composes differently with downstream operators). Without the guard, assigning the same value to a property emits a duplicate through the subject; the downstream `.removeDuplicates()` collapses it for `exportRunStatePublisher`, but any direct subscriber to a mirror subject (e.g. a future feature observing `isRunningSubject` directly) would see redundant emissions. Add the guard at every `didSet` to keep the bridge's surface honest.

This preserves:

- Synchronous emission (the `didSet` fires synchronously inside the same main-actor scope as the property mutation).
- The no-`.receive(on:)` contract (the publisher is not hopping queues).
- The `removeDuplicates` semantics.
- The `.combineLatest4` shape (no change in subscriber-visible behavior).

It costs verbosity (four extra subjects, four extra `didSet` lines) but every line is mechanical and the contract is preserved by construction.

**Alternatives considered and rejected (for ExportManager specifically):**

- `withObservationTracking` from AutoSync. The actual issue is that the primitive is *one-shot*: after `onChange` fires, tracking ends and the caller must re-register inside (or after) `onChange` to keep observing. For a continuous AutoSync subscription this means hand-rolling a re-registration loop that's equivalent to a `.sink`, with no upside over the `CurrentValueSubject` mirror. (Note: contrary to an earlier draft of this plan, `onChange` fires *after* the mutation is committed and the new value is observable — it is closer to `didChange` than `willChange`. The blocker is the one-shot semantics, not stale reads.)
- Convert `exportRunStatePublisher` to `AsyncStream`. Issue: AutoSync's current code is built on Combine subscriptions; rewriting it to consume an `AsyncStream` is a separate, large refactor and is out of scope.
- Keep `ExportManager` as `ObservableObject` indefinitely. Workable as a fallback if the bridge proves unstable, but undercuts the migration's payoff.

**Tasks:**

1. Inventory every Combine consumer of `ExportManager` properties (not just `exportRunStatePublisher`). Grep for `.sink` on `exportManager.$…` and on any explicit publisher property. Document the list before changing anything.
2. Implement the `CurrentValueSubject` mirror pattern for the four properties `exportRunStatePublisher` composes over. Keep `completedRunsSubject` as-is (already an explicit `PassthroughSubject`).
3. Convert `ExportManager` to `@Observable`. Delete `@Published` annotations. Add the `didSet` mirror calls.
4. Update injection sites (every view that takes `@EnvironmentObject var exportManager: ExportManager`).
5. Convert two-way bindings in settings views to `@Bindable`. (E.g. `Toggle(isOn: $exportManager.convertHEICToJPEG)` requires `@Bindable var exportManager: ExportManager` at the view's level.)
6. **Re-run the full AutoSync test suite.** This phase's success criterion is "AutoSync behaves identically; no flakiness." Any regression here blocks the phase.
7. Delete smoothness Task 2.1 from the smoothness plan. Re-scope smoothness Task 1.1 down to whatever hotspots remain.

**Definition of done:**

- `ExportManager` is `@Observable`.
- `exportRunStatePublisher` continues to fire on the same triggers, in the same order, with the same `removeDuplicates` semantics.
- All AutoSync tests pass (specifically the integration tests in `AutoSyncManagerTests`).
- No view-level regression visible in manual testing.
- Smoothness plan updated: Task 2.1 removed, Task 1.1 pared.

**Risk:** High. The AutoSync seam is the single hardest piece of the migration. Two mitigations: (a) the `CurrentValueSubject` mirror pattern is mechanical and contract-preserving by construction; (b) Phase 5 lands last, after every other migration has validated the recipe and AutoSync hasn't been touched.

---

## AutoSync Bridge — Standalone Reference

Because this is the single load-bearing piece, a standalone callout:

**Contract** (from architecture-conventions.md §AutoSync seam): synchronous `.sink`, never `.receive(on:)` or `MainActor.run`; mirrors fire in the same main-actor scope as the upstream mutation; AutoSync observes a coherent main-actor snapshot.

**With `@Observable` (default behavior):** breaks. No `$property` projections. `withObservationTracking` is one-shot — after `onChange` fires, the tracking registration is gone and the caller has to re-register manually. For Combine-shaped continuous subscriptions, this means writing a re-registration loop equivalent to a `.sink`, with no advantage over the explicit subject mirror.

**Bridge recipe:**

1. For each property `foo` on an `@Observable` type that AutoSync (or any other Combine consumer) subscribes to, add `private let fooSubject = CurrentValueSubject<FooType, Never>(initial)`.
2. Add `didSet { fooSubject.send(foo) }` to the property.
3. Rewrite any `Publishers.CombineLatest…($foo, $bar, ...)` to use the subjects directly.
4. Verify the rebuilt publisher behaves identically (`removeDuplicates`, ordering, sync emission) — a unit test that compares the publisher output for a scripted sequence of mutations before/after migration is the safest check.

**Scope:** apply this bridge only where Combine consumers exist. Pure SwiftUI consumption needs no bridge — `@Observable` works directly for views.

---

## Cross-Cutting Concerns

### Actor isolation

`@Observable @MainActor final class` works as expected. No change in policy. Helpers that are `nonisolated` stay `nonisolated`. The `JSONLRecordFile` static `nonisolated` helpers continue to work; they're not part of the observation chain.

### Cancellation seam

Unchanged. `isCurrent(gen)` reads from main-actor contexts continue to work. `@Observable` doesn't alter actor semantics. Cancellation tests in the existing suite need no migration-specific changes.

### Combine integration

The bridge above handles Combine consumers explicitly. Any *new* Combine consumer added during or after the migration must follow the bridge recipe; document this in the recipe doc from Phase 0.

### Environment type collisions

`@Environment(MyType.self)` is keyed by type. Two different `@Observable` types with similar names (or, worse, the same name in different modules) could collide in confusing ways. Audit the codebase before Phase 1; no obvious collisions exist today but add this check to the recipe.

### `@Bindable` vs. `@Binding`

`@Binding` to a property of an `ObservableObject` works via the `$published` projection. With `@Observable`, the consuming view needs `@Bindable var thing: MyType` *before* it can write `$thing.property`. Audit every two-way binding in `Views/Settings/` and `Views/Export/` before migrating the source-of-truth type. Examples to verify:

- `Toggle(isOn: $exportManager.convertHEICToJPEG)` — needs `@Bindable var exportManager` in the view.
- `Picker(selection: $exportManager.versionSelection)` — same.
- Every `TextField(text: $...)` against an observable property — same.

### Macro hygiene

`@Observable` is a macro. Be conservative with the supported shape:

- Don't add `@ObservationIgnored` reflexively; only on properties that genuinely shouldn't be tracked (e.g. private caches that aren't view-visible).
- Don't combine `@Observable` with other macros that touch storage (e.g. `@AppStorage` works at the view level, not the model level — fine).
- Computed properties are tracked transitively through the stored properties they read; this is correct and idiomatic.
- Don't add custom `init` patterns that bypass the macro's storage setup. If a custom init is needed, follow the macro-generated shape exactly.

---

## Testing Strategy

The goal of the test plan isn't only "don't regress" — it's "verify the *granularity* actually improved" so the migration's stated payoff is observable.

### Pre-migration baseline (before Phase 0)

Establish a baseline using the invalidation harness from `ui-smoothness-plan.md` §Rollout & Measurement:

1. Capture per-view invalidation counts during a scripted scenario: launch → select a 10k-asset month → start a 200-asset export → observe.
2. Record the counts for: month sidebar rows, year sidebar rows, grid cells, progress bar, toolbar.
3. Commit the baseline to a CI-readable fixture (e.g. JSON in `photo-exportTests/Fixtures/`).

This baseline is what the migration is measured against. It also surfaces unexpected dependencies — if the baseline shows a view invalidating on something nobody expected, that's a finding to address before migration, not after.

### Per-phase verification

Each phase adds at least one regression test that asserts *granular tracking actually engaged*.

**Caveat — `withObservationTracking` is one-shot.** A naïve call (`withObservationTracking { read } onChange: { count += 1 }`) stops tracking after the *first* mutation. To observe N mutations, the test has to re-register inside `onChange` (or wrap that pattern in a helper). Test sketches that omit the re-registration loop will silently under-count or appear to pass when they shouldn't.

**Required test helper** (add to `photo-exportTests/TestHelpers/ObservationCounter.swift` before Phase 0):

```swift
@MainActor
final class ObservationCounter {
    private(set) var count = 0
    private var isActive = true

    /// Begin tracking `read`; increment `count` whenever any tracked property
    /// mutates. Re-registers automatically until `stop()` is called.
    func start<T>(_ read: @escaping @MainActor () -> T) {
        guard isActive else { return }
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.count += 1
                self.start(read) // re-register
            }
        }
    }

    func stop() { isActive = false }
}
```

Granularity test using the helper:

```swift
@Test @MainActor func testObservableGranularity_RecordStore() async {
    let store = ExportRecordStore(...)
    let bucketUnderTest = ObservationCounter()
    let unrelatedBucket = ObservationCounter()

    bucketUnderTest.start { store.monthSummary(forYear: 2024, month: 5) }
    unrelatedBucket.start { store.monthSummary(forYear: 2023, month: 1) }

    store.markExported(asset: makeAsset(year: 2024, month: 5), ...)
    await Task.yield()

    #expect(bucketUnderTest.count == 1)
    #expect(unrelatedBucket.count == 0)  // the granularity win

    bucketUnderTest.stop()
    unrelatedBucket.stop()
}
```

**Verify the underlying granularity assumption before relying on the test.** The test only proves granularity if `monthSummary(forYear:month:)` reads a *single* observable property keyed by `(year, month)`. Read `Records/ExportRecordStore.swift:427–454` to confirm: today's implementation reads `monthCounters[MonthKey(year: year, month: month)]`, a single dictionary lookup on a single stored property. After migration, `@Observable` tracks reads at the level of the `monthCounters` *dictionary*, not at individual key level — so any mutation to *any* month bucket would fire the dependency. To get per-bucket granularity, the migration should either (a) expose per-month-key tracking via the `Observation` framework's `_$observationRegistrar` extension, or (b) accept that granularity is at the dictionary level and the test asserts a weaker but still useful property (any month-bucket mutation invalidates any month-bucket reader — still better than the current "any record mutation invalidates every observer").

Pick (b) for v1 and document the limitation; (a) is a possible future refinement.

### Cancellation seam regression

Run the existing cancellation tests after each phase. Specifically:

- `ExportManagerTests` — the per-job cancellation tests.
- The `isCurrent(gen)` synchronous-read tests.

These should not be affected by observation changes; if they fail, something subtle is wrong with actor isolation.

### AutoSync seam regression (Phase 0.5 spike + Phase 5 gate)

The AutoSync test suite (`AutoSyncManagerTests` and its environment-fake-based scenarios) is the critical gate for both the Phase 0.5 spike and the Phase 5 migration. The same scripted sequence drives both — captured against the pre-migration code, replayed against the spike branch, and re-checked when Phase 5 lands.

**Scripted mutation sequence** (exercise all four CombineLatest4 inputs and the `removeDuplicates` collapse):

```
Step 1. Initial state: activeRunContext=nil, isRunning=false, queueCount=0, isEnqueueingAll=false
        → expect emission: ExportRunState(isManualActive=false, isAutoSyncActive=false)
Step 2. User triggers Export All: isEnqueueingAll=true
        → expect emission: ExportRunState(isManualActive=true)  (manual fire-and-forget)
Step 3. First job appends: queueCount=1 (isEnqueueingAll still true)
        → expect NO emission  (removeDuplicates collapses; isManualActive stayed true)
Step 4. Bulk dispatcher finishes enqueueing: isEnqueueingAll=false, queueCount=1, isRunning=true
        → expect NO emission  (still manualActive)
Step 5. Queue drains: queueCount=0, isRunning=false
        → expect emission: ExportRunState(isManualActive=false)
Step 6. AutoSync starts a run: activeRunContext=AutoSyncContext, isRunning=true
        → expect emission: ExportRunState(isAutoSyncActive=true)
Step 7. AutoSync finishes: activeRunContext=nil, isRunning=false
        → expect emission: ExportRunState(isAutoSyncActive=false, isManualActive=false)
```

Expected emission count: **4 distinct states.** Any deviation from this count or order indicates the bridge altered the publisher's contract.

**Capture mechanism:**

1. On the pre-migration code (today's `@Published` version), run a one-shot test that drives this sequence and records every emission to `photo-exportTests/Fixtures/ExportRunStatePublisherBaseline.json`.
2. Commit the fixture.
3. The Phase 0.5 spike runs the same test against the scratch `@Observable` clone and asserts emissions match the fixture.
4. After Phase 5 lands, the test runs against the migrated `ExportManager` and asserts the fixture still matches.

```swift
@Test @MainActor func testExportRunStatePublisherMatchesBaseline() async throws {
    let manager = makeExportManager(/* with fakes */)
    let recorder = PublisherRecorder<ExportRunState>()
    let subscription = manager.exportRunStatePublisher.sink { recorder.record($0) }
    defer { subscription.cancel() }

    // Drive the 7-step sequence above.
    await driveScriptedSequence(on: manager)

    let baseline = try loadBaseline("ExportRunStatePublisherBaseline.json")
    #expect(recorder.captured == baseline)
}
```

**Why this is non-negotiable.** The AutoSync contract is documented in [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) §AutoSync seam. Any silent change here (an extra emission, a dropped emission, a reordered pair) can cause AutoSync to race the manual export path — the exact regression the seam exists to prevent. The fixture-baselined test is the only realistic way to catch such bugs.

### Combine bridge unit tests (Phase 5)

For each property mirrored to a `CurrentValueSubject`:

- Mutation to a *new* value triggers a `send` with the new value.
- Mutation to the *same* value (e.g. `manager.isRunning = false` when it's already `false`) triggers **no** `send`, because the `didSet` guard skips it (`guard newValue != oldValue else { return }`). This deviates from raw `CurrentValueSubject` behavior — without the guard, every property assignment would emit regardless of value equality. The guard is the bridge's correctness primitive.
- Ordering between multiple subjects is preserved when two properties are mutated in the same synchronous scope (e.g. `manager.isRunning = true; manager.queueCount = 1` emits `isRunning` first, `queueCount` second, deterministically because `didSet`s fire in declaration order within the same main-actor tick).

### View-level snapshot tests (optional)

If the project adopts snapshot testing later, snapshot the rendered UI before and after each phase under identical state. Today no snapshot testing exists; skip unless it's added.

---

## Risks

### High — AutoSync bridge subtleties

The `didSet` mirror pattern *is* synchronous, but if a property is mutated from within a Combine pipeline (rare but possible), the mirror's emission could re-enter that pipeline. Audit for re-entrancy before Phase 5.

### Medium — Two-way binding sprawl

Every `Toggle` / `Picker` / `TextField` against an observable property in `Views/Settings/` needs `@Bindable`. This is mechanical but easy to miss. The compile error is clear (`cannot find $foo in scope`), so missed sites are caught at build time — not silent.

### Medium — `@Environment` lookup-by-type

Type collisions are surfaced at runtime, not compile time. Audit before Phase 1 to catch any obvious risk (e.g. two different observable types with the same suffix).

### Low-medium — Test infrastructure

Existing tests instantiate managers directly and assert on `@Published` properties via the projected publisher (rare). Search for `.$` patterns in tests before each phase; rewrite to use direct property reads.

### Low — Macro debug experience

`@Observable` expands at compile time; errors at the expansion boundary can mention generated symbols. Most are decodable; budget some debugging time the first time a real error surfaces.

---

## Out of Scope

- Migrating away from SwiftUI entirely.
- Adopting third-party observation libraries (e.g. `swift-perception` for backports). Codebase targets macOS 15, no backport need.
- Rewriting AutoSync to consume `AsyncStream` instead of Combine. Out of scope here; could be a follow-up if the `CurrentValueSubject` bridge turns out to be unstable in practice.
- Migrating the `actor`-typed `CollectionCountCache`. It's an actor for genuine concurrent-access reasons (not observation); `@Observable` doesn't apply.
- The host-driven collaborators (`ExportQueueCoordinator`, `VariantExporter`, `ImportCoordinator`). They're `@MainActor final class` but not `ObservableObject` today (verify) — they don't need migration unless they grow observable surface area.

---

## Decisions (closed by the review pass)

- **Sequencing relative to the UI Smoothness Plan: interleaved.** Land the unchanged smoothness tasks first (1.2, 1.3, 2.2, 2.3, 3.2); then Phases 0 → 0.5 → 1–4 of this plan; then re-evaluate the reshaped smoothness tasks (1.1, 2.1, 3.1) and decide whether Phase 5 proceeds (per Phase 5's make-or-defer rule). Rationale: the unchanged smoothness tasks ship visible wins and don't conflict; the migration removes Task 2.1 outright and de-scopes 1.1/3.1.
- **`MonthViewModel` migration timing: deferred into Task 1.2.** Phase 2 covers `ExportProgressState` only. `MonthViewModel`'s migration happens inside Task 1.2's diff because Task 1.2 already touches that file.
- **AutoSync `exportRunStatePublisher` scripted sequence: closed.** See the 7-step sequence in §Testing Strategy — same script for the Phase 0.5 spike and the Phase 5 gate.

## Open Questions

- **`@ObservationIgnored` use.** Audit during each phase; default to *not* using `@ObservationIgnored` unless there's a demonstrated reason (private cache that's never read by views, telemetry counter the observer doesn't care about).
- **Whether to fold `ExportProgressState` back into `ExportManager`.** With `@Observable`, the granular tracking might make the separate `ExportProgressState` object unnecessary — readers could observe `ExportManager.currentAssetFilename` directly and only re-evaluate on that specific property. **Defer until after Phase 2:** capture invalidation counts on the migrated `ExportProgressState`; if the split no longer earns its keep, fold back in a follow-up.
- **Per-key granularity for `monthCounters`.** Today, `@Observable` tracks at the dictionary level, not at individual key level. The v1 test in §Testing Strategy accepts dictionary-level granularity. If profiling shows that's insufficient (a hot grid that re-renders on unrelated month-bucket mutations), explore exposing per-key tracking via the `Observation` framework's lower-level `_$observationRegistrar` API. Future refinement; not Phase 3 blocker.
- **`Observations<T>` async sequence.** macOS 15+ ships an `async` consumption shape for `@Observable` types that some non-Combine consumers might prefer over hand-rolled `withObservationTracking` loops. Not relevant for AutoSync (which is Combine-shaped), but useful to document in the recipe doc as the modern primitive for background-task observation.
