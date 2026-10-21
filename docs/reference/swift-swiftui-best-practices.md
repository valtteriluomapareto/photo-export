# Swift and SwiftUI Best Practices

Use this guide when writing code or reviewing changes. The
[architecture reference](architecture-conventions.md) owns the role map, data flow,
state ownership and export contracts; the
[contributor guide](../../CONTRIBUTING.md) owns commands and workflow.

## 1) Architecture & Project Structure

Follow the [module responsibilities](architecture-conventions.md#module-responsibilities)
when placing new code. Keep business logic out of SwiftUI bodies and use app-owned
value types at service boundaries. Prefer narrow injected protocols for external
operations; the [protocol directory](../../photo-export/Protocols/) is the current
inventory. Keep classes final unless subclassing is an intentional requirement,
and give helpers the smallest useful visibility.

## 2) Swift Concurrency

Use the [actor isolation policy](architecture-conventions.md#2-actor-isolation-policy)
for collaborators and helpers. UI state belongs on the main actor; pure policies
remain plain values. For example, this complete declaration keeps observable state
main-bound:

```swift
import Combine

@MainActor
final class LibraryStatus: ObservableObject {
  @Published private(set) var assetCount = 0

  func updateCount(_ count: Int) {
    assetCount = count
  }
}
```

In a view, use `.task(id:)` for a load owned by the view's identity or query inputs.
Check cancellation and ownership before publishing a result. For visible library
revisions, refresh in place as described below. Export work follows the
[generation contract](architecture-conventions.md#1-cancellation-contract), and
detached I/O uses `runDetached` to propagate cancellation and wait for physical work.
An `await` alone does not prove that synchronous work leaves the main actor.

Prefer main-actor isolation to manually dispatching UI writes. In particular, keep
coordinator-to-manager mirrors synchronous: introducing `MainActor.run`, an async
queue or `.receive(on:)` there breaks the
[AutoSync seam](architecture-conventions.md#3-autosync-seam-preservation).

## 3) Photos Framework Best Practices

- Keep Photos access read-only. Authorization and fetching belong behind the
  library service; handle denied, restricted and limited access explicitly.
- Track assets by `PHAsset.localIdentifier`, and use descriptors outside the
  PhotoKit implementation. Existing callers and supported requests are defined by
  [`PhotoLibraryService`](../../photo-export/Protocols/PhotoLibraryService.swift).
- Keep enumeration bounded and cancellation-aware. Use the existing progressive
  stream and count-cache seams instead of adding synchronous large-library work
  to a view or the main actor.
- Use `PHCachingImageManager` and the decoded thumbnail cache through the existing
  library methods. Balance each consumer's preheating registrations.
- Export bytes through the resource/render/conversion seams rather than thumbnail
  requests. [`ResourceSelection`](../../photo-export/Export/ResourceSelection.swift)
  owns edited-producer selection, including the edited-video render path.

## 4) Export Pipeline (Robustness Checklist)

Use the [export and record owners](architecture-conventions.md#export-and-record-owners)
to find the implementation to extend. Check these contracts when reviewing a change:

- Admission preserves import conflicts, store readiness and destination availability.
- Job settings use the [canonical entry-point capture policy](architecture-conventions.md#canonical-start-entry-point-shape).
- Every async mutation follows the [generation cancellation contract](architecture-conventions.md#1-cancellation-contract).
- Byte producers and cleanup follow the [final commit boundary](architecture-conventions.md#final-file-commit-boundary).
  Filename allocation alone does not protect the commit from a collision; the
  contract documents exclusive rename and the check-then-move filesystem limits.
- Record reads, writes, cleanup and reuse probes go through `RecordStoreRouter`;
  completion and fallback decisions go through `ExportCompletionPolicy`.
- Destination state keys on the [stable logical id](architecture-conventions.md#destination-identity).
- Auto Export keeps the [behavior reference](auto-export-behavior.md) and existing
  [regression gates](architecture-conventions.md#regression-gates) intact.

Bounded export parallelism remains an idea in the
[GitHub backlog](https://github.com/valtteriluomapareto/photo-export/issues/318#issuecomment-6311950302).
It requires a separate plan preserving cancellation and final-file ownership.

## 5) SwiftUI View Best Practices

Prefer `NavigationSplitView` for the macOS sidebar/detail structure. Derive values
from their owners and keep local `@State` limited to state the view owns.

A task identity must conform to `Equatable`; use a named value for several inputs.
This complete example accepts a load action without inventing another library API:

```swift
import SwiftUI

struct MonthKey: Equatable, Sendable {
  let year: Int
  let month: Int
}

@MainActor
struct MonthTaskExample: View {
  let key: MonthKey
  let load: @MainActor (MonthKey) async -> Void

  var body: some View {
    Text("\(key.year)-\(key.month)")
      .task(id: key) {
        await load(key)
      }
  }
}
```

Use that pattern for scope changes. A Photos `libraryRevision` instead calls
`MonthViewModel.refresh(for:)` from `.onChange` to update the visible grid in place.
Keep surviving selections and reject superseded results. Thumbnail and detail tasks
use per-asset content revisions. See the full
[preview ownership contract](architecture-conventions.md#preview-content-ownership)
and the maintained [`MonthContentView`](../../photo-export/Views/Timeline/MonthContentView.swift)
and [`CollectionContentView`](../../photo-export/Views/Collections/CollectionContentView.swift).
Do not replace these refresh handlers with a revision-keyed full grid load.

Pass action-only dependencies as plain references or closures from an observing
parent. Subscribe through `@EnvironmentObject` or `@ObservedObject` when the body
reads the object's state. The hosted observation tests show that `@AppStorage` can
rebuild an otherwise action-only view with its parent; keep it out of those leaves,
or use the established `Equatable`/`.equatable()` pattern.
`AutoSyncAwareExportButton` remains a deliberate exception pending Observation work.

Extract complex sections, keep expensive object creation out of `body`, reuse
formatters, and use lazy grids for thumbnails. Label icon-only status indicators
and provide accessible controls.

## 6) Error Handling & User Messaging

Handle errors at the owning boundary and provide actionable user messages. Preserve
error domains/codes used by retry classification and persisted signatures when
wrapping errors. Use existing presentation surfaces for the owning feature rather
than introducing another alert system. Record recoverable failures with enough
context to diagnose them.

## 7) Logging & Instrumentation

Use Unified Logging through `os.Logger` and the shared `Logger.app` helper.
Inside the app target, use the existing named category for the operation:

```swift
import os

func logAssetCount(_ count: Int) {
  let logger = Logger.app(.photos)
  logger.info("Fetched \(count) assets")
}
```

Use existing categories when investigating an issue. Signposts and Instruments can
measure work around resource production, persistence and thumbnail loading.

## 8) Performance & Memory

Keep enumeration batches bounded, cooperate with cancellation, and yield where the
existing pipeline does so. Avoid wall-clock delays as a substitute for ownership
or readiness. Reuse thumbnail caches and formatters, avoid redundant model copies,
and measure work before moving it to another actor or adding parallel exporters.

## 9) Code Style & API Design

Use verbs for functions and clear parameter labels. Prefer immutable values and
private helpers; use `public` only for an actual external API. Avoid force unwraps
unless an established initialization pattern requires them. Document reasons and
contracts that are not evident from the code.

Style thresholds and exclusions live in [`.swiftlint.yml`](../../.swiftlint.yml),
and formatter settings in [`.swift-format.json`](../../.swift-format.json). Run the
strict [contributor commands](../../CONTRIBUTING.md#local-setup) with the formatter's
explicit configuration path.

## 10) Photos Change Handling

Preserve the existing change-observer and persistent-change adapter boundaries.
Refresh UI descriptors without clearing visible grids, and reconcile a deleted
selection from an owned successful result. Follow the
[preview contract](architecture-conventions.md#preview-content-ownership) for image
revision checks and the [Auto Export reference](auto-export-behavior.md) for dirty
work, acknowledgement and reconciliation rules.

## 11) Testing Matrix (Must-Haves)

Use injected fakes for platform operations, isolated `TestScratch` preferences and
folders, pure policy tests for combinatorial behavior, and hosted SwiftUI tests
for bindings and rendered actions. See the
[contributor test strategy](../../CONTRIBUTING.md#ui-behavior-test-strategy) and
[release validation guide](../project/release-validation.md) for the automated/manual
boundary.

Relevant scenarios include authorization changes, large and iCloud-optimized
libraries, destination disconnects and permissions, filename collisions, interrupted
exports, and cancellation during image loading. Preserve the named regression
gates; do not re-record them without auditing the behavior change.

## 12) Example: Main-Actor-safe state updates

For the actual loading, error, selection and cancellation flow, read
[`MonthViewModel`](../../photo-export/ViewModels/MonthViewModel.swift) and its
[`MonthViewModelTests`](../../photo-exportTests/MonthViewModelTests.swift).
Keeping this example in the implementation avoids a second model with outdated
library calls or weaker ownership checks. The standalone examples above demonstrate
only isolated language/UI patterns.

## 13) References

- [Architecture and contracts](architecture-conventions.md)
- [Auto Export behavior](auto-export-behavior.md)
- [Persistence format](persistence-store.md)
- [Contributor setup and workflow](../../CONTRIBUTING.md)
