# Observation Migration Recipe

How to convert one `ObservableObject` + `@Published` type to SwiftUI's
`@Observable`. Established by the Phase 2.0 pilot (`WhatsNewState`) —
`docs/project/plans/ui-smoothness-plan.md` §2.

The migration *order* lives in the plan; this doc is the *how*.

## Pre-migration grep

Before touching the type, scan for patterns that mean an isolated
migration will break a Combine consumer. Any hit disqualifies the type
from the leaf-pilot path — either bridge first (plan §2.1) or pick
another type.

```bash
TYPE='<TypeName>'                # the class being migrated
PROP='<typeProperty>'            # the property name a view writes (lowercased)

# Projected-publisher / KeyPath access ($-projection through type or instance):
git grep -nE "$TYPE\\.\\\$|$PROP\\.\\\$|\\\\\\.\\\$"
# Combine surface exposed by callers:
git grep -nE "\\.sink|assign\\(to:|eraseToAnyPublisher"
# Hand-rolled invalidation:
git grep -nE "objectWillChange|\\.send\\(\\)"
# KVO observers on this type:
git grep -nE "observe\\(\\\\\\.|NSKeyValueObservation"
# Combine surface exposed by the type itself:
git grep -nE "self\\.\\\$|: AnyPublisher|: PassthroughSubject|: CurrentValueSubject|AnyCancellable"
# Generic-parameter constraints that name ObservableObject:
git grep -nE ": ObservableObject\\b|<.*: ObservableObject"
```

`WhatsNewState` returned zero hits across every pattern, which is why it
was the chosen pilot.

## The class itself

```diff
-import Foundation
+import Foundation
+import Observation

-@MainActor
-final class WhatsNewState: ObservableObject {
-  @Published private(set) var shouldShow: Bool
+@Observable
+@MainActor
+final class WhatsNewState {
+  private(set) var shouldShow: Bool
```

- Drop `: ObservableObject` and every `@Published`. The macro tracks all
  stored properties automatically.
- Keep `@MainActor` and `final class` — orthogonal to Observation and
  load-bearing per
  [`architecture-conventions.md`](architecture-conventions.md)
  §Actor isolation policy.
- Add `import Observation` only if the file does not already import
  SwiftUI (SwiftUI re-exports it on macOS 14+).

## Wrapper flips at consumer / storage sites

| Old form (Combine)                    | New form (Observation)                                 |
| ------------------------------------- | ------------------------------------------------------ |
| `@StateObject var x: T` (view-owned)  | `@State var x: T`                                      |
| `StateObject(wrappedValue: T())`      | `State(wrappedValue: T())`                             |
| `.environmentObject(x)`               | `.environment(x)`                                      |
| `@EnvironmentObject var x: T`         | `@Environment(T.self) var x`                           |
| `@ObservedObject var x: T`            | `let x: T` (read-only) or `@Bindable var x: T`         |

`@Bindable` is required only when the view writes through a
`$`-projected binding (`TextField("name", text: $state.name)`). Plain
reads need no annotation — the `@Observable` macro instruments view
bodies so every property access registers a tracked dependency. A
manual `Binding(get:set:)` whose `get` reads the property also tracks
correctly because the closure runs inside the enclosing body's
`withObservationTracking` scope.

## Verify that the macro actually instrumented the property

The state-machine tests pass whether or not `@Observable` fired; they
exercise values, not tracking. Add one tracking-contract test per
migrated type so a future refactor that breaks the macro (e.g. someone
adds `@ObservationIgnored` by accident) fails loudly:

```swift
@Test func mutationsRegisterAsTrackedChange() async {
  let state = WhatsNewState(/* ... */)
  let counter = ObservationCounter { _ = state.shouldShow }

  state.markAsSeen()  // shouldShow: true → false (a value change)

  let count = try await counter.waitForNextChange()
  #expect(count == 1)
}
```

`ObservationCounter`
(`photo-exportTests/TestHelpers/ObservationCounter.swift`) re-registers
after each fire and has a built-in timeout, so a property that *isn't*
tracked surfaces as a timeout, not a hang.

### Important: mutations have to produce a value change

`withObservationTracking`'s observers are notified on willSet only when
the new value differs from the old (the macro fires willSet
unconditionally, but the tracking framework deduplicates by value).
Confirmed empirically while migrating `LoginItemController`: calling a
method that re-reads from the same upstream source and writes the same
value back does not fire the observer, even though the assignment did
run.

For types whose production mutation paths cannot deterministically
produce a value change in a test environment (e.g. wrappers around
`SMAppService` or similar system services that return the same value
when called from tests), add a small `#if DEBUG`-gated mutation seam:

```swift
#if DEBUG
  func setStatusForObservationTracking(_ newStatus: Status) {
    status = newStatus
  }
#endif
```

The test then forces a known value transition and uses
`withObservationTracking` directly (synchronous, simpler than the async
`ObservationCounter` for the single-mutation case):

```swift
@Test func statusMutationFiresTrackedObserver() {
  let controller = LoginItemController()
  let initial = controller.status
  var observedChange = false
  withObservationTracking {
    _ = controller.status
  } onChange: {
    observedChange = true
  }

  let next: LoginItemController.Status = (initial == .enabled) ? .notFound : .enabled
  controller.setStatusForObservationTracking(next)

  #expect(observedChange)
}
```

## Verification checklist

1. **Build the worktree.** A missed `@EnvironmentObject` → `@Environment`
   swap surfaces as a noisy compile error.
2. **Run the type's own tests + the one tracking-contract test above.**
3. **Run the full test suite.** Catches view-tree instantiation paths
   that crash on missing environment.
