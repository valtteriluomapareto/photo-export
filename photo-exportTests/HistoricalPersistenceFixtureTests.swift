import CryptoKit
import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct HistoricalPersistenceFixtureTests {
  private static let checkout = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
  private static let fixtureRoot = checkout.appendingPathComponent("test-fixtures/persistence")
  private static let tags = ["v1.0.3", "v1.6.5"]
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Manifest: Decodable {
    struct Release: Decodable {
      let commit: String
      let releaseURL: String
      let sources: [String: String]
      let harnessSHA256: String
      let files: [String: String]
    }
    let schemaVersion: Int
    let toolchain: String
    let target: String
    let hostRuntime: String
    struct AuxiliaryGeneration: Decodable {
      let files: [String: String]
    }
    let releases: [String: Release]
    let auxiliaryGenerations: [String: AuxiliaryGeneration]
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func manifest() throws -> Manifest {
    let path = fixtureRoot.appendingPathComponent("manifest.json")
    try #require(
      FileManager.default.fileExists(atPath: path.path),
      "Tests require the checkout fixture directory: \(path.path)")
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: path))
  }

  @MainActor
  private struct Fixture {
    let root: URL
    let originals: [URL: Data]

    init(tag: String) throws {
      let release = try #require(try HistoricalPersistenceFixtureTests.manifest().releases[tag])
      let source = HistoricalPersistenceFixtureTests.fixtureRoot.appendingPathComponent(tag)
      var bytes: [URL: Data] = [:]
      for (relative, expected) in release.files {
        let url = source.appendingPathComponent(relative)
        let data = try Data(contentsOf: url)
        try #require(
          HistoricalPersistenceFixtureTests.digest(data) == expected,
          "Changed immutable fixture: \(url.path)")
        bytes[url] = data
      }
      originals = bytes
      root = TestScratch.directory("Historical")
      try FileManager.default.copyItem(at: source, to: root)
    }

    func cleanup() {
      for (url, expected) in originals {
        #expect(
          (try? Data(contentsOf: url)) == expected,
          "The original fixture must remain unchanged: \(url.path)")
      }
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test func provenanceAndFileInventoryArePinned() throws {
    let manifest = try Self.manifest()
    #expect(manifest.schemaVersion == 1)
    #expect(!manifest.toolchain.isEmpty)
    #expect(!manifest.target.isEmpty)
    #expect(!manifest.hostRuntime.isEmpty)
    #expect(Set(manifest.releases.keys) == Set(Self.tags))
    #expect(manifest.releases["v1.0.3"]?.commit == "a85100a7b0c734a0f492f5d76f5317c6c599d38f")
    #expect(manifest.releases["v1.6.5"]?.commit == "0b0eb9b786311a961f9051d14e2e93cb0ecca135")
    for tag in Self.tags {
      let release = try #require(manifest.releases[tag])
      #expect(
        release.releaseURL
          == "https://github.com/valtteriluomapareto/photo-export/releases/tag/\(tag)")
      let harness = Self.checkout.appendingPathComponent("scripts/fixtures/\(tag).swift")
      #expect(Self.digest(try Data(contentsOf: harness)) == release.harnessSHA256)
      let root = Self.fixtureRoot.appendingPathComponent(tag)
      let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
      let files = Set(
        paths.filter {
          (try? root.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey])
            .isRegularFile) == true
        })
      let allFiles = release.files.merging(manifest.auxiliaryGenerations[tag]?.files ?? [:]) {
        old, _ in old
      }
      #expect(files == Set(allFiles.keys))
      for (path, expected) in allFiles {
        #expect(Self.digest(try Data(contentsOf: root.appendingPathComponent(path))) == expected)
      }
    }
  }

  @Test(arguments: tags)
  func timelineSnapshotReplayAndReopenPreserveHistoricalSemantics(tag: String) throws {
    let fixture = try Fixture(tag: tag)
    defer { fixture.cleanup() }
    for _ in 0..<2 {
      // A fresh instance repeats only production loading; no test save or forced
      // compaction can mask a missing load/replay operation.
      let a = ExportRecordStore(baseDirectoryURL: fixture.root)
      let b = ExportRecordStore(baseDirectoryURL: fixture.root)
      a.configure(for: "A")
      b.configure(for: "B")
      #expect(a.state == .ready)
      #expect(b.state == .ready)
      let expectedIds: Set<String> =
        tag == "v1.0.3"
        ? ["shared", "snapshot-only", "log-only", "interrupted", "raw-failure"]
        : ["shared", "snapshot-only", "log-only", "interrupted", "fallback", "live", "video"]
      #expect(Set(a.recordsById.keys) == expectedIds)
      #expect(Set(b.recordsById.keys) == ["shared"])
      for (id, filename) in [
        ("shared", "REPLAY.JPG"), ("snapshot-only", "SNAP.JPG"), ("log-only", "LOG.JPG"),
      ] {
        let record = try #require(a.exportInfo(assetId: id))
        #expect(record.year == 2024 && record.month == 4 && record.relPath == "2024/04/")
        #expect(record.variants[.original]?.filename == filename)
        #expect(record.variants[.original]?.status == .done)
        #expect(record.variants[.original]?.exportDate == date)
        #expect(record.variants[.original]?.subfolder == nil)
        #expect(
          a.isExported(
            asset: TestAssetFactory.makeAsset(id: id), selection: .edited, livePhotosPaired: false))
        #expect(
          ExportCompletionPolicy.missingVariants(required: [.original], variants: record.variants)
            .isEmpty)
      }
      let interrupted = try #require(a.exportInfo(assetId: "interrupted"))
      #expect(interrupted.variants[.original]?.filename == "PARTIAL.JPG")
      #expect(interrupted.variants[.original]?.status == .failed)
      #expect(interrupted.variants[.original]?.lastError == "Interrupted before completion")
      #expect(interrupted.variants[.original]?.exportDate == nil)
      #expect(
        ExportCompletionPolicy.missingVariants(
          required: [.original], variants: interrupted.variants) == [.original])
      let other = try #require(b.exportInfo(assetId: "shared"))
      #expect(other.year == 2030 && other.month == 1 && other.relPath == "2030/01/")
      #expect(other.variants[.original]?.filename == "OTHER.JPG")
      #expect(other.variants[.original]?.status == .failed)
      #expect(other.variants[.original]?.lastError == "Other destination")
      #expect(
        !b.isExported(
          asset: TestAssetFactory.makeAsset(id: "shared"), selection: .edited,
          livePhotosPaired: false))
      if tag == "v1.0.3" {
        #expect(
          a.exportInfo(assetId: "raw-failure")?.variants[.original]?.lastError
            == "Legacy disk error")
      } else {
        let fallback = try #require(a.exportInfo(assetId: "fallback"))
        #expect(
          fallback.variants[.edited]?.lastError
            == "Edited resource unavailable; original backed up as _orig")
        #expect(fallback.variants[.original]?.filename == "F_orig.HEIC")
        #expect(
          a.isExported(
            asset: TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true),
            selection: .edited, livePhotosPaired: false))
        #expect(
          !a.isExported(
            asset: TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true),
            selection: .editedWithOriginals, livePhotosPaired: false))
        let live = try #require(a.exportInfo(assetId: "live"))
        #expect(
          live.variants[.originalPairedVideo]?.lastError
            == "Photos has no exportable paired video resource for this Live Photo")
        #expect(
          ExportCompletionPolicy.missingVariants(
            required: [.original, .originalPairedVideo], variants: live.variants
          ).isEmpty)
        #expect(a.exportInfo(assetId: "video")?.variants[.original]?.subfolder == "videos")
      }
      a.flushForTesting()
      b.flushForTesting()
    }
  }

  @Test func collectionSnapshotReplayAndReopenPreservePlacementOwnership() throws {
    let fixture = try Fixture(tag: "v1.6.5")
    defer { fixture.cleanup() }
    for _ in 0..<2 {
      let a = CollectionExportRecordStore(baseDirectoryURL: fixture.root)
      let b = CollectionExportRecordStore(baseDirectoryURL: fixture.root)
      a.configure(for: "A")
      b.configure(for: "B")
      #expect(a.state == .ready && b.state == .ready)
      #expect(
        Set(a.placements.keys) == ["collections:favorites", "fixture-album", "fixture-shared"])
      let favorites = try #require(a.placements["collections:favorites"])
      let album = try #require(a.placements["fixture-album"])
      let shared = try #require(a.placements["fixture-shared"])
      #expect(favorites.relativePath == "Collections/Favorites/")
      #expect(album.relativePath == "Collections/Albums/Nested/Album/")
      #expect(shared.relativePath == "Collections/Shared Albums/Shared/")
      #expect(favorites.createdAt == date && album.createdAt == date && shared.createdAt == date)
      #expect(
        a.exportInfo(assetId: "shared", placement: favorites)?.variants[.original]?.filename
          == "REPLAY-FAV.JPG")
      #expect(
        a.exportInfo(assetId: "shared", placement: album)?.variants[.original]?.lastError
          == "Album disk error")
      #expect(
        a.exportInfo(assetId: "shared", placement: shared)?.variants[.original]?.filename
          == "SHARED.JPG")
      let asset = TestAssetFactory.makeAsset(id: "shared")
      #expect(
        a.isExported(
          asset: asset, placement: favorites, selection: .edited, livePhotosPaired: false))
      #expect(
        !a.isExported(asset: asset, placement: album, selection: .edited, livePhotosPaired: false))
      #expect(
        a.isExported(
          asset: asset, placement: shared, selection: .editedWithOriginals, livePhotosPaired: false)
      )
      #expect(a.exportInfo(assetId: "deleted", placement: favorites) == nil)
      #expect(
        a.exportInfo(assetId: "snapshot-only", placement: favorites)?.variants[.original]?.filename
          == "SNAP.JPG")
      #expect(
        a.exportInfo(assetId: "log-only", placement: album)?.variants[.original]?.filename
          == "LOG.JPG")
      let interrupted = try #require(a.exportInfo(assetId: "interrupted", placement: album))
      #expect(interrupted.variants[.original]?.status == .failed)
      #expect(interrupted.variants[.original]?.lastError == "Interrupted before completion")
      #expect(
        a.exportInfo(assetId: "video", placement: album)?.variants[.original]?.subfolder == "videos"
      )
      #expect(
        a.exportInfo(assetId: "shared", placement: favorites)?.variants[.original]?.subfolder == nil
      )
      let fallback = TestAssetFactory.makeAsset(id: "fallback", hasAdjustments: true)
      #expect(
        a.isExported(asset: fallback, placement: album, selection: .edited, livePhotosPaired: false)
      )
      #expect(
        !a.isExported(
          asset: fallback, placement: album, selection: .editedWithOriginals,
          livePhotosPaired: false))
      let live = try #require(a.exportInfo(assetId: "live", placement: album))
      #expect(
        live.variants[.originalPairedVideo]?.lastError
          == "Photos has no exportable paired video resource for this Live Photo")
      #expect(
        ExportCompletionPolicy.missingVariants(
          required: [.original, .originalPairedVideo], variants: live.variants
        ).isEmpty)
      #expect(Set(b.placements.keys) == ["collections:favorites"])
      #expect(
        b.exportInfo(assetId: "shared", placement: favorites)?.variants[.original]?.lastError
          == "Other destination")
      #expect(
        !b.isExported(
          asset: asset, placement: favorites, selection: .edited, livePhotosPaired: false))
      a.flushForTesting()
      b.flushForTesting()
    }
  }

  /// Import Existing Backup's album adoption on top of v1.6.5 collection history: it appends
  /// only the existing placement and record operations, keeps the saved placement's folder and
  /// completed variants, and the result reopens.
  @Test func collectionBulkImportOnHistoricalStoreUsesExistingOperations() throws {
    let fixture = try Fixture(tag: "v1.6.5")
    defer { fixture.cleanup() }
    let logURL = fixture.root.appendingPathComponent("A/collection-records.jsonl")
    let originalLog = try Data(contentsOf: logURL)
    let store = CollectionExportRecordStore(baseDirectoryURL: fixture.root)
    store.configure(for: "A")
    let saved = try #require(store.placements["fixture-album"])
    let imported = ExportPlacement(
      kind: .album, id: "collections:album:aaaaaaaaaaaaaaaa:bbbbbbbb", displayName: "Imported",
      collectionLocalIdentifier: "imported", relativePath: "Collections/Albums/Imported/",
      createdAt: date)
    func done(_ name: String) -> ExportVariantRecord {
      ExportVariantRecord(filename: name, status: .done, exportDate: date, lastError: nil)
    }
    let batches: [CollectionExportRecordStore.ImportBatch] = [
      .init(
        placement: ExportPlacement(
          kind: .album, id: saved.id, displayName: "Renamed", collectionLocalIdentifier: "x",
          relativePath: saved.relativePath, createdAt: Date()),
        records: [
          "shared": [.original: done("ALBUM.JPG")], "log-only": [.original: done("OTHER.JPG")],
          "new": [.original: done("NEW.JPG")],
        ]),
      .init(placement: imported, records: ["new": [.original: done("NEW.JPG")]]),
    ]
    let placementsBefore = store.placements.count
    store.bulkImportRecords(batches)
    store.flushForTesting()
    #expect(store.recordedVariantCount(of: batches) == 4)
    #expect(store.placements.count == placementsBefore + 1)

    let log = try Data(contentsOf: logURL)
    #expect(log.prefix(originalLog.count) == originalLog, "history is appended to, not rewritten")
    let appended = log.dropFirst(originalLog.count).split(separator: UInt8(ascii: "\n"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let ops = try appended.map {
      try decoder.decode(CollectionExportRecordStore.LogOp.self, from: Data($0))
    }
    #expect(ops.count == 4)
    for line in appended {
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      #expect(["upsertPlacement", "upsertRecord"].contains(object["op"] as? String))
    }

    let reopened = CollectionExportRecordStore(baseDirectoryURL: fixture.root)
    reopened.configure(for: "A")
    #expect(reopened.state == .ready)
    let album = try #require(reopened.placements["fixture-album"])
    #expect(album.relativePath == "Collections/Albums/Nested/Album/")
    #expect(album.displayName == saved.displayName && album.createdAt == date)
    #expect(reopened.placements[imported.id]?.relativePath == imported.relativePath)
    #expect(
      reopened.exportInfo(assetId: "shared", placement: album)?.variants[.original]?.filename
        == "ALBUM.JPG")
    #expect(
      reopened.exportInfo(assetId: "log-only", placement: album)?.variants[.original]?.filename
        == "LOG.JPG")
    #expect(reopened.exportInfo(assetId: "new", placement: imported) != nil)
    #expect(
      reopened.exportInfo(assetId: "video", placement: album)?.variants[.original]?.subfolder
        == "videos")
    reopened.flushForTesting()
  }
}
