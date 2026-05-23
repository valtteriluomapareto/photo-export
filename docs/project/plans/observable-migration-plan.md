# Modern SwiftUI Observation Migration Plan

Sibling to [`ui-smoothness-plan.md`](ui-smoothness-plan.md). Goal: migrate the codebase from `ObservableObject` + `@Published` to the `@Observable` macro (available since macOS 14; the codebase targets macOS 15), so SwiftUI gets per-property fine-grained dependency tracking instead of one-dirty-bit-per-object invalidation.

Cross-cutting contracts from [`docs/reference/architecture-conventions.md`](../../reference/architecture-conventions.md) — cancellation seam, actor isolation policy, AutoSync seam — must be preserved by every phase. The AutoSync seam in particular needs deliberate bridging (see §AutoSync Bridge below); the rest survives the migration intact.

> **Status:** Draft. Not yet review-validated against current code beyond the spot-checks called out inline. Treat the file:line references as a starting point — re-verify before implementation.

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

Six phases. Order matters: each phase de-risks the next by validating an aspect of the migration (injection patterns, Combine bridge, test seams) on lower-stakes types before applying it to the highest-stakes one.

### Phase 0 — Foundation

**Goal:** validate the approach end-to-end on one trivial type before touching anything significant.

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

**Tasks:**

1. `ExportProgressState` is owned by `ExportManager`. While `ExportManager` is still `ObservableObject`, it can hold an `@Observable` instance as a plain property — *but* the manager won't re-publish changes to the instance. That's actually fine for SwiftUI views (they observe `ExportProgressState` directly via `@Environment` or by being passed an instance), but verify no view currently observes `ExportProgressState` *via* `ExportManager.objectWillChange`. Grep before migrating.
2. `MonthViewModel` is `@StateObject` in `MonthContentView`. Migrate to `@State var viewModel = MonthViewModel(...)` and adjust initialization.

**Definition of done:** Both types are `@Observable`; per-asset progress UI updates only invalidate the progress bar and the affected row, not the whole observing tree.

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

### Phase 5 — ExportManager + the AutoSync Bridge

**Goal:** the highest-risk migration. `ExportManager` is the AutoSync seam.

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
        didSet { activeRunContextSubject.send(activeRunContext) }
    }
    var isRunning: Bool = false {
        didSet { isRunningSubject.send(isRunning) }
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

This preserves:

- Synchronous emission (the `didSet` fires synchronously inside the same main-actor scope as the property mutation).
- The no-`.receive(on:)` contract (the publisher is not hopping queues).
- The `removeDuplicates` semantics.
- The `.combineLatest4` shape (no change in subscriber-visible behavior).

It costs verbosity (four extra subjects, four extra `didSet` lines) but every line is mechanical and the contract is preserved by construction.

**Alternatives considered and rejected (for ExportManager specifically):**

- `withObservationTracking` from AutoSync. Issue: the `onChange` closure fires *before* the property update is observable. AutoSync would read the old value, which breaks coherence. Could work for non-coherence-sensitive consumers; not appropriate here.
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

**With `@Observable` (default behavior):** breaks. No `$property` projections; `withObservationTracking` is one-shot and fires *before* the property update is observable.

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

Each phase adds at least one regression test that asserts *granular tracking actually engaged*. Pattern:

```swift
@Test func testObservableGranularity_RecordStore() async {
    let store = ExportRecordStore(...)
    var summaryReads = 0
    var unrelatedReads = 0

    withObservationTracking {
        _ = store.monthSummary(forYear: 2024, month: 5)  // reads only this bucket
    } onChange: {
        summaryReads += 1
    }

    withObservationTracking {
        _ = store.monthSummary(forYear: 2023, month: 1)  // unrelated bucket
    } onChange: {
        unrelatedReads += 1
    }

    // Mutate only the 2024/05 bucket
    store.markExported(asset: makeAsset(year: 2024, month: 5), ...)
    await Task.yield()

    expect(summaryReads).toBe(1)
    expect(unrelatedReads).toBe(0)  // <-- the win: unrelated tracking didn't fire
}
```

This is the test that proves granularity. Add one per migrated type (or per phase).

### Cancellation seam regression

Run the existing cancellation tests after each phase. Specifically:

- `ExportManagerTests` — the per-job cancellation tests.
- The `isCurrent(gen)` synchronous-read tests.

These should not be affected by observation changes; if they fail, something subtle is wrong with actor isolation.

### AutoSync seam regression (Phase 5 critical)

The AutoSync test suite (`AutoSyncManagerTests` and its environment-fake-based scenarios) is the critical gate for Phase 5. Add a new test before Phase 5 starts:

```swift
@Test func testExportRunStatePublisherEmitsIdenticallyAfterMigration() {
    // Drive a scripted sequence of mutations on ExportManager;
    // capture the emitted ExportRunState sequence;
    // compare against a recorded baseline from the pre-migration code.
}
```

The baseline is captured *before* Phase 5 starts. The test runs *after* Phase 5 lands. Equal emission sequence = bridge is correct.

### Combine bridge unit tests (Phase 5)

For each property mirrored to a `CurrentValueSubject`:

- Mutation triggers a single `send` with the new value.
- No `send` fires when the property is set to its current value (matches `removeDuplicates` behavior).
- Ordering between multiple subjects is preserved.

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

## Open Questions

- **Sequencing relative to the UI Smoothness Plan.** Options:
  1. **Smoothness plan first, then this.** Pro: smoothness wins ship sooner; users feel the difference before migration. Con: invest in Task 2.1 (and parts of 1.1) that this plan then makes obsolete — wasted work.
  2. **This plan first, then remaining smoothness tasks.** Pro: no wasted work on tasks that get obsoleted. Con: migration is the higher-risk track; users wait longer for smoothness wins.
  3. **Interleaved.** Land smoothness Tasks 1.2 / 1.3 / 2.2 / 2.3 / 3.2 (the unchanged ones) first; then Phases 0–5 of this plan; then re-evaluate Tasks 1.1 / 2.1 / 3.1.
  - Recommendation: **(3)**. The unchanged smoothness tasks deliver visible wins and don't conflict; the migration removes the work for 2.1 entirely and de-scopes 1.1/3.1.
- **`MonthViewModel` migration timing.** If smoothness Task 1.2 (thumbnail cache) lands first, `MonthViewModel` shrinks significantly. Decide whether to migrate `MonthViewModel` in Phase 2 (current placement) or defer until after Task 1.2 lands.
- **Test fixture for the `exportRunStatePublisher` baseline.** What's the scripted mutation sequence? Should it be the same scenario as the invalidation baseline, or a separate AutoSync-focused script? Phase 5 prerequisite — decide before Phase 5 starts.
- **`@ObservationIgnored` use.** Are there properties on the migrated types that should genuinely not participate in tracking (e.g. private caches, telemetry counters)? Audit during each phase; default to *not* using `@ObservationIgnored` unless there's a demonstrated reason.
- **Whether to migrate `ExportProgressState` independently or fold into `ExportManager`.** With `@Observable`, the granular tracking might make the separate `ExportProgressState` object unnecessary — readers could observe `ExportManager` directly and only re-evaluate on the specific progress field they read. Consider folding back together in Phase 2 or Phase 5 if the separation no longer earns its keep.
