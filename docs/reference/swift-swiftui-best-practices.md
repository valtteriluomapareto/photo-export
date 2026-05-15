# Swift and SwiftUI Best Practices

This guide distills proven Swift and SwiftUI patterns for building a robust, scalable Photos backup/export app on macOS.

Use this document as a checklist when writing code or reviewing PRs.

---

## 1) Architecture & Project Structure

- Prefer clear layering:
  - **Views (SwiftUI)**: Stateless UI, render from inputs; no business logic.
  - **ViewModels (ObservableObject)**: State, UI-friendly transformations, side-effects orchestration.
  - **Records/ AutoSync/ PhotoLibrary/ Managers/**: stateful services and pure helpers split by feature area (record stores; auto-export state machine; PhotoKit access; export pipeline / destination / orchestration).
  - **Models**: Plain value types and domain types.
- Keep each view in its own file. Avoid multiple large `View` types in one file (e.g., move `MonthView` out of `ContentView.swift`).
- Make types `final` by default unless subclassing is intended. Mark helpers `private` and prefer `internal` over `public` unless needed.
- Prefer protocol-driven boundaries for testability. The app uses `PhotoLibraryService`, `AssetResourceWriter`, `FileSystemService`, and `ExportDestination` protocols (see `photo-export/Protocols/`).
- Use app-owned value types (`AssetDescriptor`, `ResourceDescriptor`) at non-framework boundaries instead of passing `PHAsset`/`PHAssetResource` directly.

---

## 2) Swift Concurrency

- Mark UI-facing types and properties with `@MainActor` when they mutate UI state:
```swift
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var assets: [PHAsset] = []
}
```
- Avoid mixing `DispatchQueue.main.async` inside `Task` blocks. Use `await MainActor.run { ... }` or mark the function `@MainActor`.
- Always design for cancellation. When fetching on changing inputs (`year`, `month`), prefer `.task(id:)` over `onAppear`/`onChange` triads:
```swift
.task(id: (year, month)) {
    await viewModel.loadAssets(forYear: year, month: month)
}
```
- Propagate `async throws` up; handle errors once at the boundary, mapping them to user-visible messages.
- Avoid detached tasks for UI work; prefer structured concurrency via `Task {}` scoped to the view.

---

## 3) Photos Framework Best Practices

- Authorization:
  - Check `PHPhotoLibrary.authorizationStatus(for: .readWrite)` before querying assets.
  - Handle `.denied`, `.restricted`, `.limited` gracefully; explain to the user how to fix access.
  - React if access changes while the app is running via `PHPhotoLibraryChangeObserver`.
- Fetching and memory:
  - Use `PHFetchOptions` with predicates for date ranges and sorting by `creationDate`.
  - For large libraries, iterate with batching and `autoreleasepool { }` (as already done) to limit memory.
  - Avoid unnecessary casts (`PHFetchResult.object(at:)` already returns `PHAsset`).
- Thumbnails and caching:
  - Use `PHCachingImageManager` for thumbnail grids; preheat around the visible range and stop caching when off-screen.
  - Set `options.isNetworkAccessAllowed = true` when iCloud originals may be remote (already done).
- Full-size export:
  - For export, prefer original resources over `requestImage(...)`:
    - Images: use `PHAssetResourceManager` with `PHAssetResourceType.photo` or `PHContentEditingInput` to access `fullSizeImageURL`.
    - Videos: `requestExportSession` for precise control; ensure you export at original quality.
- Track assets by `localIdentifier`. Persist export status using this ID for incremental/resumable exports.

---

## 4) Export Pipeline (Robustness Checklist)

- Pre-flight checks:
  - Verify destination root exists and is writable; clearly surface errors if not.
  - Validate path length and sanitize names (non-ASCII, reserved characters). Never overwrite existing files; generate unique names.
- Incremental export:
  - Maintain an export log or database keyed by `PHAsset.localIdentifier` with status: pending, in-progress, done, failed.
  - On launch, reconcile the log with the filesystem; clean up partial files.
- Resilience:
  - Write to a temporary file then atomically move to final location after success.
  - On interruption/crash, leave the system in a recoverable state and resume next launch.
- Error isolation:
  - Skip corrupt/unsupported assets, record the error, and continue.
- Concurrency:
  - Use a bounded task queue (e.g., `AsyncSemaphore`) to export in limited parallelism.
  - Prefer backpressure-aware design; avoid loading all assets in memory.

---

## 5) SwiftUI View Best Practices

- Prefer **NavigationSplitView** (macOS) for sidebar + detail over `NavigationView`.
- Derive state instead of storing duplicates. Keep `@State` minimal and source-of-truth single.
- Replace multiple `onChange(of:)` with `.task(id:)` to coalesce loads:
```swift
.task(id: (year, month)) { await viewModel.loadAssets(forYear: year, month: month) }
```
- Extract complex UI sections into small views with clear inputs. Avoid heavy logic in `body`.
- Avoid creating expensive objects in `body` or tight loops. For `DateFormatter`, provide static caches:
```swift
enum Formatters {
    static let monthName: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM"; return f
    }()
}
```
- Use `LazyVGrid`/`LazyHGrid` for dense grids. For long horizontal strips, your `LazyHStack` is fine; consider a grid when vertical space is available.
- Cancellation-friendly selection: cancel any in-flight full-image request when selection changes.
- Accessibility: provide labels (`.accessibilityLabel`) and dynamic type-friendly layout where applicable.

---

## 6) Error Handling & User Messaging

- Create domain errors conforming to `LocalizedError` for user-friendly messages. Avoid surfacing raw system errors to the UI.
- Centralize error presentation (e.g., `AlertState` or a small `ErrorBanner` component). Keep messages actionable.
- Log all recoverable errors (see Logging section) with context to aid debugging.

---

## 7) Logging & Instrumentation

- Use Unified Logging (`os.Logger`) instead of `print`:
```swift
import os
let logger = Logger(subsystem: "com.valtteriluoma.photo-export", category: "Photos")
logger.info("Fetched \(assets.count) assets for \(year)-\(month)")
logger.error("Export failed: \(error.localizedDescription)")
```
- Consider signposts for export phases and thumbnail preheating to profile performance in Instruments.

---

## 8) Performance & Memory

- Keep batches small and yield with `try await Task.sleep(nanoseconds: ...)` as you do; prefer cooperative cancellation checks (`Task.checkCancellation()`).
- Cache thumbnails and reuse across views; clear when memory pressure occurs or when leaving the screen.
- Avoid repeatedly recreating `DateFormatter`, `NumberFormatter`, etc. Provide static singletons.
- Avoid redundant state copies (e.g., keeping both `assets` and separate arrays of IDs unless necessary).
- Prefer value semantics for models (`struct`) and minimal reference types.

---

## 9) Code Style & API Design

- Naming:
  - Functions are verbs, variables are nouns. Avoid abbreviations.
  - Keep APIs explicit; label parameters clearly (`forYear year: Int, month: Int`).
- Access control: `private` for helpers, `internal` for module use, `public` only when needed.
- Documentation:
  - Use concise doc comments for public APIs and complex logic blocks.
- Avoid force unwraps. Use `guard` and fail fast with meaningful errors.
- Prefer `let` over `var` and immutability by default.
- Remove unnecessary casts (e.g., `PHAsset.fetchAssets(...).object(at:)` returns `PHAsset` already).

---

## 10) Photos Change Handling

- Adopt `PHPhotoLibraryChangeObserver` to refresh lists when the library changes while the app is open.
- Reconcile selected asset if it was deleted; fall back gracefully.

---

## 11) Testing Matrix (Must-Haves)

- Authorization flows: first run, denied, restricted, limited, revoked mid-session.
- Libraries: very small, large (10k–100k+), and iCloud-optimized with missing originals.
- Export targets: internal disk, external drives (unplug/plug), network shares; low-permission and low-space scenarios.
- Filenames: non-ASCII, very long names, name collisions.
- Resilience: crash/kill during export; resume correctness; no corrupt partial files.
- Concurrency: cancel while loading thumbnails or full image; rapid month switching.

---

## 12) Example: Main-Actor-safe state updates

```swift
@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var assets: [AssetDescriptor] = []
    @Published private(set) var thumbnailsById: [String: NSImage] = [:]
    @Published var selectedAsset: AssetDescriptor?
    @Published var selectedImage: NSImage?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let library: PhotoLibraryService
    private var imageLoadTask: Task<Void, Never>?

    init(library: PhotoLibraryService) { self.library = library }

    func loadAssets(forYear year: Int, month: Int) async {
        isLoading = true
        errorMessage = nil
        selectedAsset = nil
        selectedImage = nil
        do {
            let monthAssets = try await library.fetchAssets(year: year, month: month)
            assets = monthAssets
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func select(_ asset: AssetDescriptor) {
        imageLoadTask?.cancel()
        selectedAsset = asset
        selectedImage = nil
        imageLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await library.requestFullImage(for: asset.id)
                try Task.checkCancellation()
                self.selectedImage = image
            } catch is CancellationError { /* no-op */ }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
}
```

---

## 13) References

- Photos framework programming guide
- Apple Human Interface Guidelines (macOS)
- Instruments: Time Profiler, Memory Graph, Signposts
- Swift Concurrency best practices (WWDC sessions)

---

Adopting these practices will keep the app responsive and safe with very large libraries, make exports reliable and resumable, and improve overall code clarity and testability.
