import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 3 Slice B: per-error categorisation. The classifier is best-effort;
/// these tests pin the most-likely-encountered domain/code pairs so retries
/// route to the right bucket. Unknown domains fall through to `.unknown`
/// without misclassification.
struct AutoSyncFailureCategoryClassificationTests {

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

  @Test func cocoaNoSuchFileMapsToDestinationUnavailable() {
    let error = NSError(
      domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

    #expect(AutoSyncFailureCategory.classify(error).category == .destinationUnavailable)
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

  @Test func sentinelBuildsExplicitSignal() {
    let signal = AutoSyncFailureCategory.sentinel(
      category: .assetMissing, signature: "asset-missing", message: "Asset not found")

    #expect(signal.category == .assetMissing)
    #expect(signal.errorSignature == "asset-missing")
    #expect(signal.localizedDescription == "Asset not found")
  }
}
