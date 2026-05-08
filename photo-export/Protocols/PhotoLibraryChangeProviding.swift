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
@MainActor
protocol PhotoLibraryChangeProviding: AnyObject {
  var authorizationStatus: PHAuthorizationStatus { get }
  var changes: AnyPublisher<PhotoLibraryChangeOutcome, Never> { get }
}

typealias PhotoLibraryChangeOutcome = Result<
  PhotoLibraryPersistentChangeEvent, PhotoLibraryPersistentChangeFetchError
>
