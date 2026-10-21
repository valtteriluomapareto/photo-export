import Foundation
import Testing

@testable import Photo_Export

struct ExportErrorCodeTests {
  @Test func rawValuesKeepTheirPersistedIdentities() {
    let rows: [(ExportErrorCode, Int)] = [
      (.exportFolderAccessDenied, 1),
      (.destinationAlreadyExists, 2),
      (.assetNotFoundForResourceWrite, 3),
      (.matchingResourceNotFound, 4),
      (.pairedOriginalFilenameConflict, 5),
      (.assetNotFoundForVideoRender, 6),
      (.videoExportSessionUnavailable, 7),
      (.videoExportFailed, 8),
      (.editedResourceUnavailable, 9),
      (.imageDecodeFailed, 10),
      (.invalidTimelinePlacement, 11),
    ]
    for (errorCode, persistedValue) in rows {
      #expect(errorCode.rawValue == persistedValue)
      #expect(ExportErrorCode(rawValue: persistedValue) == errorCode)
    }
    #expect(ExportErrorCode(rawValue: 0) == nil)
    #expect(ExportErrorCode(rawValue: 12) == nil)
  }

  @Test func legacyExportCodesKeepTheirCategoryAndSignature() {
    let rows: [(Int, AutoSyncFailureCategory, String)] = [
      (1, .unknown, "Export:1"),
      (2, .destinationCollision, "Export:2"),
      (3, .unknown, "Export:3"),
      (4, .unknown, "Export:4"),
      (5, .destinationCollision, "Export:5"),
      (6, .unknown, "Export:6"),
      (7, .unknown, "Export:7"),
      (8, .unknown, "Export:8"),
      (9, .unknown, "Export:9"),
      (10, .unknown, "Export:10"),
      (11, .unknown, "Export:11"),
    ]
    for (code, category, signature) in rows {
      let signal = AutoSyncFailureCategory.classify(NSError(domain: "Export", code: code))
      #expect(signal.category == category, "Export code \(code)")
      #expect(signal.errorSignature == signature)
    }
  }

  @Test(arguments: [-1, 0, 12, Int.max])
  func unknownExportCodesRemainUnknown(code: Int) {
    let signal = AutoSyncFailureCategory.classify(NSError(domain: "Export", code: code))
    #expect(signal.category == .unknown)
    #expect(signal.errorSignature == "Export:\(code)")
  }

  @Test func editedUnavailableBridgeKeepsItsHistoricalIdentity() {
    let error = EditedResourceUnavailableError() as NSError
    #expect(error.domain == "Export")
    #expect(error.code == 9)
    #expect(error.localizedDescription == "Edited resource unavailable")
    let signal = AutoSyncFailureCategory.classify(error)
    #expect(signal.category == .unknown)
    #expect(signal.errorSignature == "Export:9")
  }

  @Test(arguments: [
    NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
    NSURLErrorTimedOut, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff,
    NSURLErrorCallIsActive, NSURLErrorDataNotAllowed, NSURLErrorCancelled, 12345,
  ])
  func urlErrorsKeepTheirICloudRetryPolicy(code: Int) {
    let signal = AutoSyncFailureCategory.classify(NSError(domain: NSURLErrorDomain, code: code))
    #expect(signal.category == .iCloudTransient)
    #expect(signal.errorSignature == "NSURLErrorDomain:\(code)")
  }

  @MainActor
  @Test func persistedExportFailuresContinueTheirAttemptHistory() throws {
    let directory = TestScratch.directory("ExportErrorCodeTests")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let rows: [(Int, AutoSyncFailureCategory, String)] = [
      (2, .destinationCollision, "Export:2"),
      (5, .destinationCollision, "Export:5"),
      (9, .unknown, "Export:9"),
    ]
    var historical = AutoSyncRetryState()
    for (code, category, signature) in rows {
      historical.recordFailure(
        scope: .timeline, assetId: "asset-\(code)", variant: .original,
        category: category, errorSignature: signature, at: now, nextEligibleAt: nil)
    }
    let writer = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: directory)
    try writer.save(historical, destinationId: "destination")
    let reader = FileBackedAutoSyncRetryStateStore(baseDirectoryURL: directory)
    var reopened = try reader.load(destinationId: "destination")
    let nextFailure = now.addingTimeInterval(60)
    for (code, category, signature) in rows {
      let previous = try #require(
        reopened.entry(scope: .timeline, assetId: "asset-\(code)", variant: .original))
      #expect(previous.errorSignature == signature)
      #expect(previous.category == category)
      #expect(previous.attemptCount == 1)
      let signal = AutoSyncFailureCategory.classify(NSError(domain: "Export", code: code))
      reopened.recordFailure(
        scope: .timeline, assetId: "asset-\(code)", variant: .original,
        category: signal.category, errorSignature: signal.errorSignature, at: nextFailure,
        nextEligibleAt: signal.category.nextEligibleAt(attemptCount: 2, from: nextFailure))
    }
    try writer.save(reopened, destinationId: "destination")
    let continued = try reader.load(destinationId: "destination")
    for (code, category, signature) in rows {
      let entry = try #require(
        continued.entry(scope: .timeline, assetId: "asset-\(code)", variant: .original))
      #expect(entry.errorSignature == signature)
      #expect(entry.category == category)
      #expect(entry.attemptCount == 2)
      #expect(entry.firstFailedAt == now)
      #expect(entry.lastFailedAt == nextFailure)
      #expect(entry.nextEligibleAt == (code == 9 ? nextFailure.addingTimeInterval(120) : nil))
    }
    let file = directory.appendingPathComponent("destination/retryState.json")
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let placements = try #require(json["entriesByPlacement"] as? [String: Any])
    let timeline = try #require(placements["timeline"] as? [String: Any])
    for (code, _, signature) in rows {
      let asset = try #require(timeline["asset-\(code)"] as? [String: Any])
      let entry = try #require(asset["original"] as? [String: Any])
      #expect(entry["errorSignature"] as? String == signature)
      #expect(entry["attemptCount"] as? Int == 2)
    }
  }
}
