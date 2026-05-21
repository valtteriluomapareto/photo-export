import AVFoundation
import Foundation
import Photos
import Testing

@testable import Photo_Export

struct ResourceSelectionTests {
  private func resources(_ types: [(PHAssetResourceType, String)]) -> [ResourceDescriptor] {
    types.map { ResourceDescriptor(type: $0.0, originalFilename: $0.1) }
  }

  private func descriptor(
    id: String = "asset-id",
    mediaType: PHAssetMediaType = .image,
    hasAdjustments: Bool = false
  ) -> AssetDescriptor {
    AssetDescriptor(
      id: id, creationDate: nil, mediaType: mediaType,
      pixelWidth: 0, pixelHeight: 0, duration: 0, hasAdjustments: hasAdjustments)
  }

  // MARK: - Original selection

  @Test func originalPrefersPhotoOverFullSizePhoto() {
    let r = resources([
      (.fullSizePhoto, "edit.JPG"),
      (.photo, "orig.HEIC"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type == .photo)
  }

  @Test func originalFallsBackToAlternatePhoto() {
    let r = resources([
      (.alternatePhoto, "alt.JPG"),
      (.fullSizePhoto, "edit.JPG"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type
        == .alternatePhoto)
  }

  @Test func originalVideoPrefersVideoResource() {
    let r = resources([
      (.fullSizeVideo, "edit.mov"),
      (.video, "orig.mov"),
    ])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .video)?.type == .video)
  }

  @Test func originalReturnsLastResortWhenNoOriginalSideResource() {
    // Matches the existing "use whatever's there" fallback so current broken assets still get a
    // best-effort export.
    let r = resources([(.fullSizePhoto, "edit.JPG")])
    #expect(
      ResourceSelection.selectOriginalResource(from: r, mediaType: .image)?.type
        == .fullSizePhoto)
  }

  // MARK: - Edited producer selection

  @Test func editedProducerPrefersFullSizePhotoForImages() {
    let r = resources([
      (.photo, "orig.HEIC"),
      (.fullSizePhoto, "edit.JPG"),
    ])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    if case .resource(let resource) = producer {
      #expect(resource.type == .fullSizePhoto)
    } else {
      Issue.record("Expected .resource case, got \(producer)")
    }
  }

  @Test func editedProducerNeverFallsBackToPhoto() {
    let r = resources([(.photo, "orig.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    #expect(producer == .none)
  }

  @Test func editedProducerNeverFallsBackToAlternatePhoto() {
    let r = resources([(.alternatePhoto, "alt.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true))
    #expect(producer == .none)
  }

  @Test func editedProducerPrefersFullSizeVideoForVideos() {
    let r = resources([
      (.video, "orig.mov"),
      (.fullSizeVideo, "edit.mov"),
    ])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video, descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    if case .resource(let resource) = producer {
      #expect(resource.type == .fullSizeVideo)
    } else {
      Issue.record("Expected .resource case, got \(producer)")
    }
  }

  @Test func editedProducerRendersAdjustedVideoWithOnlyOriginalResource() {
    // The render path is the fix for issue #18. With no .fullSizeVideo and
    // hasAdjustments=true, we must produce a render request rather than nil.
    let r = resources([(.video, "IMG_1234.MOV")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    if case .render(let request) = producer {
      #expect(request.assetId == "asset-id")
      #expect(request.originalFilename == "IMG_1234.MOV")
      #expect(request.fileType == AVFileType.mov)
      #expect(request.kind == .video)
    } else {
      Issue.record("Expected .render case, got \(producer)")
    }
  }

  @Test func editedProducerNoneForUnadjustedVideoWithOnlyOriginalResource() {
    // hasAdjustments=false means the user has nothing to render — the
    // edited variant should never have been enqueued by the caller, but if
    // we are asked we must answer .none.
    let r = resources([(.video, "IMG_1234.MOV")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: false))
    #expect(producer == .none)
  }

  @Test func editedProducerNoneForVideoWithNoResources() {
    let r: [ResourceDescriptor] = []
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video,
      descriptor: descriptor(mediaType: .video, hasAdjustments: true))
    #expect(producer == .none)
  }

  // MARK: - originalFilename property

  @Test func producerOriginalFilenameMirrorsResource() {
    let resource = ResourceDescriptor(type: .fullSizePhoto, originalFilename: "edit.JPG")
    #expect(EditedProducer.resource(resource).originalFilename == "edit.JPG")
  }

  @Test func producerOriginalFilenameMirrorsRenderRequest() {
    let request = MediaRenderRequest(
      assetId: "id", originalFilename: "IMG_1234.MOV", fileType: .mov, kind: .video)
    #expect(EditedProducer.render(request).originalFilename == "IMG_1234.MOV")
  }

  // MARK: - HEIC→JPEG conversion (issue #47)
  //
  // Eight cases cover the toggle × edited-resource × original-resource matrix
  // for the .image branch. Video controls follow.

  /// Toggle OFF, JPEG edited resource present: existing `.resource` path.
  @Test func editedProducerToggleOffPicksEditedJPEG() {
    let r = resources([(.fullSizePhoto, "edit.JPG"), (.photo, "orig.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: false)
    if case .resource(let res) = producer {
      #expect(res.originalFilename == "edit.JPG")
    } else {
      Issue.record("expected .resource, got \(producer)")
    }
  }

  /// Toggle OFF, edited HEIC resource: returns it as `.resource` (current
  /// behavior — Photos served HEIC for an edited asset; we write the HEIC).
  @Test func editedProducerToggleOffWritesEditedHEICAsResource() {
    let r = resources([(.fullSizePhoto, "edit.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: false)
    if case .resource(let res) = producer {
      #expect(res.originalFilename == "edit.HEIC")
    } else {
      Issue.record("expected .resource, got \(producer)")
    }
  }

  /// Toggle OFF, only HEIC original (unedited): no edited variant.
  @Test func editedProducerToggleOffUneditedHEICReturnsNone() {
    let r = resources([(.photo, "IMG_0001.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: false),
      convertHEICToJPEG: false)
    #expect(producer == .none)
  }

  /// Toggle ON, edited HEIC resource present: convert it. Edited HEIC beats
  /// the original even though `.photo` is also HEIC — synthesizing one JPEG,
  /// not two.
  @Test func editedProducerToggleOnEditedHEICConvertsTheEditedResource() {
    let r = resources([
      (.fullSizePhoto, "IMG_0001.HEIC"),
      (.photo, "IMG_0001.HEIC"),
    ])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: true)
    if case .convertHEIC(let req) = producer {
      #expect(req.assetId == "asset-id")
      #expect(req.sourceResource.type == .fullSizePhoto)
      #expect(req.originalFilename == "IMG_0001.JPG")
    } else {
      Issue.record("expected .convertHEIC, got \(producer)")
    }
  }

  /// Toggle ON, unedited HEIC original: convert it.
  @Test func editedProducerToggleOnUneditedHEICConvertsTheOriginal() {
    let r = resources([(.photo, "IMG_0001.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: false),
      convertHEICToJPEG: true)
    if case .convertHEIC(let req) = producer {
      #expect(req.sourceResource.type == .photo)
      #expect(req.originalFilename == "IMG_0001.JPG")
    } else {
      Issue.record("expected .convertHEIC, got \(producer)")
    }
  }

  /// Toggle ON, edited HEIC + non-HEIC original (cross-imported library
  /// entries): still converts the edit. The original's format doesn't
  /// affect the synthesis decision once an edited resource is in play.
  @Test func editedProducerToggleOnEditedHEICWithNonHEICOriginalConvertsTheEdit() {
    let r = resources([(.fullSizePhoto, "edit.HEIC"), (.photo, "orig.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: true)
    if case .convertHEIC(let req) = producer {
      #expect(req.sourceResource.type == .fullSizePhoto)
      #expect(req.originalFilename == "edit.JPG")
    } else {
      Issue.record("expected .convertHEIC, got \(producer)")
    }
  }

  /// Toggle ON, **adjusted** asset with HEIC original but no `.fullSizePhoto`
  /// — rare iCloud-mid-edit state. Must NOT silently treat the HEIC original
  /// as the edit and ship pre-edit bytes; falls through to `.none` so the
  /// existing `editedResourceUnavailableMessage` recovery handles it later.
  @Test func editedProducerToggleOnAdjustedHEICWithoutEditedResourceReturnsNone() {
    let r = resources([(.photo, "IMG_0001.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: true)
    #expect(producer == .none)
  }

  /// Toggle ON, JPEG edited resource (Photos rendered the edit as JPEG):
  /// behaves like toggle off — no synthesis needed.
  @Test func editedProducerToggleOnJPEGEditFallsThrough() {
    let r = resources([(.fullSizePhoto, "edit.JPG"), (.photo, "orig.HEIC")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: true),
      convertHEICToJPEG: true)
    if case .resource(let res) = producer {
      #expect(res.originalFilename == "edit.JPG")
    } else {
      Issue.record("expected .resource, got \(producer)")
    }
  }

  /// Toggle ON, unedited non-HEIC original (JPG, PNG, etc.): no synthesis;
  /// the user's "Include originals" off case naturally produces no `.edited`
  /// variant (because `requiredVariants` returns `[.original]` for unedited
  /// non-HEIC assets — see issue #47 PR-1 commit).
  @Test func editedProducerToggleOnUneditedJPEGReturnsNone() {
    let r = resources([(.photo, "IMG_0001.JPG")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: false),
      convertHEICToJPEG: true)
    #expect(producer == .none)
  }

  /// Toggle ON applies to HEIF as well (depth-effect / multi-image captures
  /// come back as HEIF rather than HEIC).
  @Test func editedProducerToggleOnHEIFAlsoConverts() {
    let r = resources([(.photo, "IMG_0001.HEIF")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .image, descriptor: descriptor(hasAdjustments: false),
      convertHEICToJPEG: true)
    if case .convertHEIC(let req) = producer {
      #expect(req.originalFilename == "IMG_0001.JPG")
    } else {
      Issue.record("expected .convertHEIC, got \(producer)")
    }
  }

  /// Video assets are unaffected by the toggle — the conversion path is
  /// image-only.
  @Test func editedProducerToggleOnDoesNotAffectVideo() {
    let r = resources([(.video, "MOV_0001.MOV")])
    let producer = ResourceSelection.selectEditedProducer(
      from: r, mediaType: .video, descriptor: descriptor(mediaType: .video, hasAdjustments: true),
      convertHEICToJPEG: true)
    if case .render(let req) = producer {
      #expect(req.originalFilename == "MOV_0001.MOV")
    } else {
      Issue.record("expected .render, got \(producer)")
    }
  }

  // MARK: - ConvertHEICRequest filename derivation

  @Test func jpegFilenameReplacesHEICExtensionWithUppercaseJPG() {
    #expect(ResourceSelection.jpegFilename(replacingExtensionOf: "IMG_0001.HEIC") == "IMG_0001.JPG")
    #expect(ResourceSelection.jpegFilename(replacingExtensionOf: "IMG_0001.heic") == "IMG_0001.JPG")
    #expect(ResourceSelection.jpegFilename(replacingExtensionOf: "IMG_0001.HEIF") == "IMG_0001.JPG")
  }

  @Test func producerOriginalFilenameMirrorsConvertHEICRequest() {
    let producer = EditedProducer.convertHEIC(
      ConvertHEICRequest(
        assetId: "x",
        sourceResource: ResourceDescriptor(type: .photo, originalFilename: "IMG_0001.HEIC"),
        originalFilename: "IMG_0001.JPG"))
    #expect(producer.originalFilename == "IMG_0001.JPG")
  }

  @Test func producerOriginalFilenameNilForNone() {
    #expect(EditedProducer.none.originalFilename == nil)
  }

  // MARK: - Unified producer dispatch (paired-video and image variants share a seam)

  /// Helper: assert that `selectProducer` returns `.resource` with the expected
  /// `PHAssetResourceType`. Used by the paired-video tests below.
  private func expectResource(
    _ producer: EditedProducer,
    type expected: PHAssetResourceType
  ) {
    if case .resource(let resource) = producer {
      #expect(resource.type == expected)
    } else {
      Issue.record("Expected .resource(\(expected.rawValue)), got \(producer)")
    }
  }

  /// `.originalPairedVideo` picks the unedited motion file out of a Live Photo's
  /// resource set. The still-side `.photo` is intentionally ignored — that's the
  /// `.original` variant's job. Pinned through the unified `selectProducer` seam
  /// (issue #49) so the variant-based dispatch is the single source of truth.
  @Test func selectProducerOriginalPairedVideoPicksPairedVideoResource() {
    let r = resources([
      (.photo, "IMG_0001.HEIC"),
      (.pairedVideo, "IMG_0001.MOV"),
      (.fullSizePhoto, "IMG_0001_edit.JPG"),
    ])
    let producer = ResourceSelection.selectProducer(
      variant: .originalPairedVideo, from: r, descriptor: descriptor(hasAdjustments: false))
    expectResource(producer, type: .pairedVideo)
  }

  /// `.editedPairedVideo` prefers `.fullSizePairedVideo` when Photos has rendered an
  /// edited motion companion (e.g. trimmed Live Photo, stabilisation applied).
  @Test func selectProducerEditedPairedVideoPrefersFullSizePairedVideo() {
    let r = resources([
      (.pairedVideo, "IMG_0001.MOV"),
      (.fullSizePairedVideo, "IMG_0001_edit.MOV"),
    ])
    let producer = ResourceSelection.selectProducer(
      variant: .editedPairedVideo, from: r, descriptor: descriptor(hasAdjustments: true))
    expectResource(producer, type: .fullSizePairedVideo)
  }

  /// When Photos elides `.fullSizePairedVideo` (edit didn't touch motion), the
  /// edited paired-video variant falls back to `.pairedVideo` so the user still
  /// gets the motion file alongside the edited still — recovered automatically
  /// without a `.failed` record because the bytes the user expects are still
  /// available.
  @Test func selectProducerEditedPairedVideoFallsBackToPairedVideoWhenFullSizeMissing() {
    let r = resources([(.pairedVideo, "IMG_0001.MOV")])
    let producer = ResourceSelection.selectProducer(
      variant: .editedPairedVideo, from: r, descriptor: descriptor(hasAdjustments: true))
    expectResource(producer, type: .pairedVideo)
  }

  /// Empty paired-video resource set → `.none` for both paired-video variants. Caller
  /// records the recoverable failure rather than synthesizing one.
  @Test func selectProducerReturnsNoneWhenNoPairedResource() {
    let r = resources([(.photo, "IMG_0001.HEIC")])
    let original = ResourceSelection.selectProducer(
      variant: .originalPairedVideo, from: r, descriptor: descriptor(hasAdjustments: false))
    let edited = ResourceSelection.selectProducer(
      variant: .editedPairedVideo, from: r, descriptor: descriptor(hasAdjustments: true))
    #expect(original == .none)
    #expect(edited == .none)
  }

  /// Image-side variants must not be redirected to a paired-video resource even if
  /// one is present. Guards against a bug where the writer would pick a `.MOV`
  /// resource when asked for `.original`.
  @Test func selectProducerImageVariantsIgnorePairedVideoResource() {
    let r = resources([
      (.photo, "IMG_0001.HEIC"),
      (.pairedVideo, "IMG_0001.MOV"),
    ])
    let original = ResourceSelection.selectProducer(
      variant: .original, from: r, descriptor: descriptor(hasAdjustments: false))
    expectResource(original, type: .photo)
  }
}
