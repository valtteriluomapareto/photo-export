import Combine
import Photos

/// Persistent-change-observation seam for AutoSync. Production code adapts
/// `PHPhotoLibraryChangeObserver` callbacks plus `PHPhotoLibrary.fetchPersistentChanges(since:)`
/// into a stream of outcomes; tests inject `FakePersistentChangeSource` to drive events
/// deterministically.
///
/// The stream is `Result`-based so the three documented fetch failure modes
/// (token-expired, token-invalid, details-unavailable) are routed individually rather than
/// being collapsed into a generic "no change" silence.
///
/// **Why `AnyPublisher` instead of `AsyncSequence`?** The rest of the manager layer uses
/// Combine (`@Published`, `objectWillChange`), so consumers of this seam stay consistent
/// with the rest of the codebase. AsyncSequence would force the AutoSync reducer loop to
/// be a `Task`-based pump, which the plan doesn't require — the reducer is synchronous and
/// effects are emitted as a list, with timer/IO effects executed by an effect runner that
/// already serializes work on `@MainActor`. If the reducer ever moves to a structured-
/// concurrency design, migrating the protocol while it has only one consumer is cheap.
@MainActor
protocol PhotoLibraryChangeProviding: AnyObject {
  var authorizationStatus: PHAuthorizationStatus { get }
  var changes: AnyPublisher<PhotoLibraryChangeOutcome, Never> { get }
}

typealias PhotoLibraryChangeOutcome = Result<
  PhotoLibraryPersistentChangeEvent, PhotoLibraryPersistentChangeFetchError
>
