import AVFoundation
import Foundation
import Photos
import os

/// Structured result of categorising an export failure. Carries both the
/// retry-policy bucket (`category`) and a stable string identity
/// (`errorSignature`) that survives across runs. The retry store combines the
/// scope/placement, asset, variant, category and signature so a different failure
/// resets the attempt count instead of inheriting an unrelated backoff.
/// See docs/reference/auto-export-behavior.md#retry-and-failure-policy.
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
  ///
  /// An `ExportDestinationError` is matched by type: `.notAvailable` is unavailable, and
  /// `.notWritable` and `.scopeAccessDenied` are permission failures. Every case is listed,
  /// so a new one has to be classified when it is added.
  ///
  /// Two kinds of wrapper are classified by their cause, keeping the outer signature:
  /// an `ExportDestinationError.failedToCreateFolder` by its underlying error, and a
  /// Cocoa error that would otherwise be `.unknown` (such as 512 from `createDirectory`)
  /// by a POSIX `NSUnderlyingError` one level down. The cause's errno is logged.
  static func classify(_ error: Error) -> ExportFailureSignal {
    let nsError = error as NSError
    let signature = "\(nsError.domain):\(nsError.code)"
    let localized = error.localizedDescription
    return ExportFailureSignal(
      category: category(of: error), errorSignature: signature, localizedDescription: localized)
  }

  private static let logger = Logger.app(.failureClassification)

  private static func category(of error: Error) -> AutoSyncFailureCategory {
    if let destinationError = error as? ExportDestinationManager.ExportDestinationError {
      switch destinationError {
      case .notAvailable:
        return .destinationUnavailable
      // Write access is denied: the folder is read-only (`.notWritable`, as with EROFS or
      // EACCES) or sandbox access was refused (`.scopeAccessDenied`).
      case .notWritable, .scopeAccessDenied:
        return .destinationPermission
      case .failedToCreateFolder(_, let underlying):
        return category(of: underlying)
      case .noSelection, .invalidYear, .invalidMonth, .pathTooLong, .notDirectory,
        .invalidRelativePath:
        return .unknown
      }
    }
    let nsError = error as NSError
    let outer = category(domain: nsError.domain, code: nsError.code)
    guard outer == .unknown, nsError.domain == NSCocoaErrorDomain,
      let cause = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
      cause.domain == NSPOSIXErrorDomain
    else { return outer }
    let classified = category(domain: cause.domain, code: cause.code)
    logger.debug(
      "Classified \(nsError.domain, privacy: .public):\(nsError.code, privacy: .public) by its POSIX cause errno \(cause.code, privacy: .public) as \(classified.rawValue, privacy: .public)"
    )
    return classified
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
      case NSFileWriteFileExistsError:
        return .destinationCollision
      default:
        // Includes no-such-file (4, 260): a missing file can be a staged file or a reuse
        // source rather than the destination root, so it does not prove the destination is
        // gone.
        return .unknown
      }
    case NSPOSIXErrorDomain:
      switch Int32(code) {
      case EEXIST: return .destinationCollision
      case ENOSPC: return .destinationNoSpace
      case EACCES, EPERM, EROFS: return .destinationPermission
      // The destination can't be reached: a network share dropped or timed out, or the
      // device is gone. ENOENT and EIO stay unknown; either can come from elsewhere.
      case ENOTCONN, ETIMEDOUT, ESTALE, EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ENXIO:
        return .destinationUnavailable
      default: return .unknown
      }
    case "Export":
      return code == 2 || code == 5 ? .destinationCollision : .unknown
    case AVFoundationErrorDomain:
      return code == AVError.Code.diskFull.rawValue ? .destinationNoSpace : .unknown
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
    case "CloudPhotoLibraryErrorDomain":
      // Observed iCloud download failure; private neighboring codes remain unknown.
      return code == 1005 ? .iCloudTransient : .unknown
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
