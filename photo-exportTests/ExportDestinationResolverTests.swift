import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Phase 2 unit tests for `ExportDestinationResolver`. The resolver owns every destination
/// URL and filename decision (stem allocation, `_orig` companion naming, unique-filename
/// collision suffixing, recovered group stems). These tests pin each rule directly against
/// a real temp-dir filesystem so a refactor cannot quietly change *where files land* — the
/// single most user-visible kind of regression in this codebase.
struct ExportDestinationResolverTests {

  // MARK: - Fixtures

  /// Creates a temp dir for the test and a resolver wired to the real filesystem service.
  private static func makeResolver(prefix: String = "DestResolver") throws -> (URL, ExportDestinationResolver) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let resolver = ExportDestinationResolver(fileSystem: FileIOService())
    return (dir, resolver)
  }

  private static func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  private func plantFile(_ name: String, in dir: URL) {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
  }

  private func makeAsset(hasAdjustments: Bool = false, isLivePhoto: Bool = false)
    -> AssetDescriptor
  {
    TestAssetFactory.makeAsset(hasAdjustments: hasAdjustments, isLivePhoto: isLivePhoto)
  }

  private func makePhotoResource(_ filename: String) -> ResourceDescriptor {
    TestAssetFactory.makeResource(type: .photo, originalFilename: filename)
  }

  // MARK: - splitFilename

  @Test func splitFilename_basic() {
    let r = ExportDestinationResolver.splitFilename("IMG_0001.JPG")
    #expect(r.base == "IMG_0001")
    #expect(r.ext == "JPG")
  }

  @Test func splitFilename_multipleDots() {
    let r = ExportDestinationResolver.splitFilename("my.photo.file.heic")
    #expect(r.base == "my.photo.file")
    #expect(r.ext == "heic")
  }

  @Test func splitFilename_noExtension() {
    let r = ExportDestinationResolver.splitFilename("README")
    #expect(r.base == "README")
    #expect(r.ext == "")
  }

  @Test func splitFilename_withSpacesAndCollisionSuffix() {
    let r = ExportDestinationResolver.splitFilename("My Photo (1).png")
    #expect(r.base == "My Photo (1)")
    #expect(r.ext == "png")
  }

  /// `URL(fileURLWithPath:)` strips any preceding path components — `splitFilename` returns
  /// only the leaf base and extension. Load-bearing because some call sites pass values
  /// that, in malformed inputs, could contain slashes.
  @Test func splitFilename_pathStripping_returnsOnlyLeaf() {
    let r = ExportDestinationResolver.splitFilename("a/b/c.jpg")
    #expect(r.base == "c")
    #expect(r.ext == "jpg")
  }

  // MARK: - uniqueFileURL

  @Test func uniqueFileURL_noConflict() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let url = resolver.uniqueFileURL(in: dir, baseName: "photo", ext: "jpg")
    #expect(url.lastPathComponent == "photo.jpg")
  }

  @Test func uniqueFileURL_withConflicts() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("photo.jpg", in: dir)
    plantFile("photo (1).jpg", in: dir)
    let url = resolver.uniqueFileURL(in: dir, baseName: "photo", ext: "jpg")
    #expect(url.lastPathComponent == "photo (2).jpg")
  }

  @Test func uniqueFileURL_sequentialConflicts() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG.heic", in: dir)
    for i in 1...5 {
      plantFile("IMG (\(i)).heic", in: dir)
    }
    let url = resolver.uniqueFileURL(in: dir, baseName: "IMG", ext: "heic")
    #expect(url.lastPathComponent == "IMG (6).heic")
  }

  /// Loop is capped at 10 000 iterations. On overflow, the function must return the last
  /// attempted URL rather than spinning forever or trapping. Uses a programmable fake
  /// filesystem because planting 10 000 real files is wasteful.
  @Test func uniqueFileURL_capRespected_returnsLastAttemptedURL() {
    final class AlwaysExists: FileSystemService, @unchecked Sendable {
      func fileExists(atPath path: String) -> Bool { true }
      func moveItemAtomically(from src: URL, to dst: URL) throws {}
      func applyTimestamps(creationDate: Date, to url: URL) {}
      func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
      func removeItem(at url: URL) throws {}
      func copyItem(from src: URL, to dst: URL) throws {}
    }
    let resolver = ExportDestinationResolver(fileSystem: AlwaysExists())
    let dir = URL(fileURLWithPath: "/tmp/cap-test")
    let url = resolver.uniqueFileURL(in: dir, baseName: "X", ext: "JPG")
    // Body increments index until 10 001 and breaks; the last candidate it constructed
    // before the break is "X (10000).JPG".
    #expect(url.lastPathComponent == "X (10000).JPG")
  }

  // MARK: - allocatePairedGroupStem

  @Test func allocatePairedGroupStem_freshSlot_returnsBaseStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir)
    #expect(stem == "IMG_0001")
  }

  @Test func allocatePairedGroupStem_editedSlotOccupied_bumpsCollisionSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001.HEIC", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir)
    #expect(stem == "IMG_0001 (1)")
  }

  @Test func allocatePairedGroupStem_origSlotOccupied_bumpsCollisionSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001_orig.HEIC", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir)
    #expect(stem == "IMG_0001 (1)")
  }

  @Test func allocatePairedGroupStem_requiresBothSlotsFree() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    // IMG_0001.HEIC is occupied; IMG_0001 (1)_orig.HEIC is also occupied; (2) is free
    // for both slots, so it should land at (2).
    plantFile("IMG_0001.HEIC", in: dir)
    plantFile("IMG_0001 (1)_orig.HEIC", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir)
    #expect(stem == "IMG_0001 (2)")
  }

  // MARK: - allocateUnusedOrigStem

  @Test func allocateUnusedOrigStem_freshSlot_returnsBaseStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let stem = resolver.allocateUnusedOrigStem(
      baseStem: "vacation", originalExt: "JPG", destDir: dir)
    #expect(stem == "vacation")
  }

  @Test func allocateUnusedOrigStem_collisionBumps() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("vacation_orig.JPG", in: dir)
    let stem = resolver.allocateUnusedOrigStem(
      baseStem: "vacation", originalExt: "JPG", destDir: dir)
    #expect(stem == "vacation (1)")
  }

  // MARK: - inheritedGroupStem

  @Test func inheritedGroupStem_noRecord_returnsNil() {
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: nil, descriptor: makeAsset(), resources: [])
    #expect(stem == nil)
  }

  @Test func inheritedGroupStem_editedDone_usesEditedStem() {
    var record = ExportRecord(id: "a", year: 2025, month: 7, relPath: "2025/07/")
    record.variants[.edited] = ExportVariantRecord(
      filename: "vacation.HEIC", status: .done, exportDate: Date(), lastError: nil)
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: makeAsset(hasAdjustments: true), resources: [])
    #expect(stem == "vacation")
  }

  @Test func inheritedGroupStem_originalDone_naturalFilename_keepsBareStem() {
    // Original `.done` filename matches the asset's current original-side resource filename
    // → treat as the natural filename, even though it ends with `_orig`.
    var record = ExportRecord(id: "a", year: 2025, month: 7, relPath: "2025/07/")
    record.variants[.original] = ExportVariantRecord(
      filename: "vacation_orig.JPG", status: .done, exportDate: Date(), lastError: nil)
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: makeAsset(),
      resources: [makePhotoResource("vacation_orig.JPG")])
    #expect(stem == "vacation_orig", "matching natural filename keeps the bare stem")
  }

  @Test func inheritedGroupStem_originalDone_appCompanion_stripsOrigSuffix() {
    // Original `.done` filename does NOT match the current natural filename, and ends in
    // `_orig` — treat as an app-written companion and recover the group stem.
    var record = ExportRecord(id: "a", year: 2025, month: 7, relPath: "2025/07/")
    record.variants[.original] = ExportVariantRecord(
      filename: "vacation_orig.JPG", status: .done, exportDate: Date(), lastError: nil)
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: makeAsset(),
      resources: [makePhotoResource("vacation.HEIC")])
    #expect(stem == "vacation", "_orig suffix is stripped when the prior filename is a companion")
  }

  @Test func inheritedGroupStem_originalDone_noOrigSuffix_returnsBareStem() {
    var record = ExportRecord(id: "a", year: 2025, month: 7, relPath: "2025/07/")
    record.variants[.original] = ExportVariantRecord(
      filename: "IMG_0001.HEIC", status: .done, exportDate: Date(), lastError: nil)
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: makeAsset(),
      resources: [makePhotoResource("IMG_0001.HEIC")])
    #expect(stem == "IMG_0001")
  }

  @Test func inheritedGroupStem_originalNotDone_returnsNil() {
    var record = ExportRecord(id: "a", year: 2025, month: 7, relPath: "2025/07/")
    record.variants[.original] = ExportVariantRecord(
      filename: "IMG.HEIC", status: .failed, exportDate: nil, lastError: "boom")
    let stem = ExportDestinationResolver.inheritedGroupStem(
      from: record, descriptor: makeAsset(), resources: [])
    #expect(stem == nil)
  }

  // MARK: - resolveDestination — single variant, no group stem

  @Test func resolveDestination_originalNoGroupStem_landsAtNaturalStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, stem) = try resolver.resolveDestination(
      variant: .original, descriptor: makeAsset(),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: nil, pairOriginalWithSuffix: false)
    #expect(url.lastPathComponent == "IMG_0001.HEIC")
    #expect(stem == "IMG_0001")
  }

  @Test func resolveDestination_originalNoGroupStem_collisionSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001.HEIC", in: dir)
    let (url, _) = try resolver.resolveDestination(
      variant: .original, descriptor: makeAsset(),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: nil, pairOriginalWithSuffix: false)
    #expect(url.lastPathComponent == "IMG_0001 (1).HEIC")
  }

  @Test func resolveDestination_editedNoGroupStem_usesOriginalResourceStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    // Photos.app exports an edited file under the *original* resource's stem (e.g. an asset
    // whose original is IMG_0001.HEIC produces edit at IMG_0001.HEIC). The resolver must
    // honour that even when the request's `originalFilename` argument is the edited resource's
    // filename.
    let (url, stem) = try resolver.resolveDestination(
      variant: .edited, descriptor: makeAsset(hasAdjustments: true),
      originalFilename: "FullSizeRender.HEIC",
      resources: [makePhotoResource("IMG_0001.HEIC")],
      destDir: dir, groupStem: nil, pairOriginalWithSuffix: false)
    #expect(url.lastPathComponent == "IMG_0001.HEIC")
    #expect(stem == "IMG_0001")
  }

  // MARK: - resolveDestination — with group stem (paired pair)

  @Test func resolveDestination_originalPairedWithSuffix_landsAtOrigCompanion() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, stem) = try resolver.resolveDestination(
      variant: .original, descriptor: makeAsset(hasAdjustments: true),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001_orig.HEIC")
    #expect(stem == "IMG_0001")
  }

  @Test func resolveDestination_originalPairedWithSuffix_existingFile_throws() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001_orig.HEIC", in: dir)
    do {
      _ = try resolver.resolveDestination(
        variant: .original, descriptor: makeAsset(hasAdjustments: true),
        originalFilename: "IMG_0001.HEIC", resources: [],
        destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
      Issue.record("Expected throw on paired-original collision")
    } catch let error as NSError {
      // Sentinel preserved across the refactor.
      #expect(error.domain == "Export")
      #expect(error.code == 5)
      #expect(error.localizedDescription.contains("Paired original filename already exists on disk"))
    }
  }

  @Test func resolveDestination_originalUnpairedWithSuffixFalse_landsAtBareStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, _) = try resolver.resolveDestination(
      variant: .original, descriptor: makeAsset(),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: false)
    #expect(url.lastPathComponent == "IMG_0001.HEIC")
  }

  @Test func resolveDestination_editedWithGroupStem_landsAtNaturalStem() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, stem) = try resolver.resolveDestination(
      variant: .edited, descriptor: makeAsset(hasAdjustments: true),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001.HEIC")
    #expect(stem == "IMG_0001")
  }

  @Test func resolveDestination_editedWithGroupStem_existingFile_collisionSuffix() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001.HEIC", in: dir)
    let (url, _) = try resolver.resolveDestination(
      variant: .edited, descriptor: makeAsset(hasAdjustments: true),
      originalFilename: "IMG_0001.HEIC", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    // Documented one-time cost: post-edit case where prior `.original.done` already
    // occupies the natural stem; the new edited write goes to `(1)`.
    #expect(url.lastPathComponent == "IMG_0001 (1).HEIC")
  }

  // MARK: - resolveDestination — Live Photo paired-video variants

  /// `.originalPairedVideo` paired with `.editedPairedVideo` writes the unedited motion
  /// file as the `_orig` companion. Mirrors the still-side `.original` paired rule, with
  /// a `.mov` extension instead of HEIC/JPG.
  @Test func resolveDestination_originalPairedVideo_paired_landsAtOrigMov() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, stem) = try resolver.resolveDestination(
      variant: .originalPairedVideo,
      descriptor: makeAsset(hasAdjustments: true, isLivePhoto: true),
      originalFilename: "IMG_0001.MOV", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001_orig.MOV")
    #expect(stem == "IMG_0001")
  }

  /// `.originalPairedVideo` with no `.edited` companion in the run writes the motion
  /// file at the bare stem. Matches `.editedWithOriginals` off for an unedited Live
  /// Photo: the still and motion files both land at the natural stem.
  @Test func resolveDestination_originalPairedVideo_unpaired_landsAtBareMov() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, _) = try resolver.resolveDestination(
      variant: .originalPairedVideo,
      descriptor: makeAsset(isLivePhoto: true),
      originalFilename: "IMG_0001.MOV", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: false)
    #expect(url.lastPathComponent == "IMG_0001.MOV")
  }

  /// `.editedPairedVideo` lands at the natural stem `.mov` — same shape as the image
  /// `.edited` variant. Confirms the `_orig` suffix is never applied to the edited
  /// motion file.
  @Test func resolveDestination_editedPairedVideo_landsAtBareMov() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, stem) = try resolver.resolveDestination(
      variant: .editedPairedVideo,
      descriptor: makeAsset(hasAdjustments: true, isLivePhoto: true),
      originalFilename: "IMG_E0001.MOV", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001.MOV")
    #expect(stem == "IMG_0001")
  }

  /// Collision on the paired-original target throws the same sentinel (code 5) as the
  /// still-side variant — the caller's failure-handling path doesn't branch on which
  /// half of the pair tripped.
  @Test func resolveDestination_originalPairedVideo_existingFile_throwsSentinel() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001_orig.MOV", in: dir)
    do {
      _ = try resolver.resolveDestination(
        variant: .originalPairedVideo,
        descriptor: makeAsset(hasAdjustments: true, isLivePhoto: true),
        originalFilename: "IMG_0001.MOV", resources: [],
        destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
      Issue.record("Expected throw on paired-original-video collision")
    } catch let error as NSError {
      #expect(error.domain == "Export")
      #expect(error.code == 5)
      #expect(error.localizedDescription.contains("IMG_0001_orig.MOV"))
    }
  }

  // MARK: - allocatePairedGroupStem — 4-slot variant

  /// Default (nil `pairedVideoExt`) keeps the legacy 2-slot behaviour exactly. Pinning
  /// here so a refactor that swaps the parameter order or default can't silently change
  /// what an existing call site does.
  @Test func allocatePairedGroupStem_legacy2SlotPathUnchangedWhenPairedVideoNil() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    // Plant only the `.mov` slot. With `pairedVideoExt: nil` the resolver doesn't
    // look at it and returns the base stem.
    plantFile("IMG_0001.MOV", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir,
      pairedVideoExt: nil)
    #expect(stem == "IMG_0001")
  }

  /// Live Photo allocation must reserve all four slots. A pre-existing `.mov` blocks
  /// the base stem even though both image slots are free.
  @Test func allocatePairedGroupStem_4Slot_bumpsWhenPairedVideoEditedOccupied() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001.MOV", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir,
      pairedVideoExt: "MOV")
    #expect(stem == "IMG_0001 (1)")
  }

  /// A pre-existing `_orig.mov` blocks the base stem too — the four-slot freeness
  /// check is symmetric across the image and motion sides of the pair.
  @Test func allocatePairedGroupStem_4Slot_bumpsWhenPairedVideoOrigOccupied() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001_orig.MOV", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir,
      pairedVideoExt: "MOV")
    #expect(stem == "IMG_0001 (1)")
  }

  /// Stem bumps until every one of the four slots at that index is free. Realistic
  /// "partial Live Photo backup on disk" scenario: image slot taken at (0), motion
  /// slot taken at (1); allocator must skip both and land at (2).
  @Test func allocatePairedGroupStem_4Slot_skipsPartiallyOccupiedIndices() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    plantFile("IMG_0001.HEIC", in: dir)
    plantFile("IMG_0001 (1).MOV", in: dir)
    let stem = resolver.allocatePairedGroupStem(
      baseStem: "IMG_0001", editedExt: "HEIC", originalExt: "HEIC", destDir: dir,
      pairedVideoExt: "MOV")
    #expect(stem == "IMG_0001 (2)")
  }

  // MARK: - Casing preservation

  /// The resolver preserves whatever extension casing PhotoKit reports — uppercase or
  /// lowercase. On Apple hardware Live Photo motion files report `.MOV` (uppercase);
  /// on assets imported from other sources the casing can vary. Without this regression
  /// guard, a future "normalize to lowercase" cleanup could silently mismatch the
  /// scanner's filename-equality check on re-import.
  @Test func resolveDestination_pairedVideo_preservesLowercaseExtension() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, _) = try resolver.resolveDestination(
      variant: .originalPairedVideo,
      descriptor: makeAsset(hasAdjustments: true, isLivePhoto: true),
      originalFilename: "IMG_0001.mov", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001_orig.mov")
  }

  @Test func resolveDestination_pairedVideo_preservesUppercaseExtension() throws {
    let (dir, resolver) = try Self.makeResolver()
    defer { Self.cleanup(dir) }
    let (url, _) = try resolver.resolveDestination(
      variant: .originalPairedVideo,
      descriptor: makeAsset(hasAdjustments: true, isLivePhoto: true),
      originalFilename: "IMG_0001.MOV", resources: [],
      destDir: dir, groupStem: "IMG_0001", pairOriginalWithSuffix: true)
    #expect(url.lastPathComponent == "IMG_0001_orig.MOV")
  }
}
