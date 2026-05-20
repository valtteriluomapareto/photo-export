import Foundation
import Testing

@testable import Photo_Export

struct ExportFilenamePolicyTests {
  // MARK: - originalFilename

  @Test func originalFilenameWithoutSuffix() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "JPG", withSuffix: false)
        == "IMG_0001.JPG")
  }

  @Test func originalFilenameWithOrigSuffix() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "HEIC", withSuffix: true)
        == "IMG_0001_orig.HEIC")
  }

  @Test func originalFilenamePreservesCollisionSuffixInStem() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001 (1)", ext: "JPG", withSuffix: true)
        == "IMG_0001 (1)_orig.JPG")
  }

  // MARK: - editedFilename

  @Test func editedFilenameUsesGroupStemPlusEditedExtension() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001.JPG")
  }

  @Test func editedFilenamePicksUpRenderedJpegFromHeicOriginal() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001",
        editedResourceFilename: "FullSizeRender.JPG"
      ) == "IMG_0001.JPG")
  }

  @Test func editedFilenamePreservesCollisionSuffixInStem() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001 (1)",
        editedResourceFilename: "IMG_E0001.JPG"
      ) == "IMG_0001 (1).JPG")
  }

  // MARK: - parseOriginalCandidate

  @Test func parseOriginalCandidateRecognizesPlainOrigFilename() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001_orig.JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
    #expect(parsed?.fileExtension == "JPG")
  }

  @Test func parseOriginalCandidatePreservesGroupCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(
      filename: "IMG_0001 (1)_orig.JPG")
    #expect(parsed?.groupStem == "IMG_0001 (1)")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == nil)
  }

  @Test func parseOriginalCandidateRecognizesFinalFileCollisionSuffix() {
    let parsed = ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001_orig (1).JPG")
    #expect(parsed?.groupStem == "IMG_0001")
    #expect(parsed?.canonicalOriginalStem == "IMG_0001")
    #expect(parsed?.fileCollisionSuffix == 1)
  }

  @Test func parseOriginalCandidateReturnsNilForNonOrigFilename() {
    #expect(ExportFilenamePolicy.parseOriginalCandidate(filename: "IMG_0001.JPG") == nil)
    #expect(
      ExportFilenamePolicy.parseOriginalCandidate(filename: "vacation_2020.JPG") == nil)
  }

  @Test func parseOriginalCandidateRequiresOrigSuffixOnStem() {
    #expect(
      ExportFilenamePolicy.parseOriginalCandidate(filename: "my_orig_photo.JPG") == nil)
  }

  // MARK: - isOrigCompanion

  @Test func isOrigCompanionMatchesPlainAndCollisionForms() {
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001.JPG") == false)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001 (1).JPG") == false)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001_orig.JPG") == true)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001_orig (1).JPG") == true)
    // The predicate is shape-only: a real user filename ending in `_orig` matches.
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "vacation_orig.JPG") == true)
  }

  // MARK: - Paired-video filenames

  /// The existing image-side helpers are extension-agnostic: passing a `.mov`
  /// extension produces the right Live-Photo paired-video filename. Pinned here
  /// so a future refactor that special-cases `JPG`/`HEIC` doesn't silently break
  /// the motion-file path.
  @Test func originalFilenameProducesPlainMovWhenUnpaired() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "MOV", withSuffix: false)
        == "IMG_0001.MOV")
  }

  /// `.originalPairedVideo` paired with `.editedPairedVideo` → the motion file
  /// takes the `_orig` suffix in lock-step with the still-side `.original`.
  @Test func originalFilenameProducesOrigMovWhenPairedWithEdited() {
    #expect(
      ExportFilenamePolicy.originalFilename(stem: "IMG_0001", ext: "MOV", withSuffix: true)
        == "IMG_0001_orig.MOV")
  }

  /// `.editedPairedVideo` lands at `<groupStem>.mov` regardless of the resource's
  /// reported filename casing.
  @Test func editedFilenameForPairedVideoLandsAtGroupStemMov() {
    #expect(
      ExportFilenamePolicy.editedFilename(
        stem: "IMG_0001",
        editedResourceFilename: "IMG_E0001.MOV"
      ) == "IMG_0001.MOV")
  }

  /// `_orig`-companion detection works on `.mov` filenames too, so a future
  /// scanner pass over a backup folder can identify Live Photo originals
  /// without an extension allow-list.
  @Test func isOrigCompanionRecognizesMovOrigFilename() {
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001_orig.MOV") == true)
    #expect(ExportFilenamePolicy.isOrigCompanion(filename: "IMG_0001.MOV") == false)
  }
}
