import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Coverage for the resource-file-size discriminator added in issue #32.
///
/// Burst photos commonly land in the "Ambiguous (skipped)" bucket because
/// `BackupScanner.matchFiles` runs out of distinguishing signals: same
/// filename or near-stem, same creation second within 1s tolerance, identical
/// dimensions, no duration. Resource file size is usually the only metadata
/// that differs between burst frames. The discriminator is variant-aware
/// (compares against the matching variant's resources) and conservative —
/// missing or non-unique sizes leave the result `.ambiguous`.
@MainActor
struct BackupScannerSizeDiscriminatorTests {

  // MARK: - Helpers

  private func makeService(
    assets: [(yearMonth: String, descriptors: [AssetDescriptor])],
    resources: [String: [ResourceDescriptor]] = [:]
  ) -> FakePhotoLibraryService {
    let service = FakePhotoLibraryService()
    for (key, descriptors) in assets {
      service.assetsByYearMonth[key] = descriptors
    }
    for (id, res) in resources {
      service.resourcesByAssetId[id] = res
    }
    return service
  }

  private func makeScannedFiles(
    _ files: [(year: Int, month: Int, filename: String, modDate: Date?, fileSize: UInt64?)]
  ) throws -> ([BackupScanner.ScannedFile], URL) {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSSizeTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    var scannedFiles: [BackupScanner.ScannedFile] = []
    for file in files {
      let monthStr = String(format: "%02d", file.month)
      let dir = rootDir.appendingPathComponent("\(file.year)", isDirectory: true)
        .appendingPathComponent(monthStr, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let fileURL = dir.appendingPathComponent(file.filename)
      FileManager.default.createFile(atPath: fileURL.path, contents: Data("test".utf8))
      let ext = fileURL.pathExtension
      let stem = (file.filename as NSString).deletingPathExtension
      let (baseStem, hadSuffix) = BackupScanner.stripCollisionSuffix(from: stem)
      let baseFilename = ext.isEmpty ? baseStem : baseStem + "." + ext
      scannedFiles.append(
        BackupScanner.ScannedFile(
          url: fileURL, year: file.year, month: file.month, filename: file.filename,
          baseFilename: baseFilename, hasCollisionSuffix: hadSuffix,
          fileExtension: ext.lowercased(),
          modificationDate: file.modDate, fileSize: file.fileSize))
    }
    return (scannedFiles, rootDir)
  }

  // MARK: - Tests

  /// Two assets share creation second, dimensions, and filename. Their
  /// resource sizes differ. Each scanned file must match its size-equal
  /// counterpart instead of going to ambiguous.
  @Test func burstDisambiguatedByResourceFileSize() async throws {
    let burstDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let burstA = TestAssetFactory.makeAsset(
      id: "burst-A", creationDate: burstDate, mediaType: .image,
      pixelWidth: 4032, pixelHeight: 3024)
    let burstB = TestAssetFactory.makeAsset(
      id: "burst-B", creationDate: burstDate, mediaType: .image,
      pixelWidth: 4032, pixelHeight: 3024)

    let service = makeService(
      assets: [("2025-6", [burstA, burstB])],
      resources: [
        "burst-A": [
          TestAssetFactory.makeResource(originalFilename: "IMG_5000.HEIC", fileSize: 2_500_000)
        ],
        "burst-B": [
          TestAssetFactory.makeResource(originalFilename: "IMG_5000.HEIC", fileSize: 2_700_000)
        ],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (
        year: 2025, month: 6, filename: "IMG_5000.HEIC", modDate: burstDate,
        fileSize: 2_500_000
      ),
      (
        year: 2025, month: 6, filename: "IMG_5000 (2).HEIC", modDate: burstDate,
        fileSize: 2_700_000
      ),
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.ambiguous.isEmpty)
    #expect(result.unmatched.isEmpty)
    let matchByFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map { ($0.file.filename, $0.asset.id) })
    #expect(matchByFilename["IMG_5000.HEIC"] == "burst-A")
    #expect(matchByFilename["IMG_5000 (2).HEIC"] == "burst-B")
  }

  /// Scanned file's `fileSize` is nil. The discriminator can't compute, so
  /// the result must remain `.ambiguous`.
  @Test func scannedSizeNilLeavesResultAmbiguous() async throws {
    let burstDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let burstA = TestAssetFactory.makeAsset(
      id: "burst-A", creationDate: burstDate, mediaType: .image)
    let burstB = TestAssetFactory.makeAsset(
      id: "burst-B", creationDate: burstDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [burstA, burstB])],
      resources: [
        "burst-A": [
          TestAssetFactory.makeResource(originalFilename: "IMG.HEIC", fileSize: 1_000_000)
        ],
        "burst-B": [
          TestAssetFactory.makeResource(originalFilename: "IMG.HEIC", fileSize: 2_000_000)
        ],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG.HEIC", modDate: burstDate, fileSize: nil)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  /// Resource sizes are nil on both candidates (PhotoKit failed to expose
  /// fileSize). Discriminator finds nothing to match against → ambiguous.
  @Test func resourceSizesNilLeavesResultAmbiguous() async throws {
    let burstDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let burstA = TestAssetFactory.makeAsset(
      id: "burst-A", creationDate: burstDate, mediaType: .image)
    let burstB = TestAssetFactory.makeAsset(
      id: "burst-B", creationDate: burstDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [burstA, burstB])],
      resources: [
        "burst-A": [TestAssetFactory.makeResource(originalFilename: "IMG.HEIC")],
        "burst-B": [TestAssetFactory.makeResource(originalFilename: "IMG.HEIC")],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG.HEIC", modDate: burstDate, fileSize: 1_000_000)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  /// Both candidates have the same resource size. Discriminator finds two
  /// matches, leaves result ambiguous (conservative).
  @Test func equalResourceSizesLeavesResultAmbiguous() async throws {
    let burstDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let burstA = TestAssetFactory.makeAsset(
      id: "burst-A", creationDate: burstDate, mediaType: .image)
    let burstB = TestAssetFactory.makeAsset(
      id: "burst-B", creationDate: burstDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [burstA, burstB])],
      resources: [
        "burst-A": [
          TestAssetFactory.makeResource(originalFilename: "IMG.HEIC", fileSize: 1_500_000)
        ],
        "burst-B": [
          TestAssetFactory.makeResource(originalFilename: "IMG.HEIC", fileSize: 1_500_000)
        ],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (year: 2025, month: 6, filename: "IMG.HEIC", modDate: burstDate, fileSize: 1_500_000)
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  /// Codex pre-merge finding (issue #32 PR review): the size check must be
  /// scoped to the resource that admitted the candidate. Otherwise an
  /// unrelated `.alternatePhoto` (or any other resource) on the same asset
  /// can rescue a candidate whose named-match resource doesn't actually have
  /// the scanned size, silently matching the wrong asset.
  ///
  /// Setup: scanned `IMG_0001.JPG` is 2 MB. Asset A's named-match
  /// `IMG_0001.JPG` is 1 MB but its unrelated `.alternatePhoto` is 2 MB.
  /// Asset B's named-match is 3 MB. With a "any resource on this side"
  /// check, A would incorrectly pass the size narrow via its alternate.
  /// With the scoped check, neither candidate passes → ambiguous (correct).
  @Test func sizeNarrowIgnoresUnrelatedAlternateResources() async throws {
    let burstDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let assetA = TestAssetFactory.makeAsset(
      id: "alt-A", creationDate: burstDate, mediaType: .image)
    let assetB = TestAssetFactory.makeAsset(
      id: "alt-B", creationDate: burstDate, mediaType: .image)

    let service = makeService(
      assets: [("2025-6", [assetA, assetB])],
      resources: [
        "alt-A": [
          TestAssetFactory.makeResource(
            type: .photo, originalFilename: "IMG_0001.JPG", fileSize: 1_000_000),
          // Unrelated alternate resource happens to share the scanned file's
          // size. The pre-fix discriminator would have matched A on this.
          TestAssetFactory.makeResource(
            type: .alternatePhoto, originalFilename: "IMG_0001.RAW",
            fileSize: 2_000_000),
        ],
        "alt-B": [
          TestAssetFactory.makeResource(
            type: .photo, originalFilename: "IMG_0001.JPG", fileSize: 3_000_000)
        ],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      (
        year: 2025, month: 6, filename: "IMG_0001.JPG", modDate: burstDate,
        fileSize: 2_000_000
      )
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  /// Edited variant with `_orig` sibling: the edited scanned file must
  /// compare against the edited resource's size, and the `_orig` file
  /// against the original resource's size. Variant-awareness is the point.
  @Test func variantAwareSizeMatchEditedAndOriginalSiblings() async throws {
    let editDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Two edited assets sharing creation date, dimensions, and original-
    // resource filename. Distinguish A from B by edited-resource size for
    // the .JPG file and by original-resource size for the _orig.HEIC file.
    let editA = TestAssetFactory.makeAsset(
      id: "edit-A", creationDate: editDate, mediaType: .image, hasAdjustments: true)
    let editB = TestAssetFactory.makeAsset(
      id: "edit-B", creationDate: editDate, mediaType: .image, hasAdjustments: true)

    let service = makeService(
      assets: [("2025-6", [editA, editB])],
      resources: [
        "edit-A": [
          TestAssetFactory.makeResource(
            type: .photo, originalFilename: "IMG_9000.HEIC", fileSize: 4_000_000),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "IMG_9000.JPG",
            fileSize: 1_500_000),
        ],
        "edit-B": [
          TestAssetFactory.makeResource(
            type: .photo, originalFilename: "IMG_9000.HEIC", fileSize: 4_200_000),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "IMG_9000.JPG",
            fileSize: 1_700_000),
        ],
      ]
    )

    let (files, rootDir) = try makeScannedFiles([
      // Edited file: must match edit-A's edited-resource size.
      (
        year: 2025, month: 6, filename: "IMG_9000.JPG", modDate: editDate,
        fileSize: 1_500_000
      ),
      // _orig sibling: must match edit-A's original-resource size.
      (
        year: 2025, month: 6, filename: "IMG_9000_orig.HEIC", modDate: editDate,
        fileSize: 4_000_000
      ),
    ])
    defer { try? FileManager.default.removeItem(at: rootDir) }

    let result = try await BackupScanner.matchFiles(
      files, photoLibraryService: service
    ) { _ in }

    #expect(result.ambiguous.isEmpty)
    let matchByFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map {
        ($0.file.filename, ($0.asset.id, $0.variant))
      })
    let edited = matchByFilename["IMG_9000.JPG"]
    let original = matchByFilename["IMG_9000_orig.HEIC"]
    #expect(edited?.0 == "edit-A")
    #expect(edited?.1 == .edited)
    #expect(original?.0 == "edit-A")
    #expect(original?.1 == .original)
  }
}
