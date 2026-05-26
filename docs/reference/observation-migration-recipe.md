# Observation Migration Recipe

How to convert one `ObservableObject` + `@Published` type to SwiftUI's
`@Observable` while keeping the app building and the tests green. This is
the recipe established by the Phase 2.0 pilot
(`WhatsNewState`) — `docs/project/plans/ui-smoothness-plan.md` §2.0.

The migration order across the codebase lives in the plan; this doc is
the *how*, not the *what-next*.

## Pre-migration check

Before touching the type, grep for the four patterns that mean migrating
in isolation will break a Combine consumer:

```bash
git grep -n "<TypeName>\\.\\$"     # projected-publisher access
git grep -n "<typeProperty>\\.\\$" # same, through an instance
git grep -n "\\.sink" -- "$(git ls-files | xargs grep -l '<TypeName>')"
git grep -n "objectWillChange"
```

If any of those return hits, the type either:

- Needs a Combine bridge (see plan §2.1 — AutoSync seam pattern), or
- Is too entangled for the leaf-pilot path. Pick a different type to
  migrate first.

`WhatsNewState`'s grep returned zero hits across all four patterns, which
is why it was the chosen pilot.

## The class itself

```diff
-import Foundation
+import Foundation
+import Observation

-/// `shouldShow` is `@Published` so the sheet's `isPresented` binding flips
-/// to false synchronously on `markAsSeen()`, …
-@MainActor
-final class WhatsNewState: ObservableObject {
-  @Published private(set) var shouldShow: Bool
+/// `@Observable` (Phase 2.0 pilot for the broader Observation migration).
+/// Per-property tracking means a sheet binding that reads only
+/// `shouldShow` doesn't re-evaluate when `lastSeenVersion` or
+/// `upgradeNotes` mutate — and vice versa.
+@Observable
+@MainActor
+final class WhatsNewState {
+  private(set) var shouldShow: Bool
```

Rules:

- Drop `: ObservableObject` from the class declaration.
- Drop `@Published` from every property — the `@Observable` macro tracks
  every stored property automatically.
- Keep `@MainActor` and `final class` — these are orthogonal to
  Observation and load-bearing per
  [`architecture-conventions.md`](architecture-conventions.md)
  §Actor isolation policy.
- Add `import Observation`.

Methods, computed properties, and inits need no changes.

## App-entry storage

```diff
-  @StateObject private var whatsNewState: WhatsNewState
+  @State private var whatsNewState: WhatsNewState
```

```diff
-    _whatsNewState = StateObject(wrappedValue: WhatsNewState())
+    _whatsNewState = State(wrappedValue: WhatsNewState())
```

`@State` is the correct app-entry storage for `@Observable` reference
types on macOS 15+. The underscore-prefixed `_propertyName = State(...)`
init pattern works identically for both wrappers.

## Injection

```diff
-        .environmentObject(whatsNewState)
+        .environment(whatsNewState)
```

`.environment(_:)` accepts any `@Observable` instance directly — no
keypath, no `WhatsNewState.self` argument. The compiler infers the type
from the instance.

## Consumer side

```diff
-  @EnvironmentObject private var whatsNewState: WhatsNewState
+  @Environment(WhatsNewState.self) private var whatsNewState
```

```diff
-  @ObservedObject var state: WhatsNewState
+  let state: WhatsNewState
```

Three forms by consumer site:

| Old form (Combine)                         | New form (Observation)                                  |
| ------------------------------------------ | ------------------------------------------------------- |
| `@EnvironmentObject var x: T`              | `@Environment(T.self) var x`                            |
| `@ObservedObject var x: T`                 | plain `let x: T` (read-only) or `@Bindable var x: T`    |
| `@StateObject var x: T` (view-owned)       | `@State var x: T`                                       |

The `@Observable` macro instruments the view body so any *read* of an
observed property registers a dependency. No annotation needed for reads.

### Two-way bindings: `@Bindable`

`@Bindable` is required only when the view needs to *write* to a
property through a `Binding`-projecting `$` — e.g.
`TextField("name", text: $state.name)` or
`Toggle(isOn: $state.enabled)`.

`WhatsNewState` had zero such call sites — `WhatsNewView` reads `state`
and calls `state.markAsSeen()`; the sheet's `isPresented` uses a manual
`Binding(get:set:)` not a `$`-projection — so the pilot needed no
`@Bindable`. When a migrated type *does* expose a `$` binding,
`@Bindable` is the swap target for `@ObservedObject`.

## Verification

1. **Build the worktree.** `xcodebuild ... build` must pass without
   warnings. The compiler error if you missed an `@EnvironmentObject` →
   `@Environment` swap is very loud ("…not found in environment"), so
   build-then-test catches the common omission.
2. **Run the type's own tests** — `xcodebuild ... -only-testing:`. Tests
   that read properties via dot-syntax (the typical shape) need no
   changes; tests that called `.objectWillChange` or used Combine
   `.sink` against the projected publisher need rewriting.
3. **Run the full test suite.** A subtle break — `@EnvironmentObject`
   crashing the app because injection wasn't updated at a parent view —
   will surface at runtime in any test that instantiates the view tree.

## What this recipe does NOT cover

- Types with active Combine consumers (`.sink`, `$publisher`, `assign`,
  `removeDuplicates`, AutoSync's synchronous-mirror seam). Those need
  the bridge spike of plan §2.1 first.
- Types where `objectWillChange.send()` is called explicitly. Those
  hand-rolled invalidation paths need a per-call audit before swapping.
- Custom `Combine.Publisher` conformances exposed by the type.
