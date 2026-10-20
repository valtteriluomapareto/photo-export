import AVFoundation
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 3 Slice B: per-error categorisation. The classifier is best-effort;
/// these tests pin the most-likely-encountered domain/code pairs so retries
/// route to the right bucket. Unknown domains fall through to `.unknown`
/// without misclassification.
struct AutoSyncFailureCategoryClassificationTests {

  @Test func nativeRendererDiskFullIsAStableHardDestinationFailure() {
    let signal = AutoSyncFailureCategory.classify(
      NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue))
    #expect(signal.category == .destinationNoSpace)
    #expect(!signal.category.isAutomaticallyRetryable)
    #expect(signal.errorSignature == "\(AVFoundationErrorDomain):-11807")
    #expect(
      AutoSyncFailureCategory.classify(
        NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue)
      ).category == .unknown)
  }

  @Test func knownFileCollisionsRequireManualRetry() throws {
    for error in [
      NSError(domain: "Export", code: 5), NSError(domain: "Export", code: 2),
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError),
      NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)),
    ] {
      let signal = AutoSyncFailureCategory.classify(error)
      #expect(!signal.category.isAutomaticallyRetryable)
      #expect(signal.category.nextEligibleAt(attemptCount: 1, from: Date()) == nil)
      let data = try JSONEncoder().encode(signal.category)
      #expect(try JSONDecoder().decode(AutoSyncFailureCategory.self, from: data) == signal.category)
      var state = AutoSyncRetryState()
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      state.recordFailure(
        scope: .timeline, assetId: "collision", variant: .original,
        category: signal.category, errorSignature: signal.errorSignature, at: now,
        nextEligibleAt: signal.category.nextEligibleAt(attemptCount: 1, from: now))
      let decoded = try JSONDecoder().decode(
        AutoSyncRetryState.self, from: JSONEncoder().encode(state))
      let entry = decoded.entry(scope: .timeline, assetId: "collision", variant: .original)
      #expect(entry?.category == signal.category)
      #expect(entry?.nextEligibleAt == nil)
    }
    #expect(
      AutoSyncFailureCategory.classify(NSError(domain: "Other", code: 5)).category
        .isAutomaticallyRetryable)
  }

  @Test func observedPrivateCloudDownloadCodeOnly() {
    for code in [1004, 1005, 1006] {
      let signal = AutoSyncFailureCategory.classify(
        NSError(domain: "CloudPhotoLibraryErrorDomain", code: code))
      #expect(signal.category == (code == 1005 ? .iCloudTransient : .unknown))
      #expect(signal.errorSignature == "CloudPhotoLibraryErrorDomain:\(code)")
    }
  }

  @Test func cocoaOutOfSpaceMapsToDestinationNoSpace() {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
      userInfo: [NSLocalizedDescriptionKey: "out of space"])

    let signal = AutoSyncFailureCategory.classify(error)

    #expect(signal.category == .destinationNoSpace)
    #expect(signal.errorSignature == "NSCocoaErrorDomain:\(NSFileWriteOutOfSpaceError)")
    #expect(signal.localizedDescription == "out of space")
  }

  @Test func cocoaNoWritePermissionMapsToDestinationPermission() {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

    #expect(AutoSyncFailureCategory.classify(error).category == .destinationPermission)
  }

  @Test func cocoaReadOnlyVolumeMapsToDestinationPermission() {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)

    #expect(AutoSyncFailureCategory.classify(error).category == .destinationPermission)
  }

  /// A missing file can come from the source side (a staged file, a reuse source), so
  /// it does not prove that the destination went away.
  @Test(arguments: [NSFileNoSuchFileError, NSFileReadNoSuchFileError])
  func cocoaNoSuchFileIsUnknown(code: Int) {
    let signal = AutoSyncFailureCategory.classify(
      NSError(domain: NSCocoaErrorDomain, code: code))

    #expect(signal.category == .unknown)
    #expect(signal.errorSignature == "NSCocoaErrorDomain:\(code)")
  }

  struct ErrnoRow: Sendable, CustomTestStringConvertible {
    let code: Int32
    let category: AutoSyncFailureCategory
    let testDescription: String
    init(_ code: Int32, _ name: String, _ category: AutoSyncFailureCategory) {
      self.code = code
      self.category = category
      self.testDescription = name
    }
  }

  /// One row per errno the export pipeline can surface. Only errors that say the
  /// destination can't be reached are Destination Unavailable.
  static let errnoRows: [ErrnoRow] = [
    ErrnoRow(ENOTCONN, "ENOTCONN", .destinationUnavailable),
    ErrnoRow(ETIMEDOUT, "ETIMEDOUT", .destinationUnavailable),
    ErrnoRow(ESTALE, "ESTALE", .destinationUnavailable),
    ErrnoRow(EHOSTDOWN, "EHOSTDOWN", .destinationUnavailable),
    ErrnoRow(EHOSTUNREACH, "EHOSTUNREACH", .destinationUnavailable),
    ErrnoRow(ENETDOWN, "ENETDOWN", .destinationUnavailable),
    ErrnoRow(ENETUNREACH, "ENETUNREACH", .destinationUnavailable),
    ErrnoRow(ENXIO, "ENXIO", .destinationUnavailable),
    ErrnoRow(ENOENT, "ENOENT", .unknown),
    ErrnoRow(EIO, "EIO", .unknown),
    ErrnoRow(EXDEV, "EXDEV", .unknown),
    ErrnoRow(ECONNRESET, "ECONNRESET", .unknown),
    ErrnoRow(ENOSPC, "ENOSPC", .destinationNoSpace),
    ErrnoRow(EACCES, "EACCES", .destinationPermission),
    ErrnoRow(EPERM, "EPERM", .destinationPermission),
    ErrnoRow(EROFS, "EROFS", .destinationPermission),
    ErrnoRow(EEXIST, "EEXIST", .destinationCollision),
  ]

  @Test(arguments: errnoRows)
  func posixErrnoMapsToItsCategory(row: ErrnoRow) throws {
    let signal = AutoSyncFailureCategory.classify(
      NSError(domain: NSPOSIXErrorDomain, code: Int(row.code)))
    #expect(signal.category == row.category)
    #expect(signal.errorSignature == "NSPOSIXErrorDomain:\(row.code)")

    let bridged = AutoSyncFailureCategory.classify(
      POSIXError(try #require(POSIXErrorCode(rawValue: row.code))))
    #expect(bridged.category == row.category)
    #expect(bridged.errorSignature == "NSPOSIXErrorDomain:\(row.code)")
  }

  @Test func posixENOSPCMapsToDestinationNoSpace() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

    #expect(AutoSyncFailureCategory.classify(error).category == .destinationNoSpace)
  }

  @Test func posixEACCESMapsToDestinationPermission() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))

    #expect(AutoSyncFailureCategory.classify(error).category == .destinationPermission)
  }

  @Test func urlNoConnectionMapsToICloudTransient() {
    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

    #expect(AutoSyncFailureCategory.classify(error).category == .iCloudTransient)
  }

  @Test func unknownDomainMapsToUnknown() {
    let error = NSError(domain: "ArbitraryDomain", code: 42)

    let signal = AutoSyncFailureCategory.classify(error)

    #expect(signal.category == .unknown)
    #expect(signal.errorSignature == "ArbitraryDomain:42")
  }

  @Test func errorSignatureIsStableAcrossLocalizationChanges() {
    // The signature is `domain:code`, so two errors with the same domain
    // and code but different `localizedDescription`s produce the same
    // signature — the retry store recognises them as the same failure
    // recurring.
    let error1 = NSError(
      domain: NSCocoaErrorDomain, code: 640,
      userInfo: [NSLocalizedDescriptionKey: "The volume is out of space."])
    let error2 = NSError(
      domain: NSCocoaErrorDomain, code: 640,
      userInfo: [NSLocalizedDescriptionKey: "Le volume est plein."])

    #expect(
      AutoSyncFailureCategory.classify(error1).errorSignature
        == AutoSyncFailureCategory.classify(error2).errorSignature)
  }

  @Test func backoffAttemptOneFiresAfter30Seconds() {
    let failedAt = Date(timeIntervalSince1970: 1_000_000)
    let next = AutoSyncFailureCategory.iCloudTransient.nextEligibleAt(
      attemptCount: 1, from: failedAt)
    #expect(next == failedAt.addingTimeInterval(30))
  }

  @Test func backoffEscalatesAcrossAttempts() {
    let failedAt = Date(timeIntervalSince1970: 1_000_000)
    let delays: [(Int, TimeInterval)] = [
      (1, 30), (2, 120), (3, 600), (4, 3600), (5, 21_600), (10, 21_600),
    ]
    for (attempt, expectedDelay) in delays {
      let next = AutoSyncFailureCategory.unknown.nextEligibleAt(
        attemptCount: attempt, from: failedAt)
      #expect(next == failedAt.addingTimeInterval(expectedDelay))
    }
  }

  @Test func hardCategoriesHaveNoBackoff() {
    let failedAt = Date()
    for category in [
      AutoSyncFailureCategory.destinationPermission, .destinationNoSpace,
      .assetMissing, .resourceMissing, .destinationUnavailable,
    ] {
      #expect(category.nextEligibleAt(attemptCount: 1, from: failedAt) == nil)
    }
  }

  /// Guard: further writes in the run would hit the same failure only for these.
  @Test func destinationWideFailuresStopTheRun() {
    #expect(
      Set(AutoSyncFailureCategory.allCases.filter(\.stopsCurrentExportRun))
        == [.destinationNoSpace, .destinationPermission, .destinationUnavailable])
  }

  @Test func sentinelBuildsExplicitSignal() {
    let signal = AutoSyncFailureCategory.sentinel(
      category: .assetMissing, signature: "asset-missing", message: "Asset not found")

    #expect(signal.category == .assetMissing)
    #expect(signal.errorSignature == "asset-missing")
    #expect(signal.localizedDescription == "Asset not found")
  }

  // MARK: - Wrapped errors

  private static func wrapping(
    _ underlying: Error, domain: String = NSCocoaErrorDomain, code: Int = NSFileWriteUnknownError
  ) -> NSError {
    NSError(domain: domain, code: code, userInfo: [NSUnderlyingErrorKey: underlying])
  }

  private static func posix(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }

  /// `createDirectory` reports a network failure as Cocoa 512 with the POSIX cause
  /// underneath. The cause decides the category; the signature stays the outer one.
  @Test(arguments: [
    ErrnoRow(ENOTCONN, "512→ENOTCONN", .destinationUnavailable),
    ErrnoRow(ETIMEDOUT, "512→ETIMEDOUT", .destinationUnavailable),
    ErrnoRow(ENOSPC, "512→ENOSPC", .destinationNoSpace),
    ErrnoRow(EACCES, "512→EACCES", .destinationPermission),
    ErrnoRow(ENOENT, "512→ENOENT", .unknown),
    ErrnoRow(EIO, "512→EIO", .unknown),
  ])
  func cocoaWrapperIsClassifiedByItsPOSIXCause(row: ErrnoRow) {
    let signal = AutoSyncFailureCategory.classify(Self.wrapping(Self.posix(row.code)))
    #expect(signal.category == row.category)
    #expect(signal.errorSignature == "NSCocoaErrorDomain:\(NSFileWriteUnknownError)")
  }

  /// Guard: only one level of POSIX cause under a Cocoa error that is otherwise
  /// unknown is consulted. A known Cocoa code keeps its own category.
  @Test func onlyAnUnknownCocoaErrorWithADirectPOSIXCauseIsReclassified() {
    let cases: [(NSError, AutoSyncFailureCategory, String)] = [
      (
        Self.wrapping(Self.wrapping(Self.posix(ENOTCONN))), .unknown,
        "NSCocoaErrorDomain:\(NSFileWriteUnknownError)"
      ),
      (
        Self.wrapping(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)), .unknown,
        "NSCocoaErrorDomain:\(NSFileWriteUnknownError)"
      ),
      (
        Self.wrapping(Self.posix(ENOTCONN), code: NSFileWriteNoPermissionError),
        .destinationPermission, "NSCocoaErrorDomain:\(NSFileWriteNoPermissionError)"
      ),
      (
        Self.wrapping(
          Self.posix(ENOTCONN), domain: AVFoundationErrorDomain,
          code: AVError.Code.unknown.rawValue),
        .unknown, "\(AVFoundationErrorDomain):\(AVError.Code.unknown.rawValue)"
      ),
      (Self.wrapping(Self.posix(ENOTCONN), domain: "Export", code: 9), .unknown, "Export:9"),
    ]
    for (error, category, signature) in cases {
      let signal = AutoSyncFailureCategory.classify(error)
      #expect(signal.category == category, "\(error)")
      #expect(signal.errorSignature == signature, "\(error)")
    }
  }

  // MARK: - ExportDestinationError

  private typealias DestinationError = ExportDestinationManager.ExportDestinationError

  @Test func destinationNotAvailableIsDestinationUnavailable() {
    let error = DestinationError.notAvailable
    let signal = AutoSyncFailureCategory.classify(error)
    #expect(signal.category == .destinationUnavailable)
    let bridged = error as NSError
    #expect(signal.errorSignature == "\(bridged.domain):\(bridged.code)")
  }

  /// A folder that couldn't be created is classified by why it couldn't, and keeps the
  /// destination error's own signature.
  @Test func folderCreationFailureIsClassifiedByItsUnderlyingError() {
    let folder = URL(fileURLWithPath: "/Volumes/Share/2026/09", isDirectory: true)
    let cases: [(Error, AutoSyncFailureCategory)] = [
      (Self.wrapping(Self.posix(ENOTCONN)), .destinationUnavailable),
      (Self.posix(ETIMEDOUT), .destinationUnavailable),
      (
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
        .destinationPermission
      ),
      (Self.posix(EACCES), .destinationPermission),
      (NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .destinationNoSpace),
      (Self.wrapping(Self.posix(ENOENT)), .unknown),
      (Self.posix(EIO), .unknown),
    ]
    for (underlying, category) in cases {
      let error = DestinationError.failedToCreateFolder(folder, underlying: underlying)
      let signal = AutoSyncFailureCategory.classify(error)
      let bridged = error as NSError
      #expect(signal.category == category, "\(underlying)")
      #expect(signal.errorSignature == "\(bridged.domain):\(bridged.code)", "\(underlying)")
    }
  }

  /// A read-only folder and a denied security scope can be reached but not written, the
  /// same condition as EROFS and EACCES. Each keeps its own bridged signature.
  @Test func destinationWriteAccessErrorsAreDestinationPermission() {
    for error in [DestinationError.notWritable, .scopeAccessDenied] {
      let signal = AutoSyncFailureCategory.classify(error)
      let bridged = error as NSError
      #expect(signal.category == .destinationPermission, "\(error)")
      #expect(signal.errorSignature == "\(bridged.domain):\(bridged.code)", "\(error)")
    }
  }

  /// Guard: destination errors that say nothing about reachability or write access stay
  /// unknown.
  @Test func otherDestinationErrorsStayUnknown() {
    for error in [
      DestinationError.noSelection, .invalidYear, .invalidMonth, .invalidRelativePath("x"),
      .pathTooLong, .notDirectory(URL(fileURLWithPath: "/tmp/x")),
    ] {
      #expect(AutoSyncFailureCategory.classify(error).category == .unknown, "\(error)")
    }
  }
}
