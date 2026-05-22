import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Scanner tests for variant-aware classification under the redesigned `_orig`-companion
/// naming convention.
@MainActor
struct BackupScannerVariantTests {
  /// `subdir` (issue #38): when non-nil, the file is materialised inside
  /// `YYYY/MM/<subdir>/` and the synthesized `ScannedFile.subfolder` carries
  /// the same value. The scanner emits `subfolder = "videos"` for files it
  /// finds in `YYYY/MM/videos/`; tests pass `subdir: "videos"` to construct
  /// fixtures that mimic what the scanner would produce.
  private func makeScannedFile(
    _ filename: String, year: Int = 2025, month: Int = 6, modDate: Date? = nil,
    subdir: String? = nil
  ) throws -> (BackupScanner.ScannedFile, URL) {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSV-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
    let monthStr = String(format: "%02d", month)
    var dir = rootDir.appendingPathComponent("\(year)", isDirectory: true)
      .appendingPathComponent(monthStr, isDirectory: true)
    if let subdir, !subdir.isEmpty {
      dir = dir.appendingPathComponent(subdir, isDirectory: true)
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(filename)
    FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
    let ext = url.pathExtension
    let stem = (filename as NSString).deletingPathExtension
    let (baseStem, hadSuffix) = BackupScanner.stripCollisionSuffix(from: stem)
    let baseFilename = ext.isEmpty ? baseStem : baseStem + "." + ext
    let sf = BackupScanner.ScannedFile(
      url: url,
      year: year,
      month: month,
      filename: filename,
      baseFilename: baseFilename,
      hasCollisionSuffix: hadSuffix,
      fileExtension: ext.lowercased(),
      modificationDate: modDate,
      fileSize: 4,
      subfolder: subdir
    )
    return (sf, rootDir)
  }

  private func service(
    _ assetsByYearMonth: [String: [AssetDescriptor]],
    resources: [String: [ResourceDescriptor]]
  ) -> FakePhotoLibraryService {
    let svc = FakePhotoLibraryService()
    svc.assetsByYearMonth = assetsByYearMonth
    svc.resourcesByAssetId = resources
    return svc
  }

  // MARK: - Exact original match

  @Test func classifiesOriginalFileAsOriginalVariant() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "orig-asset", creationDate: modDate, hasAdjustments: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "orig-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
    #expect(result.matched.first?.asset.id == "orig-asset")
  }

  // MARK: - Cross-extension default-mode classifier

  @Test func classifiesEditedJpegAgainstHeicOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "heic-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "heic-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .edited)
    #expect(result.matched.first?.asset.id == "heic-asset")
  }

  // MARK: - Same-extension default-mode classifies as `.original`

  @Test func classifiesSameExtensionEditAsOriginalWhenStemAndExtMatchOriginalResource()
    async throws
  {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "jpg-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "jpg-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    // Default mode wrote `IMG_0001.JPG` (the edit, but at natural stem). Scanner can't
    // distinguish this from the original by filename alone — documented limitation.
    let (file, root) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - `_orig` companion classifies as `.original`

  @Test func origCompanionClassifiesAsOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "pair-asset", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "pair-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001_orig.HEIC", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
    #expect(result.matched.first?.asset.id == "pair-asset")
  }

  // MARK: - User filename `vacation_orig.JPG` falls through to step 2

  @Test func userOrigFilenameWithoutAdjustedSiblingClassifiesAsOriginal() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Asset is unedited; its actual original filename is `vacation_orig.JPG`. No asset with
    // stem `vacation` and adjustments exists, so step 1 fails to match and the file falls
    // through to step 2 (exact original).
    let asset = TestAssetFactory.makeAsset(
      id: "user-named", creationDate: modDate, hasAdjustments: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "user-named": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "vacation_orig.JPG")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("vacation_orig.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - Native ` (N)` filename + `_orig` companion → edit + original pair

  @Test func nativeCollisionSuffixedAssetWithOrigCompanionPairsAsEditAndOriginal() async throws {
    // Asset's actual original filename is `IMG_0001 (1).JPG` (native ` (N)` in the user's
    // filename, not app-added). Destination has the include-originals output:
    // `IMG_0001 (1).JPG` (the edit, at the asset's native stem) and
    // `IMG_0001 (1)_orig.JPG` (the original companion). The natural-stem file pairs with
    // the `_orig` sibling, so it must classify as `.edited`, not `.original`.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "native-suffix", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "native-suffix": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001 (1).JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (editedFile, root1) = try makeScannedFile(
      "IMG_0001 (1).JPG", modDate: modDate)
    let (origFile, root2) = try makeScannedFile(
      "IMG_0001 (1)_orig.JPG", year: 2025, month: 6, modDate: modDate)
    defer {
      try? FileManager.default.removeItem(at: root1)
      try? FileManager.default.removeItem(at: root2)
    }

    let result = try await BackupScanner.matchFiles(
      [editedFile, origFile], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 2)
    let byFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map { ($0.file.filename, $0.variant) })
    #expect(byFilename["IMG_0001 (1).JPG"] == .edited)
    #expect(byFilename["IMG_0001 (1)_orig.JPG"] == .original)
  }

  // MARK: - Same-extension include-originals pair classifies losslessly

  @Test func sameExtensionIncludeOriginalsPairClassifiesEditAndOriginal() async throws {
    // Asset is JPEG → JPEG-edited, exported with include-originals: destination contains
    // `IMG_0001.JPG` (edit) + `IMG_0001_orig.JPG` (original). The pair-aware classifier
    // uses the `_orig` sibling signal to label the natural-stem file as `.edited`.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "jpg-pair", creationDate: modDate, hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "jpg-pair": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullRender.JPG"),
        ]
      ]
    )
    let (editFile, root1) = try makeScannedFile("IMG_0001.JPG", modDate: modDate)
    let (origFile, root2) = try makeScannedFile(
      "IMG_0001_orig.JPG", year: 2025, month: 6, modDate: modDate)
    defer {
      try? FileManager.default.removeItem(at: root1)
      try? FileManager.default.removeItem(at: root2)
    }

    let result = try await BackupScanner.matchFiles(
      [editFile, origFile], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 2)
    let byFilename = Dictionary(
      uniqueKeysWithValues: result.matched.map { ($0.file.filename, $0.variant) })
    #expect(byFilename["IMG_0001.JPG"] == .edited)
    #expect(byFilename["IMG_0001_orig.JPG"] == .original)
  }

  // MARK: - Two adjusted assets share a stem; date narrows to one

  @Test func origCompanionDisambiguatesByDateWhenMultipleCandidates() async throws {
    let modDateA = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let modDateB = Date(timeIntervalSinceReferenceDate: 900_000_000)
    let assetA = TestAssetFactory.makeAsset(
      id: "asset-a", creationDate: modDateA, hasAdjustments: true)
    let assetB = TestAssetFactory.makeAsset(
      id: "asset-b", creationDate: modDateB, hasAdjustments: true)
    let svc = service(
      ["2025-6": [assetA, assetB]],
      resources: [
        "asset-a": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullA.JPG"),
        ],
        "asset-b": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullB.JPG"),
        ],
      ]
    )
    // The companion's mod date matches Asset B.
    let (file, root) = try makeScannedFile("IMG_TEST_orig.JPG", modDate: modDateB)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.asset.id == "asset-b")
    #expect(result.matched.first?.variant == .original)
  }

  // MARK: - `_orig` matching with multiple candidates and identical dates → ambiguous

  @Test func origCompanionWithIdenticalDatesIsAmbiguous() async throws {
    // Two adjusted assets share both an original Photos filename and a creation date.
    // Step 1 collects both; `narrow` cannot pick one by date (identical), so the file
    // is ambiguous rather than a coin-flip classification.
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // Distinct dimensions so dimension-based discriminator can't accidentally match either.
    let assetA = TestAssetFactory.makeAsset(
      id: "asset-a", creationDate: modDate, pixelWidth: 100, pixelHeight: 100,
      hasAdjustments: true)
    let assetB = TestAssetFactory.makeAsset(
      id: "asset-b", creationDate: modDate, pixelWidth: 200, pixelHeight: 200,
      hasAdjustments: true)
    let svc = service(
      ["2025-6": [assetA, assetB]],
      resources: [
        "asset-a": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullA.JPG"),
        ],
        "asset-b": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_TEST.JPG"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullB.JPG"),
        ],
      ]
    )
    let (file, root) = try makeScannedFile("IMG_TEST_orig.JPG", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.isEmpty)
    #expect(result.ambiguous.count == 1)
  }

  // MARK: - Import merges original and edited into separate variants

  @Test func importMergesOriginalAndEditedForSameAsset() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSV-merge-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let store = ExportRecordStore(baseDirectoryURL: tempDir)
    store.configure(for: "merge-test")

    let now = Date()
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_0001_orig.HEIC", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.bulkImportRecords([
      ExportRecord(
        id: "pair", year: 2025, month: 3, relPath: "2025/03/",
        variants: [
          .edited: ExportVariantRecord(
            filename: "IMG_0001.JPG", status: .done, exportDate: now, lastError: nil)
        ])
    ])
    store.flushForTesting()

    let record = store.exportInfo(assetId: "pair")
    #expect(record?.variants[.original]?.status == .done)
    #expect(record?.variants[.edited]?.status == .done)
    #expect(record?.variants[.original]?.filename == "IMG_0001_orig.HEIC")
    #expect(record?.variants[.edited]?.filename == "IMG_0001.JPG")
  }

  // MARK: - Live Photo paired-video classification

  /// Unedited Live Photo: only the still and motion files exist on disk. The `.mov`
  /// at the natural stem classifies as `.originalPairedVideo`, not a stray full-length
  /// video. Without the Live Photo-aware classifier the scanner would dump the file
  /// into `.unmatched` and the next export would write a duplicate.
  @Test func classifiesUneditedLivePhotoMovAsOriginalPairedVideo() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "live-asset", creationDate: modDate, hasAdjustments: false, isLivePhoto: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "live-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001.MOV", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .originalPairedVideo)
    #expect(result.matched.first?.asset.id == "live-asset")
  }

  /// Edited Live Photo: both `<stem>_orig.HEIC` + `<stem>_orig.mov` and the rendered
  /// `<stem>.HEIC` + `<stem>.mov` are on disk. The `_orig.mov` sibling promotes the
  /// natural-stem `.mov` to `.editedPairedVideo`.
  @Test func classifiesEditedLivePhotoNaturalMovAsEditedPairedVideo() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "live-asset", creationDate: modDate, hasAdjustments: true, isLivePhoto: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "live-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
          TestAssetFactory.makeResource(
            type: .fullSizePhoto, originalFilename: "FullSize.HEIC"),
          TestAssetFactory.makeResource(
            type: .fullSizePairedVideo, originalFilename: "FullSize.MOV"),
        ]
      ]
    )
    // Plant all four files; the matcher needs to see the _orig.mov sibling to promote
    // the natural-stem .mov to `.editedPairedVideo`.
    let (origMov, root) = try makeScannedFile("IMG_0001_orig.MOV", modDate: modDate)
    let (naturalMov, _) = try makeScannedFile("IMG_0001.MOV", modDate: modDate)
    let (origHeic, _) = try makeScannedFile("IMG_0001_orig.HEIC", modDate: modDate)
    let (naturalHeic, _) = try makeScannedFile("IMG_0001.HEIC", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [origMov, naturalMov, origHeic, naturalHeic],
      photoLibraryService: svc, progress: { _ in })

    let naturalMovMatch = result.matched.first {
      $0.file.filename == "IMG_0001.MOV"
    }
    let origMovMatch = result.matched.first {
      $0.file.filename == "IMG_0001_orig.MOV"
    }
    #expect(naturalMovMatch?.variant == .editedPairedVideo)
    #expect(origMovMatch?.variant == .originalPairedVideo)
  }

  /// `<stem>_orig.mov` next to a Live Photo classifies as `.originalPairedVideo` even
  /// without the rendered `.mov` companion present (e.g. partial backup, or Live Photo
  /// edit that elided the `.fullSizePairedVideo` resource).
  @Test func classifiesLivePhotoOrigMovAsOriginalPairedVideo() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "live-asset", creationDate: modDate, hasAdjustments: true, isLivePhoto: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "live-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001_orig.MOV", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .originalPairedVideo)
  }

  /// Issue #49 regression guard: the scanner classifies paired-video files correctly
  /// even when the descriptor's `isLivePhoto` flag is stale/false. This is the import-
  /// existing-backup-with-toggle-off path — `descriptor(from:)` skips the resource
  /// fallback when the user hasn't enabled paired-video export, so the descriptor's
  /// flag may be `false` for an iCloud-synced Live Photo. The scanner builds its
  /// own fingerprint by reading the resource list directly, so the `.mov` file still
  /// gets classified as `.originalPairedVideo`.
  ///
  /// Without this self-sufficiency, importing a backup with paired-video files while
  /// the toggle is off would mis-classify them; later turning the toggle on would
  /// re-export Live Photos and trip the destination resolver's Code 5 ("Paired
  /// original filename already exists on disk") on the existing `.mov`.
  @Test func scannerClassifiesPairedVideoEvenWhenAssetIsLivePhotoFlagIsFalse() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    // The asset descriptor's `isLivePhoto` is *false* — the scenario where the user
    // has the Settings toggle off and `detectLivePhoto` short-circuits before the
    // resource fallback. PhotoKit still returns the `.pairedVideo` resource when
    // asked for the asset's resources, which is the signal the scanner uses.
    let asset = TestAssetFactory.makeAsset(
      id: "live-asset", creationDate: modDate, hasAdjustments: false, isLivePhoto: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "live-asset": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_0001.HEIC"),
          TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_0001.MOV"),
        ]
      ]
    )
    let (file, root) = try makeScannedFile("IMG_0001.MOV", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .originalPairedVideo)
    #expect(result.matched.first?.asset.id == "live-asset")
  }

  /// A `.mov` file matching a regular full-length video asset (not Live Photo) still
  /// classifies as `.original` — the paired-video step requires `isLivePhoto` on the
  /// fingerprint, so a non-Live-Photo video doesn't fall through into a misclassified
  /// `.originalPairedVideo`. Regression guard for the disambiguation.
  @Test func classifiesFullVideoMovAsOriginalNotPairedVideo() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "video-asset", creationDate: modDate, mediaType: .video,
      hasAdjustments: false, isLivePhoto: false)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "video-asset": [
          TestAssetFactory.makeResource(type: .video, originalFilename: "MOV_0001.MOV")
        ]
      ]
    )
    let (file, root) = try makeScannedFile("MOV_0001.MOV", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try await BackupScanner.matchFiles(
      [file], photoLibraryService: svc, progress: { _ in })
    #expect(result.matched.count == 1)
    #expect(result.matched.first?.variant == .original)
    #expect(result.matched.first?.asset.id == "video-asset")
  }

  // MARK: - Videos-subfolder discovery (issue #38)

  /// `scanBackupFolder` descends into `YYYY/MM/videos/` (if present) and emits
  /// `subfolder = "videos"` on the synthesised `ScannedFile`. Without this descent,
  /// a backup written under the subfolder layout would be silently invisible to
  /// Import Existing Backup — videos in the subfolder would not match and would
  /// be re-exported as duplicates on the next run.
  @Test func scanBackupFolderDescendsIntoVideosSubfolder() throws {
    let rootDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BSV-scan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootDir) }
    let monthDir = rootDir.appendingPathComponent("2026/03", isDirectory: true)
    let videosDir = monthDir.appendingPathComponent("videos", isDirectory: true)
    try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: monthDir.appendingPathComponent("IMG_PHOTO.JPG").path,
      contents: Data("photo".utf8))
    FileManager.default.createFile(
      atPath: videosDir.appendingPathComponent("IMG_VIDEO.MOV").path,
      contents: Data("video".utf8))

    let files = BackupScanner.scanBackupFolder(at: rootDir)

    #expect(files.count == 2)
    let photo = files.first(where: { $0.filename == "IMG_PHOTO.JPG" })
    let video = files.first(where: { $0.filename == "IMG_VIDEO.MOV" })
    #expect(photo?.subfolder == nil)
    #expect(video?.subfolder == "videos")
    // Both attribute to the same (year, month).
    #expect(photo?.year == 2026)
    #expect(photo?.month == 3)
    #expect(video?.year == 2026)
    #expect(video?.month == 3)
  }

  /// Mid-life mixed-layout standalone video (codex P2): the user exported
  /// `.original` under `.flat` (lands at `2026/03/IMG.MOV`), then flipped
  /// `videoLayout` to `.subfolder` after Photos exposed an edit, and the
  /// subsequent run wrote `.edited` to `2026/03/videos/IMG.MOV`. Same stem,
  /// same `.MOV` extension, no `_orig` sibling.
  ///
  /// Without the subfolder-split disambiguator, both files match step 2's
  /// exact-filename rule and both classify as `.original` against the same
  /// adjusted asset — the `.edited` data on disk is lost on import and the
  /// next export run would write a duplicate motion file. The classifier
  /// uses the same-stem-at-both-subfolders signal as the tiebreaker: the
  /// file in `videos/` is the `.edited` variant; the bare-path file is
  /// `.original`. Both come out matched, each carrying its own `subfolder`.
  @Test func classifierDisambiguatesMidLifeMixedLayoutStandaloneVideo() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "video-mid-life", creationDate: modDate, mediaType: .video,
      hasAdjustments: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "video-mid-life": [
          TestAssetFactory.makeResource(type: .video, originalFilename: "IMG.MOV"),
          TestAssetFactory.makeResource(
            type: .fullSizeVideo, originalFilename: "IMG.MOV"),
        ]
      ]
    )
    let (originalAtBase, root1) = try makeScannedFile("IMG.MOV", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root1) }
    let (editedInVideos, root2) = try makeScannedFile(
      "IMG.MOV", modDate: modDate, subdir: "videos")
    defer { try? FileManager.default.removeItem(at: root2) }

    let result = try await BackupScanner.matchFiles(
      [originalAtBase, editedInVideos], photoLibraryService: svc, progress: { _ in })

    #expect(result.matched.count == 2)
    #expect(result.ambiguous.isEmpty)
    #expect(result.unmatched.isEmpty)
    let bareMatch = result.matched.first(where: { $0.file.subfolder == nil })
    let videosMatch = result.matched.first(where: { $0.file.subfolder == "videos" })
    #expect(bareMatch?.variant == .original)
    #expect(videosMatch?.variant == .edited)
    // Both attribute to the same asset.
    #expect(bareMatch?.asset.id == "video-mid-life")
    #expect(videosMatch?.asset.id == "video-mid-life")
  }

  /// Cross-directory Live Photo pairing: the still lives at the base path and the
  /// paired motion lives in `videos/`. The paired-video classifier matches by stem
  /// within `(year, month)` — not by directory — so it still pairs them. Pins that
  /// behaviour so a future "same-directory" tightening doesn't silently re-export
  /// the motion as an unmatched duplicate.
  @Test func classifierPairsLivePhotoAcrossSubfolderSplit() async throws {
    let modDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let asset = TestAssetFactory.makeAsset(
      id: "live-split", creationDate: modDate, hasAdjustments: false,
      isLivePhoto: true)
    let svc = service(
      ["2025-6": [asset]],
      resources: [
        "live-split": [
          TestAssetFactory.makeResource(type: .photo, originalFilename: "IMG_LIVE.HEIC"),
          TestAssetFactory.makeResource(type: .pairedVideo, originalFilename: "IMG_LIVE.MOV"),
        ]
      ]
    )
    let (still, root1) = try makeScannedFile("IMG_LIVE.HEIC", modDate: modDate)
    defer { try? FileManager.default.removeItem(at: root1) }
    let (motion, root2) = try makeScannedFile(
      "IMG_LIVE.MOV", modDate: modDate, subdir: "videos")
    defer { try? FileManager.default.removeItem(at: root2) }

    let result = try await BackupScanner.matchFiles(
      [still, motion], photoLibraryService: svc, progress: { _ in })

    #expect(result.matched.count == 2)
    let stillMatch = result.matched.first(where: { $0.file.filename == "IMG_LIVE.HEIC" })
    let motionMatch = result.matched.first(where: { $0.file.filename == "IMG_LIVE.MOV" })
    #expect(stillMatch?.variant == .original)
    #expect(motionMatch?.variant == .originalPairedVideo)
    // The motion's `subfolder` survives matching so the rebuilt record points at
    // the file's actual on-disk location.
    #expect(motionMatch?.file.subfolder == "videos")
    #expect(stillMatch?.file.subfolder == nil)
  }
}
