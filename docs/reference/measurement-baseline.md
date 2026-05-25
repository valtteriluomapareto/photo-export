# Smoothness Measurement Baseline

How to reproduce a baseline trace for the UI smoothness work in
[`../project/plans/ui-smoothness-plan.md`](../project/plans/ui-smoothness-plan.md).

The goal is repeatable signal — not perfect profiling — so later PRs can compare
"before/after" with confidence. Land any invasive refactor only when the
measurement says it should move.

## Prerequisites

- Local Debug build of `photo-export`.
- macOS 15.x with the Photos library you usually develop against.
- Instruments (bundled with Xcode 16). The "os_signpost" template is enough.

## What's instrumented

Signposters share the `com.valtteriluoma.photo-export` subsystem so Instruments
groups them under one app entry.

| Category                            | Owner                                                  | Records                              |
| ----------------------------------- | ------------------------------------------------------ | ------------------------------------ |
| `AppLifecycle`                      | `App/AppDiagnostics.swift`                             | `AppLaunch` interval, `SelectionChanged` event |
| `Export.Run`                        | `Export/ExportQueueCoordinator.swift`                  | `ExportRun` interval                 |
| `PhotoLibraryChanges.CatchUp`       | `PhotoLibrary/PhotoLibraryPersistentChangeAdapter.swift` | `CatchUp`, `FetchPersistentChanges`, `EnumerateChanges` intervals |

A debug-only `BodyInvalidationCounter` (`App/BodyInvalidationCounter.swift`)
counts SwiftUI body re-evaluations for views wired with the
`.measureBodyInvalidations("…")` modifier:

- `MonthContentView`
- `CollectionContentView`
- `TimelineSidebarView`
- `CollectionsSidebarView`

Read from a debug REPL (`po BodyInvalidationCounter.shared.snapshot()`) or
inside an XCTest that exercises the view tree.

## Baseline scenario

A single repeatable walk through the app:

1. **Launch.** From a cold start (`killall "Photo Export"` first), open the
   app. Instruments records the `AppLaunch` interval automatically.
2. **Select a large month.** In the Timeline sidebar, pick a month with ~10k
   assets. (Use the bulk fixture in tests; in the real app, choose the
   largest available month for a consistent baseline.) Instruments records a
   `SelectionChanged` event with `kind=month`.
3. **Start a 200-asset export.** Trigger "Export Month" on the same month.
   Either narrow the month so the queue holds ~200, or stop the export after
   200 jobs to keep the interval bounded. Instruments records an `ExportRun`
   interval.
4. **Observe.** While the export drains, record:
   - sidebar row repaints (visual, plus `TimelineSidebarView` body count),
   - grid cell repaints (`MonthContentView` body count),
   - toolbar refresh rate,
   - export-progress UI updates.

## What to record

For each measurement run, capture:

- App version / commit SHA.
- Library asset count and the selected month's asset count.
- `AppLaunch` duration.
- `ExportRun` duration.
- Body invalidation counts for the four wired views (start-of-scenario reset
  via `BodyInvalidationCounter.shared.reset()`; final snapshot at the end).
- Subjective notes — frame drops, freezes, blanks.

A short markdown file under `docs/project/` per measurement run is the right
home for the numbers. Don't churn this reference file with run-specific data.

## Limitations

- Scroll-session signposts are not yet emitted; SwiftUI has no clean per-scroll
  lifecycle hook on macOS. Phase 1+ measurements can rely on visual inspection
  and frame-drop counters in Instruments' Core Animation track until a better
  seam exists.
- `BodyInvalidationCounter` is gated behind `#if DEBUG`. Release builds compile
  the modifier to identity and pay nothing.
- `ObservationCounter` (`photo-exportTests/TestHelpers/ObservationCounter.swift`)
  is the corresponding test-side primitive for Phase 2 Observation migration
  work — see the plan for usage.
