import Foundation
import Testing

@testable import Photo_Export

struct ExportVariantReasonTests {
  private func decode(reasonJSON: String, message: String) throws -> ExportVariantRecord {
    let data = try JSONSerialization.data(withJSONObject: [
      "status": "failed", "lastError": message,
    ])
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["reason"] = try JSONSerialization.jsonObject(
      with: Data(reasonJSON.utf8), options: .fragmentsAllowed)
    return try JSONDecoder().decode(
      ExportVariantRecord.self, from: JSONSerialization.data(withJSONObject: object))
  }

  @Test func typedFallbackIgnoresDisplayWording() throws {
    let edited = try decode(
      reasonJSON: "\"editedUnavailableOriginalBackedUp\"", message: "Localized fallback wording")
    let original = ExportVariantRecord(
      filename: "F_orig.HEIC", status: .done, exportDate: nil, lastError: nil)
    #expect(
      ExportCompletionPolicy.satisfiesEditedFallback(
        variants: [.original: original, .edited: edited],
        asset: TestAssetFactory.makeAsset(hasAdjustments: true), selection: .edited))
  }

  @Test(arguments: ["\"futureAcceptedMaybe\"", "null"])
  func unknownOrNullReasonCannotAcceptLegacyLookingText(reasonJSON: String) throws {
    let record = try decode(
      reasonJSON: reasonJSON,
      message: "Photos has no exportable paired video resource for this Live Photo")
    #expect(
      ExportCompletionPolicy.missingVariants(
        required: [.originalPairedVideo],
        variants: [.originalPairedVideo: record]) == [.originalPairedVideo])
  }
}

extension ExportVariantReasonTests {
  @Test func knownCodesDriveFallbackAndPairedCompletionWithChangedCopy() throws {
    let edited = try decode(reasonJSON: "\"editedResourceUnavailable\"", message: "Andere Sprache")
    #expect(
      ExportCompletionPolicy.shouldRunEditedFallback(
        variants: [.edited: edited], required: [.edited]))
    let paired = try decode(reasonJSON: "\"pairedVideoUnavailable\"", message: "Changed wording")
    #expect(
      ExportCompletionPolicy.missingVariants(
        required: [.originalPairedVideo],
        variants: [.originalPairedVideo: paired]
      ).isEmpty)
  }

  @Test func frozenLegacyLiteralsOnlyApplyToFailedRecordsWithoutReasonKey() throws {
    let cases: [(String, ExportVariantReason)] = [
      ("Interrupted before completion", .interrupted),
      ("Edited resource unavailable", .editedResourceUnavailable),
      (
        "Edited resource unavailable; original backed up as _orig",
        .editedUnavailableOriginalBackedUp
      ),
      (
        "Photos has no exportable paired video resource for this Live Photo",
        .pairedVideoUnavailable
      ),
    ]
    for (message, reason) in cases {
      for status in ["failed", "pending", "inProgress", "done"] {
        let data = try JSONSerialization.data(withJSONObject: [
          "status": status, "lastError": message,
        ])
        let record = try JSONDecoder().decode(ExportVariantRecord.self, from: data)
        #expect(record.reason == (status == "failed" ? reason : nil))
      }
      let data = try JSONSerialization.data(withJSONObject: [
        "status": "failed", "lastError": message + " ",
      ])
      #expect(try JSONDecoder().decode(ExportVariantRecord.self, from: data).reason == nil)
    }
  }

  @Test func newOrdinaryFailuresDoNotInferReasonAfterRoundTrip() throws {
    let record = ExportVariantRecord(
      filename: nil, status: .failed, exportDate: nil,
      lastError: "Edited resource unavailable; original backed up as _orig")
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["reason"] is NSNull)
    #expect(try JSONDecoder().decode(ExportVariantRecord.self, from: data) == record)
    let unknown = try decode(reasonJSON: "\"future/v2\"", message: "Edited resource unavailable")
    #expect(unknown.reason?.rawValue == "future/v2")
    #expect(
      try JSONDecoder().decode(ExportVariantRecord.self, from: JSONEncoder().encode(unknown))
        == unknown)
    #expect(throws: (any Error).self) {
      try decode(reasonJSON: "42", message: "Edited resource unavailable")
    }
  }
}

@MainActor
struct ExportVariantReasonStoreTests {
  @Test func routerTransitionsAndReloadKeepReasonsExplicit() async throws {
    let root = TestScratch.directory("ExportVariantReason")
    defer { try? FileManager.default.removeItem(at: root) }
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "dest")
    collections.configure(for: "dest")
    let router = RecordStoreRouter(timelineStore: timeline, collectionStore: collections)
    let favorite = ExportPlacement.favorites()
    collections.upsertPlacement(favorite)
    let month = ExportPlacement.timeline(year: 2024, month: 4)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let asset = TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true)
    for placement in [month, favorite] {
      let commit = try router.captureFinalCommit(
        assetId: asset.id, placement: placement, variant: .original,
        relPath: "2024/04/", subfolder: nil, acceptsEditedFallback: false)
      await commit("F_orig.HEIC")
      router.markVariantFailed(
        assetId: asset.id, placement: placement, variant: .edited,
        error: "Changed copy", reason: .editedUnavailableOriginalBackedUp, at: date)
      router.markVariantFailed(
        assetId: "unknown", placement: placement, variant: .edited,
        error: "Edited resource unavailable; original backed up as _orig",
        reason: .init(rawValue: "future/v2"), at: date)
      router.markVariantFailed(
        assetId: "ordinary", placement: placement, variant: .edited,
        error: "Edited resource unavailable; original backed up as _orig", at: date)
    }
    timeline.flushForTesting()
    collections.flushForTesting()
    let reopenedTimeline = ExportRecordStore(baseDirectoryURL: root)
    let reopenedCollections = CollectionExportRecordStore(baseDirectoryURL: root)
    reopenedTimeline.configure(for: "dest")
    reopenedCollections.configure(for: "dest")
    #expect(reopenedTimeline.isExported(asset: asset, selection: .edited, livePhotosPaired: false))
    #expect(
      reopenedCollections.isExported(
        asset: asset, placement: favorite, selection: .edited, livePhotosPaired: false))
    #expect(
      reopenedTimeline.exportInfo(assetId: "unknown")?.variants[.edited]?.reason?.rawValue
        == "future/v2")
    #expect(
      reopenedCollections.exportInfo(assetId: "unknown", placement: favorite)?.variants[.edited]?
        .reason?.rawValue == "future/v2")
    #expect(reopenedTimeline.exportInfo(assetId: "ordinary")?.variants[.edited]?.reason == nil)
    #expect(
      reopenedCollections.exportInfo(assetId: "ordinary", placement: favorite)?.variants[.edited]?
        .reason == nil)
    #expect(
      timeline.sidebarSummary(
        year: 2024, month: 4, totalCount: 1, adjustedCount: 1, selection: .edited,
        livePhotosPaired: false)?.exportedCount
        == 1)
    #expect(
      reopenedTimeline.sidebarSummary(
        year: 2024, month: 4, totalCount: 1, adjustedCount: 1, selection: .edited,
        livePhotosPaired: false)?.exportedCount
        == 1)
    let report = DiagnosticReporter(
      timelineStore: reopenedTimeline, collectionStore: reopenedCollections,
      destinationId: "dest", appVersion: "test", buildNumber: "1"
    ).makeReport()
    #expect(report.contains("reason: future/v2"))
    #expect(report.contains("fallback: original exported as F_orig.HEIC"))
    for placement in [month, favorite] {
      router.markVariantInProgress(
        assetId: asset.id, placement: placement, variant: .edited, relPath: "2024/04/",
        filename: "F.JPG")
      #expect(router.variants(forAssetId: asset.id, placement: placement)[.edited]?.reason == nil)
      router.markVariantFailed(
        assetId: asset.id, placement: placement, variant: .edited,
        error: "Unavailable", reason: .editedResourceUnavailable, at: date)
      router.markVariantFailed(
        assetId: asset.id, placement: placement, variant: .edited,
        error: "Edited resource unavailable; original backed up as _orig", at: date)
    }
    #expect(timeline.exportInfo(assetId: asset.id)?.variants[.edited]?.reason == nil)
    #expect(
      collections.exportInfo(assetId: asset.id, placement: favorite)?.variants[.edited]?.reason
        == nil)
    #expect(
      timeline.sidebarSummary(
        year: 2024, month: 4, totalCount: 1, adjustedCount: 1, selection: .edited,
        livePhotosPaired: false)?.exportedCount
        == 0)
    #expect(
      collections.monthSummary(
        assets: [asset], placement: favorite, selection: .edited, livePhotosPaired: false
      ).exportedCount == 0)
    for placement in [month, favorite] {
      router.markVariantFailed(
        assetId: asset.id, placement: placement, variant: .edited,
        error: "Unavailable", reason: .editedResourceUnavailable, at: date)
      let commit = try router.captureFinalCommit(
        assetId: asset.id, placement: placement, variant: .edited,
        relPath: "2024/04/", subfolder: nil, acceptsEditedFallback: false)
      await commit("F.JPG")
    }
    #expect(timeline.exportInfo(assetId: asset.id)?.variants[.edited]?.reason == nil)
    #expect(
      collections.exportInfo(assetId: asset.id, placement: favorite)?.variants[.edited]?.reason
        == nil)
    timeline.flushForTesting()
    collections.flushForTesting()
  }
}

extension ExportVariantReasonStoreTests {
  @Test(arguments: [false, true])
  func countersAcceptOnlyKnownReasonsBeforeAndAfterReload(paired: Bool) async throws {
    let root = TestScratch.directory("ExportVariantReason")
    defer { try? FileManager.default.removeItem(at: root) }
    let timeline = ExportRecordStore(baseDirectoryURL: root)
    let collections = CollectionExportRecordStore(baseDirectoryURL: root)
    timeline.configure(for: "dest")
    collections.configure(for: "dest")
    let favorite = ExportPlacement.favorites()
    collections.upsertPlacement(favorite)
    let router = RecordStoreRouter(timelineStore: timeline, collectionStore: collections)
    let month = ExportPlacement.timeline(year: 2024, month: 4)
    let reasons: [ExportVariantReason?] = [
      paired ? .pairedVideoUnavailable : .editedUnavailableOriginalBackedUp,
      .init(rawValue: "future"), nil,
    ]
    let assets = (0..<3).map {
      TestAssetFactory.makeAsset(id: "a\($0)", hasAdjustments: !paired, isLivePhoto: paired)
    }
    for (index, asset) in assets.enumerated() {
      for placement in [month, favorite] {
        let commit = try router.captureFinalCommit(
          assetId: asset.id, placement: placement, variant: .original,
          relPath: "2024/04/", subfolder: nil, acceptsEditedFallback: false)
        await commit(paired ? "IMG.JPG" : "IMG_orig.HEIC")
        router.markVariantFailed(
          assetId: asset.id, placement: placement,
          variant: paired ? .originalPairedVideo : .edited,
          error: index == 0
            ? "Changed copy"
            : (paired
              ? "Photos has no exportable paired video resource for this Live Photo"
              : "Edited resource unavailable; original backed up as _orig"), reason: reasons[index],
          at: Date())
      }
    }
    timeline.flushForTesting()
    collections.flushForTesting()
    let reloadedTimeline = ExportRecordStore(baseDirectoryURL: root)
    let reloadedCollections = CollectionExportRecordStore(baseDirectoryURL: root)
    reloadedTimeline.configure(for: "dest")
    reloadedCollections.configure(for: "dest")
    for store in [timeline, reloadedTimeline] {
      #expect(
        store.sidebarSummary(
          year: 2024, month: 4, totalCount: 3, adjustedCount: paired ? 0 : 3,
          selection: .edited, livePhotosPaired: paired)?.exportedCount == 1)
    }
    for store in [collections, reloadedCollections] {
      #expect(
        store.monthSummary(
          assets: assets, placement: favorite, selection: .edited,
          livePhotosPaired: paired
        ).exportedCount == 1)
    }
  }
}

extension ExportVariantReasonTests {
  @Test func flatLegacyInterruptionUsesStatusRatherThanSynthesizedCopy() throws {
    let json =
      #"{"id":"legacy","year":2024,"month":4,"relPath":"2024/04/","status":"inProgress","lastError":"Unrelated old text"}"#
    let record = try JSONDecoder().decode(ExportRecord.self, from: Data(json.utf8))
    #expect(record.variants[.original]?.reason == .interrupted)
  }
}
