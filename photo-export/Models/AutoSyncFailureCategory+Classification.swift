import Foundation
import Photos

/// Structured result of categorising an export failure. Carries both the
/// retry-policy bucket (`category`) and a stable string identity
/// (`errorSignature`) that survives across runs. Plan §"Retry and Failure
/// Policy": "Retry counts are scoped to scope/placement + assetId + variant
/// + category + errorSignature" — so the signature is what tells the retry
/// store "this is the same failure recurring" vs "this is a different
/// failure that should reset the attempt count."
struct ExportFailureSignal: Equatable, Sendable {
  let category: AutoSyncFailureCategory
  let errorSignature: String
  let localizedDescription: String
}

extension AutoSyncFailureCategory {
  /// Maps a thrown `Error` to a structured failure signal. The mapping is
  /// best-effort — unknown error types fall through to
  /// `(category: .unknown, signature: "<domain>:<code>")` so they still
  /// participate in retry bookkeeping without being misclassified into one
  /// of the named buckets. New domain/code pairs can be added incrementally
  /// as they're observed.
  ///
  /// Error signatures use `"<domain>:<code>"` form so the retry store can
  /// recognise "the same failure" without storing the Error object. Locale-
  /// dependent strings (the localized description) are intentionally not
  /// part of the signature — a user switching system languages must not
  /// reset the retry counter.
  static func classify(_ error: Error) -> ExportFailureSignal {
    let nsError = error as NSError
    let signature = "\(nsError.domain):\(nsError.code)"
    let localized = error.localizedDescription
    let category = self.category(domain: nsError.domain, code: nsError.code)
    return ExportFailureSignal(
      category: category, errorSignature: signature, localizedDescription: localized)
  }

  /// Builds a signal from a hard-coded sentinel string (e.g., "Asset not
  /// found"). Used when the failure has no underlying `Error` object —
  /// the call site decides the category and the signature is the sentinel
  /// string itself so the retry store can recognise it across runs.
  static func sentinel(
    category: AutoSyncFailureCategory, signature: String, message: String
  ) -> ExportFailureSignal {
    ExportFailureSignal(
      category: category, errorSignature: signature, localizedDescription: message)
  }

  private static func category(domain: String, code: Int) -> AutoSyncFailureCategory {
    switch domain {
    case NSCocoaErrorDomain:
      switch code {
      case NSFileWriteOutOfSpaceError:
        return .destinationNoSpace
      case NSFileWriteNoPermissionError, NSFileReadNoPermissionError,
        NSFileWriteVolumeReadOnlyError:
        return .destinationPermission
      case NSFileNoSuchFileError, NSFileReadNoSuchFileError,
        NSFileWriteFileExistsError:
        // Read-no-such-file at write time generally means the destination
        // directory vanished — treat as unavailable rather than missing-
        // asset. Write-file-exists is a collision the exporter should never
        // reach normally; surface as unknown so it doesn't get auto-retried.
        return code == NSFileWriteFileExistsError ? .unknown : .destinationUnavailable
      default:
        return .unknown
      }
    case NSPOSIXErrorDomain:
      switch Int32(code) {
      case ENOSPC: return .destinationNoSpace
      case EACCES, EPERM, EROFS: return .destinationPermission
      case ENOENT, ENXIO: return .destinationUnavailable
      default: return .unknown
      }
    case NSURLErrorDomain:
      // PhotoKit's iCloud download path surfaces NSURLError* codes.
      switch code {
      case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut, NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed:
        return .iCloudTransient
      default:
        return .iCloudTransient
      }
    case PHPhotosErrorDomain:
      guard let phCode = PHPhotosError.Code(rawValue: code) else { return .unknown }
      return categoryForPhotosError(phCode)
    default:
      return .unknown
    }
  }

  private static func categoryForPhotosError(_ code: PHPhotosError.Code)
    -> AutoSyncFailureCategory
  {
    switch code {
    case .invalidResource, .identifierNotFound:
      return .assetMissing
    case .networkError, .networkAccessRequired:
      return .iCloudTransient
    case .libraryVolumeOffline, .relinquishingLibraryBundleToWriter,
      .switchingSystemPhotoLibrary:
      return .photoKitTransient
    case .accessRestricted, .accessUserDenied:
      // App-level access; not a retry condition the export pipeline can fix.
      return .unknown
    case .persistentChangeTokenExpired, .persistentChangeDetailsUnavailable:
      // These belong to the change-fetch path, not export — included for
      // completeness but should never reach the export failure path.
      return .photoKitTransient
    default:
      return .photoKitTransient
    }
  }
}
