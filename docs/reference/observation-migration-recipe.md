# Observation Migration Recipe

How one `ObservableObject` + `@Published` type moves to SwiftUI's `@Observable`, and what has
to be true before and after. The order of types and the decisions behind it live in
[issue #315](https://github.com/valtteriluomapareto/photo-export/issues/315); this page is
the how.

Read [`architecture-conventions.md`](architecture-conventions.md) §AutoSync seam preservation
first. A type AutoSync, the destination adapter or the lifecycle/safety monitors subscribe to
carries a Combine contract, and the flip must not change a single delivery.

## Before the flip

1. **Subscribers use a named accessor.** Every subscription from outside the type goes through
   an `AnyPublisher` accessor on the owner (`identityPublisher`, `isAvailablePublisher`,
   `migrationConflictPublisher`, `importStagePublisher`, …), never `owner.$property`. The
   owner's own `$property` uses may stay until the flip. `ExportQueueCoordinator` and
   `ImportCoordinator` stay `ObservableObject`, so the coordinator → manager mirror sinks in
   `ExportManager` stay as they are.
2. **The accessor has a parity test.** `PublisherParityTests` runs `assertPublishedParity` on
   every named accessor against today's `@Published` storage. Those tests do not change in the
   flip; if one fails afterwards, the flip changed what subscribers see.
3. **Hidden dependencies have hosted liveness tests.** A view read that refreshes today only
   because another property of the same object invalidates the whole object (for example
   `MonthRow` reading `exportManager.queuedCount`, the record-store queries over unpublished
   dictionaries, `thumbnailContentRevision`) stops refreshing under Observation unless the read
   touches a tracked property. Write a hosted test that the view updates when the underlying
   value changes before the flip. The same goes for `let` holders that will start observing
   (`ContentView`'s `destinationManager` / `recordStore`, `CollectionsSidebarView`'s manager):
   pin that they still do not re-render for unrelated changes.
4. **Find the remaining Combine surface.**

   ```bash
   TYPE='TypeName'
   git grep -nE "\b$TYPE\b" -- photo-export photo-exportTests | grep -E 'ObservedObject|EnvironmentObject|StateObject|environmentObject'
   git grep -nE 'objectWillChange|\.\$[a-zA-Z]' -- photo-export photo-exportTests
   git grep -nE ': ObservableObject\b|<[^>]*: ObservableObject' -- photo-export
   ```

## The class

```diff
-@MainActor
-final class WhatsNewState: ObservableObject {
-  @Published private(set) var shouldShow: Bool
+@Observable
+@MainActor
+final class WhatsNewState {
+  private(set) var shouldShow: Bool
```

- Drop `: ObservableObject` and every `@Published`; the macro tracks every stored property.
- Keep `@MainActor` and `final class` (§Actor isolation policy).
- Mark everything that is not view state `@ObservationIgnored`: caches, collaborators and
  services, `AnyCancellable`s and tasks, `lazy` properties, implicitly unwrapped collaborators
  (`var coordinator: Coordinator!`), loggers and stores. A tracked internal turns every write
  to it into a view invalidation, and `lazy` / IUO properties don't compile under the macro.
- Public queries over ignored storage (the record stores' dictionaries) must touch a tracked
  property, such as `mutationCounter`, so a view that calls them registers a dependency and the
  existing notification coalescing still decides when it refreshes.
- `@Observable` on an `NSObject` subclass (`PhotoLibraryManager`,
  `PhotoLibraryPersistentChangeAdapter`) needs a check that KVO-backed and `@objc` members
  still behave; flip those last in their slice.
- `init` must do no work a view would repeat: `@State` builds a new instance on every view
  init and keeps only the first, so service calls, subscriptions and tasks belong in `.task`
  or an explicit `start()`.

## Wrapper flips

| Old (Combine)                         | New (Observation)                                      |
| ------------------------------------- | ------------------------------------------------------ |
| `@StateObject var x: T`               | `@State var x: T`                                      |
| `StateObject(wrappedValue: T())`      | `State(wrappedValue: T())`                             |
| `.environmentObject(x)`               | `.environment(x)`                                      |
| `@EnvironmentObject var x: T`         | `@Environment(T.self) var x`                           |
| `@ObservedObject var x: T`            | `let x: T` (reads only) or `@Bindable var x: T`        |

`@Bindable` is needed only where the view makes a binding through `$x.property`
(`Toggle(isOn: $exportManager.includeOriginals)`). Plain reads register a dependency without
any wrapper.

A missing `.environment(T.self)` is a runtime crash, not a compile error. The main window,
Settings and the menu-bar extra each inject their own environment in
`photo-export/App/photo_exportApp.swift`, and sheets in `LibraryRootView` and
`AutoExportSettingsView` re-inject some objects. Flip every injection site of the type at once,
and cover every scene root with a hosted render test that is built the way the app builds it.

## Types with Combine subscribers: the bridge

A property whose named accessor has subscribers keeps `@Published` delivery through a
hand-written bridge (`ObservableCombineBridge`): the value plus a `CurrentValueSubject`. These
rules come from the plan review and the parity tests check them:

- **Storage:** the value lives in its own storage. The getter never reads
  `CurrentValueSubject.value`: `send` updates `.value` before delivering, while `@Published`
  sinks read the *old* value. (`PublishedParityHelperTests.subjectValueGetterFails` shows the
  parity helper catching exactly this.)
- **Setter order:** `withMutation` (willSet) → publish → store. Replay to a new subscriber comes
  from the stored value, so a subscription made inside a sink replays the previous value.
- **While the type is still `ObservableObject`** (plumbing a bridge in before the flip),
  `objectWillChange.send()` comes before the subject's send.
- **Every write is published,** including one that stores the value already held: `@Published`
  emits on unchanged writes, and accessors that drop repeats do so with an explicit
  `removeDuplicates()`.
- Never `.receive(on:)` or a `MainActor` hop in the bridge or an accessor; AutoSync and the
  mirrors rely on synchronous delivery.

Bridge contract tests: a read inside the sink returns the old value; a subscribe nested inside
a sink is replayed; willSet comes before the Combine send; emission is synchronous; an
unchanged write emits; a `withObservationTracking` `onChange` fires.

## Tests

- **Parity per property.** `assertPublishedParity(object, \.property, { $0.propertyPublisher },
  change:, unchangedWrite:)` (`photo-exportTests/TestHelpers/PublishedParity.swift`) pins, for
  one accessor: synchronous replay of the current value; every delivery arriving before the
  change returns and before the value is stored (a sink reading the property sees the
  previously delivered value); a subscription made inside the sink replaying the stored value,
  missing the delivery in flight and receiving later ones; and what an unchanged write
  delivers. That is a repeat for a plain `$property`, nothing for an accessor that removes
  repeats or a mutation path that skips equal writes (`.isDropped`, which pins the
  `if value != new` guard). Derived accessors (`exportRunStatePublisher`,
  `isImportingPublisher`, `destinationSnapshotPublisher`) use the overload that takes a `value`
  closure combining the inputs. Drive everything through the type's real mutation paths; where
  no path leaves the value unchanged, say why with `.notDrivable(_:)` rather than adding a
  production test hook. `PublisherParityTests` is a regression gate and does not change in a
  flip; `PublishedParityHelperTests` shows which check fires for each wrong storage shape.
- **Dependency registration.** `ObservationProbe` (`TestHelpers/ObservationProbe.swift`) counts
  `withObservationTracking` notifications synchronously and re-registers after each one, so a
  test can assert straight after a write: for example, a record-store query's `onChange` fires
  after `flushPendingNotifications()` and not before. Its read closure must read a fixed set
  of properties, because re-registration runs during willSet and sees old values.
- **No `withKnownIssue` in gate suites.** An expected failure does not pass
  `check-regression-gates-ran.py`. Dependency-registration and tightening assertions that wait
  for a flip live in separate, non-gate suites.
- **"Only tighten" for body-invalidation tests:**
  - upper bounds on invalidation counts may only go down;
  - "must re-render or update" assertions may never be removed or weakened;
  - an exact `==` may only be dropped, with the reason in the test.

  Improvements a flip will bring are added first as new assertions under `withKnownIssue`; the
  flip removes the wrapper.
- **Gate files** change only in their subscription expression (`$x` → accessor); no assertion,
  expected value or fixture changes, and the accessor's parity test lands in the same PR.
- **Equal-value writes and the toolchain.** Whether Observation notifies on a write that
  stores an equal value depends on the toolchain. `ObservationEqualWriteTests` records what
  the toolchain that builds the tests does: an equal `Equatable` write and an identical
  reference write do not notify, and a non-`Equatable` write does (recorded on Xcode 27.1; CI
  runs it on the toolchain in `.xcode-version`). A toolchain
  bump that changes this fails there first (the 27.1 canary runs it). The Combine side does not
  depend on it: the bridge publishes every write, as the parity tests require.
- **Each flip runs:** the build (a missed `@EnvironmentObject` → `@Environment` swap is a
  compile error; a missed injection is not), the type's own tests, `PublisherParityTests`, the
  hosted suites for every view that reads the type (also repeated with
  `-test-iterations 10 -run-tests-until-failure` and compared with the baseline below), the
  full suite and `check-regression-gates-ran.py`, with gates run without re-recording.

## The ratchet

[`scripts/ci/check-observation-ratchet.py`](../../scripts/ci/check-observation-ratchet.py)
holds `photo-export/` to [`scripts/ci/observation-ratchet.txt`](../../scripts/ci/observation-ratchet.txt):
`ObservableObject` types and external `$property` uses per file, and repository totals of
`@Published`, `.environmentObject(`, `@EnvironmentObject`, `@StateObject`, `@ObservedObject`
and external `objectWillChange`. A flip lowers or removes its rows in the same change; the
guard fails until it does, and fails on any new old-pattern use, including one arriving from
main at a sync. See [`scripts/README.md`](../../scripts/README.md).

When it was introduced it counted 18 `ObservableObject` types. The plan's inventory said 19;
no 19th conformance exists in `photo-export/` (17 are single-line `class` declarations, and
`PhotoLibraryPersistentChangeAdapter` wraps its conformance onto the next line). The four
test-local `ObservableObject` types in `photo-exportTests/` are not counted.

## Hosted-suite flake baseline

Recorded on local Xcode 27.1 (macOS 26.6), before any type flipped, over the hosted
observation suites plus `PublisherParityTests` and `ObservationProbeTests`. With
`-test-iterations 10 -run-tests-until-failure` the first run stopped at the iteration where
`CollectionContentObservationTests.unrelatedQueuePublicationsDoNotRescanLoadedCollection`
failed (497 test runs, that one failure). Rerun with that test skipped, all 10 iterations ran
clean (45 tests, 490 test runs). That test fails on every iteration when its suite runs alone,
on main as well, so it is a known failure rather than a flake:
[issue #344](https://github.com/valtteriluomapareto/photo-export/issues/344). Re-record the
baseline on the CI toolchain before comparing a flip against it. Resolving #344 is an entry
condition for flipping `PhotoLibraryManager` and the record stores.
