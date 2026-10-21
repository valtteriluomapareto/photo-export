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
Settings and the menu-bar extra all get their environment from `photoExportEnvironment(_:)` in
`photo-export/App/AppCore.swift`, and sheets in `LibraryRootView` and `AutoExportSettingsView`
re-inject some objects. Flip every injection site of the type at once, and have
`AppCoreTests.sceneEnvironmentComesFromTheComposition` read the type through
`photoExportEnvironment(_:)` and check it is the core's instance. That test covers only what
the helper injects: every scene root must call `photoExportEnvironment(core)`, and a sheet
that re-injects the type needs its own hosted test.

When `AppCore` (or an object it owns) owns the instance, `PhotoExportApp` drops its
`@StateObject` instead of flipping it to `@State`; the core keeps the object alive.

## Types with Combine subscribers: the bridge

A property whose named accessor has subscribers keeps `@Published` delivery through
`ObservableCombineBridge` (`photo-export/Helpers/ObservableCombineBridge.swift`). It is a
plain class, not a macro: the owner writes the property by hand around it.
`ObservableCombineBridgeTests` and the parity tests check these rules.

- **The bridge holds the value,** and the getter returns it. Nothing reads a
  `CurrentValueSubject`'s `value`: `send` updates it before delivering, while `@Published`
  sinks read the *old* value.
- **Replay comes from the stored value,** through the bridge's own subscription, not a
  subject. A `CurrentValueSubject` replays the value in flight to a subscription made inside a
  sink (`PublishedParityHelperTests.subjectReplayFailsNestedReplay`). A `Deferred` `prepend`
  onto a `PassthroughSubject` joins the subject only after the replay, so a write made while
  the subscriber receives its replay never reaches it, and keeps nothing for a subscriber
  without demand (`prependReplayFailsWritesDuringReplayAndHeldValues`). The bridge's
  subscription joins before it replays.
- **Demand, as `@Published` handles it.** A value is delivered only while the subscriber has
  demand. Otherwise one value is kept per subscriber, the latest write winning, and delivered
  when it next requests. Demand a subscriber returns from `receive` is recorded without
  delivering the kept value: the next write replaces it, so it never arrives after a newer one.
  Every delivery goes through one path that clears the kept value.
- **Cancellation stops delivery at once, from any thread; the release happens on main.** A
  cancelled subscriber receives nothing more, not even the write in flight when another
  subscriber's sink cancelled it, nor a write made on the main actor before a cancel from
  another thread has reached the main queue (a lock-protected flag). On the main queue the
  bridge drops the subscription, and the subscription drops the subscriber. `@Published` also
  skips the write in flight when the cancelling sink is delivered first, but its fan-out order
  varies between instances; the bridge delivers in subscription order.
- **Consumers must not depend on fan-out order** between subscribers of one accessor.
- **Setter order:** `withMutation` (willSet) → deliver → store. A write made inside a sink is
  delivered at once and stored first, so the outer write's value ends up stored, as with
  `@Published` (`assertSubscriberEdgeParity`'s re-entrant check).
- **While the type is still `ObservableObject`** (plumbing a bridge in before the flip),
  `objectWillChange.send()` comes first, on every write, as `@Published` sends it. Keep the
  synthesized `objectWillChange`: it stays one publisher when no `@Published` is left, and
  `@Published` does not send to a hand-declared one
  (`ownerWithoutPublishedKeepsOneObjectWillChange`,
  `publishedDoesNotSendToAHandDeclaredObjectWillChange`).
- **Every write is delivered,** including one that stores the value already held:
  `@Published` emits on unchanged writes, and accessors that drop repeats do so with an
  explicit `removeDuplicates()`.
- **An equal write does not notify Observation.** The bridge skips `withMutation` when the new
  value equals the stored one, as the `@Observable` macro does for an `Equatable` property
  (`ObservationEqualWriteTests`). While the type is still `ObservableObject`, the equal write
  still sends `objectWillChange`, so a view that refreshes through it today still does.
- **Main actor only.** The bridge is `@MainActor`, like its owners; subscribing or requesting
  demand off the main actor traps. Cancelling off the main actor is allowed, as with
  `@Published` (an `AnyCancellable` released in a background deinit). Never `.receive(on:)`
  or a `MainActor` hop in the bridge's delivery or an accessor; AutoSync and the mirrors rely
  on synchronous delivery.
- **Side effects run after the write,** where `didSet` ran: after delivery and store.

  ```swift
  var versionSelection: ExportVersionSelection {
    get { bridgedRead(versionSelectionBridge, \.versionSelection) }
    set {
      bridgedWrite(versionSelectionBridge, \.versionSelection, newValue)
      userDefaults.set(newValue.rawValue, forKey: Self.versionSelectionDefaultsKey)
      clearEmptyRunMessage()
    }
  }
  ```

- **Each newly bridged property gets an `ObservationProbe` test** that writes only that
  property through a real mutation path and checks that the probes on its bridged siblings stay
  at 0, so a key path passed to the wrong bridge fails.

**While the owner is still `ObservableObject`** (`ExportManager` today), it conforms to
`Observable` by hand and holds its own registrar:

```swift
@MainActor
final class ExportManager: ObservableObject, Observable {
  private(set) var isRunning: Bool {
    get { bridgedRead(isRunningBridge, \.isRunning) }
    set { bridgedWrite(isRunningBridge, \.isRunning, newValue) }
  }
  private let isRunningBridge = ObservableCombineBridge(false)

  private let observationRegistrar = ObservationRegistrar()

  private func bridgedRead<Value>(
    _ bridge: ObservableCombineBridge<Value>, _ keyPath: KeyPath<ExportManager, Value>
  ) -> Value {
    observationRegistrar.access(self, keyPath: keyPath)
    return bridge.value
  }

  private func bridgedWrite<Value>(
    _ bridge: ObservableCombineBridge<Value>, _ keyPath: KeyPath<ExportManager, Value>,
    _ newValue: Value
  ) {
    objectWillChange.send()
    bridge.write(newValue) { observationRegistrar.withMutation(of: self, keyPath: keyPath, $0) }
  }
}
```

The accessor reads the bridge: `isRunningBridge.publisher`, or a combination such as
`Publishers.CombineLatest4(activeRunContextBridge.publisher, isRunningBridge.publisher, …)`.
`$isRunning` no longer exists, so a missed subscriber is a compile error.

**After the flip** the macro supplies the registrar. Drop `objectWillChange`, the registrar
and the helpers, and keep the hand-written property (the macro leaves computed properties and
`let`s alone):

```swift
@Observable
@MainActor
final class ExportManager {
  private(set) var isRunning: Bool {
    get {
      access(keyPath: \.isRunning)
      return isRunningBridge.value
    }
    set { isRunningBridge.write(newValue) { withMutation(keyPath: \.isRunning, $0) } }
  }
  private let isRunningBridge = ObservableCombineBridge(false)
}
```

`ObservableCombineBridgeTests` runs the same contract over both shapes: `@Published` parity
(`assertPublishedParity` and `assertSubscriberEdgeParity`); Observation notified before
delivery; an equal write delivered without an Observation notification; and, while plumbed,
`objectWillChange` before every delivery.

### `ExportManager`: the run-state bridge

The four inputs of `exportRunStatePublisher` (`activeRunContext`, `isRunning`, `queueCount`,
`isEnqueueingAll`) are bridged in the plumbing shape above. `ExportManagerObservationTests`
shows that each property, and each input of the derived reads views make
(`hasActiveExportWork`, `canTogglePause`, `manualExportShouldConfirmSupersede`), registers a
dependency, and that a view holding the manager as a plain `let` refreshes for queued work. An
idle teardown rewrites every input with its current value: Observation stays silent, and
`objectWillChange` fires once per write, as with `@Published`, and before the bridged
delivery.

The flip still owes:

- bridges for the other contract accessors (`versionSelection`, `convertHEICToJPEG`,
  `livePhotosPairedExport`, `isImporting`, `previousBackupMissing`, `importStage`), and for a
  coordinator's mirrored properties if `ExportQueueCoordinator` or `ImportCoordinator` flips;
- a mirror or a dependency for every read-through property that stops refreshing once
  `objectWillChange` is gone: `pendingJobs`, `currentTask`, `queuedCountsByPlacementId`,
  `isProcessing` and `queuedCount(year:month:)` read the coordinator's unpublished state, and
  `canExportTimeline` / `canExportCollection` read the record stores' `state`, which refreshes
  views today only because they also observe the stores (until the stores flip, or a
  dependency test covers them);
- `@ObservationIgnored` on the collaborators, IUOs, caches and tasks;
- the wrapper and injection flips.

## Tests

- **Parity per property.** `assertPublishedParity(object, \.property, { $0.propertyPublisher },
  change:, unchangedWrite:)` (`photo-exportTests/TestHelpers/PublishedParity.swift`) pins, for
  one accessor: synchronous replay of the current value; every delivery arriving before the
  change returns and before the value is stored (a sink reading the property sees the
  previously delivered value); a subscription made inside the sink replaying the stored value,
  missing the delivery in flight and receiving later ones; a new subscription to the same
  publisher instance replaying the current value (proven only when `change` ends on a value
  other than the start); and what an unchanged write delivers. That is a repeat for a plain
  `$property`, nothing for an accessor that removes repeats or a mutation path that skips
  equal writes (`.isDropped`, which pins the `if value != new` guard). Derived accessors
  (`exportRunStatePublisher`, `isImportingPublisher`, `destinationSnapshotPublisher`) use the
  overload that takes a `value` closure combining the inputs. Drive everything through the
  type's real mutation paths; where no path leaves the value unchanged, say why with
  `.notDrivable(_:)` rather than adding a production test hook. `PublisherParityTests` is a
  regression gate and does not change in a flip; `PublishedParityHelperTests` shows which
  check fires for each wrong storage shape.
- **Subscriber edge cases.** `assertSubscriberEdgeParity` pins, on a fresh subject with two
  synchronous writes: a write made while a subscriber receives its replay reaches it; a write
  made inside a sink is delivered at once while the outer value ends up stored; a subscriber
  without demand receives only the latest value once it asks; a write made during a replay
  that used up the demand arrives once, in order, on the next request; demand returned from
  `receive` does not deliver a kept value, and a newer write replaces it; one unit of demand
  takes the next write only; a subscriber returning one more with each value gets every write.
  `@Published` passes it (`PublishedParityHelperTests.publishedPasses`), and so does the
  bridge. It is separate from `assertPublishedParity` because not every accessor's real
  mutation path is synchronous.
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
  reference write do not notify, and a non-`Equatable` write does. Recorded on Xcode 27.1; CI
  runs it on `.xcode-version` (26.6) and on the 27.1 canary, so a toolchain whose behaviour
  differs fails it. The Combine side does not depend on it: the bridge publishes every write, as
  the parity tests require.
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
