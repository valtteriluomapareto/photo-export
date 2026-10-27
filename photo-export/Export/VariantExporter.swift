import Foundation
import OSLog

/// Single-asset, single-variant file write path. Owns:
/// - Resource selection per variant (original or edited).
/// - Destination URL allocation (via `ExportDestinationResolver`) and `.tmp` setup.
/// - Stale-`.tmp` cleanup before write; awaited stage cleanup on every exit path.
/// - In-progress record marking + in-flight tracking handoff.
/// - Reuse-source copy path (cross-placement clone of an existing `.done` write).
/// - Byte production: static resources via `AssetResourceWriter`; rendered media via
///   `MediaRenderer` directly.
/// - Final-name planning against the staged bytes (via `FinalNamePlanner`): the atomic
///   move of `.tmp` into place + timestamp application, or adoption of an identical
///   existing file that no record names.
/// - Per-variant exported / failed record write.
///
/// The exporter invokes its renderer directly. `ExportManager` constructs it to wire
/// render activity, while UI mutations route through the narrow Host. Cancellation
/// reaches the injected `ExportQueueCoordinator` directly so it stays independent
/// of UI callbacks. See docs/reference/architecture-conventions.md.
@MainActor
final class VariantExporter {

  // MARK: - Host protocol

  /// Hooks the exporter calls back into `ExportManager` for state it does not own:
  /// MainActor-published UI state (current filename / variant / render activity), and
  /// bookkeeping-aware failure recording. Cancellation now goes directly through the
  /// injected `ExportQueueCoordinator`.
  @MainActor
  protocol Host: AnyObject {
    // UI-state mirrors. Candidate for migration to coordinator-driven publishers
    // when ExportManager's UI-state surface is itself extracted; not currently scheduled.
    func setCurrentAssetFilename(_ name: String?)
    func setCurrentJobVariant(_ variant: ExportVariant?)
    func clearRenderActivity()

    /// Reads the HEIC→JPEG toggle's current value. Read at write
    /// time so a mid-run toggle change takes effect on the next variant
    /// without an in-flight reconfigure; the queue is small enough that a
    /// flip mid-run is bounded.
    var convertHEICToJPEG: Bool { get }

    // Bookkeeping-aware failure recording (updates run-summary failure counters in
    // addition to writing the record). The exporter never bypasses this for the
    // sentinel-message path — bookkeeping is load-bearing for `ExportRunSummary`.
    func recordVariantFailed(
      assetId: String, placement: ExportPlacement, variant: ExportVariant,
      sentinelMessage: String, reason: ExportVariantReason?, category: AutoSyncFailureCategory,
      at: Date) async
  }

  // MARK: - Dependencies

  private let logger = Logger.app(.variantExporter)
  private weak var host: Host?
  /// Cancellation seam. A weak reference keeps collaborator lifetimes bounded by
  /// their shared owner, `ExportManager`.
  private weak var queueCoordinator: ExportQueueCoordinator?
  private let destinationResolver: ExportDestinationResolver
  private let recordStoreRouter: RecordStoreRouter
  private let assetResourceWriter: any AssetResourceWriter
  private let mediaRenderer: any MediaRenderer
  /// HEIC→JPEG converter used by the `EditedProducer.convertHEIC` write arm.
  private let imageConverter: any ImageConverter

  /// JPEG quality used for HEIC→JPEG synthesis. `0.85` matches the default
  /// Apple's own apps use for "high quality" JPEG export; visible quality
  /// drop vs. the HEIC source is negligible for photos while the file size
  /// shrinks meaningfully. Lives here (not on `ImageConverter` itself) so
  /// the export pipeline owns the pricing decision; the protocol's
  /// `quality:` parameter is the seam.
  private static let heicJPEGQuality: Double = 0.85
  private let fileSystem: any FileSystemService
  private let finalNamePlanner: FinalNamePlanner
  private let exportDestination: any ExportDestination
  private let destinationIOFactory: @MainActor (String?) -> any DestinationIOExecuting
  private var destinationContexts: [String?: any DestinationIOExecuting] = [:]

  private func destinationIO(for id: String?) -> any DestinationIOExecuting {
    if let context = destinationContexts[id] { return context }
    let context = destinationIOFactory(id)
    destinationContexts[id] = context
    return context
  }
  func captureDestinationContext(
    placement: ExportPlacement, generation: Int
  ) throws -> ExportDestinationContext {
    try queueCoordinator?.throwIfCancelledOrStale(generation)
    guard let root = exportDestination.selectedFolderURL else { throw CancellationError() }
    let id = recordStoreRouter.destinationId(for: placement)
    let directories = try exportDestination.captureDirectoryAccess(generation: generation)
    try queueCoordinator?.throwIfCancelledOrStale(generation)
    let context = ExportDestinationContext(
      root: root, destinationId: id, generation: generation, io: destinationIO(for: id),
      directories: directories)
    try checkOwnership(context, placement: placement)
    return context
  }

  func checkOwnership(_ context: ExportDestinationContext, placement: ExportPlacement) throws {
    try queueCoordinator?.throwIfCancelledOrStale(context.generation)
    guard exportDestination.selectedFolderURL == context.root,
      recordStoreRouter.destinationId(for: placement) == context.destinationId
    else { throw CancellationError() }
  }

  // Physical final IO outlives queue teardown. Replacement jobs await its history barrier.
  private var finalCommitTask: Task<Result<CommitOutcome, Error>, Never>?

  /// Total plan-and-commit attempts for a `.suffix` slot before the variant fails with
  /// `Export:2`.
  static let maxCommitAttempts = 3

  /// What a final commit does. The export that wrote a stage owns it and removes it when it
  /// returns, whichever case ran; the commit only ever renames it.
  private enum FinalCommit {
    /// Exclusive rename of the stage to `to`.
    case move(from: URL, to: URL)
    /// Record the existing identical file, unchanged since its bytes were compared.
    case adopt(URL, storedName: String, identity: FileItemIdentity)
    /// A verified interrupted paired slot already holds the file.
    case interrupted(URL)

    var recordedName: String {
      switch self {
      case .move(_, let url), .interrupted(let url): return url.lastPathComponent
      case .adopt(_, let storedName, _): return storedName
      }
    }
  }

  private enum CommitOutcome {
    case committed(filename: String)
    /// Another file held the name, or the file planned for adoption changed.
    case collision(Error)
  }

  func waitForFinalCommit(onWait: (() -> Void)?) async {
    while let task = finalCommitTask {
      onWait?()
      _ = await task.value
    }
  }

  init(
    host: Host,
    queueCoordinator: ExportQueueCoordinator,
    destinationResolver: ExportDestinationResolver,
    recordStoreRouter: RecordStoreRouter,
    assetResourceWriter: any AssetResourceWriter,
    mediaRenderer: any MediaRenderer,
    imageConverter: any ImageConverter,
    fileSystem: any FileSystemService,
    exportDestination: any ExportDestination,
    finalNamePlanner: FinalNamePlanner? = nil,
    destinationIOFactory: @escaping @MainActor (String?) -> any DestinationIOExecuting = { _ in
      DestinationIO()
    }
  ) {
    self.host = host
    self.queueCoordinator = queueCoordinator
    self.destinationResolver = destinationResolver
    self.recordStoreRouter = recordStoreRouter
    self.assetResourceWriter = assetResourceWriter
    self.mediaRenderer = mediaRenderer
    self.imageConverter = imageConverter
    self.fileSystem = fileSystem
    self.finalNamePlanner = finalNamePlanner ?? FinalNamePlanner(fileSystem: fileSystem)
    self.exportDestination = exportDestination
    self.destinationIOFactory = destinationIOFactory
  }

  // MARK: - Public API

  /// Writes a single variant for an asset. Returns the chosen group stem when the
  /// variant's filename was materialised (so later variants can pair against it). Returns
  /// `nil` on recoverable "no resource" failures that are recorded in-store but do not
  /// change the pairing stem.
  ///
  /// `groupStem` is either inherited from a prior done variant record for this asset or,
  /// within the same job, pre-allocated when both variants will be written together.
  ///
  /// `mayAdoptExisting` is false for an image whose paired video is written next at its
  /// stem: adopting the image could leave the video's name taken and split the pair.
  func exportSingleVariant(
    variant: ExportVariant,
    descriptor: AssetDescriptor,
    resources: [ResourceDescriptor],
    destDir: URL,
    relPath: String,
    job: ExportManager.ExportJob,
    groupStem: String?,
    pairOriginalWithSuffix: Bool,
    generation gen: Int,
    inFlight: inout (assetId: String, variant: ExportVariant)?,
    subfolder: String? = nil,
    acceptsEditedFallback: Bool = false,
    mayAdoptExisting: Bool = true,
    context capturedContext: ExportDestinationContext? = nil
  ) async throws -> String? {
    try queueCoordinator?.throwIfCancelledOrStale(gen)
    let measurement = queueCoordinator?.measurementJob
    let context =
      try capturedContext
      ?? captureDestinationContext(
        placement: job.placement, generation: gen)
    try checkOwnership(context, placement: job.placement)
    let destinationIO = context.io
    // Renderer activity must always be cleared on the way out of this function —
    // including on throw — so a render failure or cancel does not leave the toolbar
    // showing `(rendering…)` forever.
    defer {
      if queueCoordinator?.isCurrent(gen) == true { host?.clearRenderActivity() }
    }

    // Single point of byte-source dispatch: `ResourceSelection.selectProducer` returns
    // the same `EditedProducer` enum for every variant, keeping byte production
    // enum-shaped rather than branching by variant here. `convertHEICToJPEG` is
    // forwarded so the `.edited` case can synthesize a JPEG from a HEIC source.
    let producer = ResourceSelection.selectProducer(
      variant: variant, from: resources, descriptor: descriptor,
      convertHEICToJPEG: host?.convertHEICToJPEG ?? false)

    guard let originalFilename = producer.originalFilename else {
      let errMsg: String
      let reason: ExportVariantReason?
      switch variant {
      case .original:
        errMsg = "No exportable resource"
        reason = nil
      case .originalPairedVideo, .editedPairedVideo:
        // Live Photo subtype said the asset has paired video, but PhotoKit's
        // resource enumeration didn't include one. A known iCloud data-
        // availability state — distinguish from a generic resource-missing
        // failure so the completion policy can treat the asset as covered
        // (still side is on disk; Photos has nothing more to give).
        errMsg = ExportVariantRecovery.pairedVideoUnavailableMessage
        reason = .pairedVideoUnavailable
      case .edited:
        errMsg = ExportVariantRecovery.editedResourceUnavailableMessage
        reason = .editedResourceUnavailable
      }
      await host?.recordVariantFailed(
        assetId: descriptor.id, placement: job.placement, variant: variant,
        sentinelMessage: errMsg, reason: reason, category: .resourceMissing, at: Date())
      logger.error(
        "No \(variant.rawValue, privacy: .public) byte source for id: \(descriptor.id, privacy: .public)"
      )
      return nil
    }

    let interruptedFilename = try await verifiedInterruptedFilename(
      variant: variant, descriptor: descriptor, producer: producer, destDir: destDir,
      relPath: relPath, job: job, groupStem: groupStem, subfolder: subfolder, generation: gen,
      destinationIO: destinationIO)
    try checkOwnership(context, placement: job.placement)

    let prepared = try await prepareVariant(
      variant: variant, descriptor: descriptor, originalFilename: originalFilename,
      resources: resources, destDir: destDir, groupStem: groupStem,
      pairOriginalWithSuffix: pairOriginalWithSuffix, interruptedFilename: interruptedFilename,
      job: job, subfolder: subfolder, context: context)
    try checkOwnership(context, placement: job.placement)
    let slot = prepared.slot
    let finalURL = prepared.url

    if prepared.isInterrupted {
      switch try await commitFile(
        .interrupted(finalURL), slot: slot, descriptor: descriptor, job: job,
        variant: variant, relPath: relPath, subfolder: subfolder,
        acceptsEditedFallback: acceptsEditedFallback, context: context)
      {
      case .committed:
        measurement?.committed()
        return slot.chosenStem(forFilename: finalURL.lastPathComponent)
      case .collision(let error):
        throw error
      }
    }

    let reuseSource: (url: URL, relativePath: String)?
    if let reuse = recordStoreRouter.findReuseSource(
      assetId: descriptor.id, variant: variant, currentPlacement: job.placement),
      case let destinationRoot = context.root
    {
      let sourceRelPath = ExportMediaPathPolicy.relativePath(
        placement: reuse.placement, subfolder: reuse.subfolder)
      reuseSource = (
        destinationRoot.appendingPathComponent(sourceRelPath, isDirectory: true)
          .appendingPathComponent(reuse.filename), sourceRelPath
      )
    } else {
      reuseSource = nil
    }

    let legacyTempURL = finalURL.appendingPathExtension("tmp")
    // The legacy sweep also finishes within the caller's scoped access. It probes the
    // network volume on utility, leaving the main thread's bounded path checks alone.
    await destinationIO.run { [fileSystem] in
      if fileSystem.fileExists(atPath: legacyTempURL.path) {
        try? fileSystem.removeItem(at: legacyTempURL)
      }
    }
    try checkOwnership(context, placement: job.placement)
    // Any producer can finish after cancellation. Its stage belongs to this attempt,
    // including fallback and HEIC materialization, never a same-path replacement.
    let tempURL = destDir.appendingPathComponent(".photo-export-\(UUID().uuidString).tmp")
    @MainActor func writeAndCommit() async throws -> String? {
      try checkOwnership(context, placement: job.placement)
      host?.setCurrentAssetFilename(finalURL.lastPathComponent)
      try checkOwnership(context, placement: job.placement)
      host?.setCurrentJobVariant(variant)
      try checkOwnership(context, placement: job.placement)
      inFlight = (assetId: descriptor.id, variant: variant)
      try await recordStoreRouter.withMutationAdmission(placement: job.placement) {
        try checkOwnership(context, placement: job.placement)
        try requireUnclaimed(
          finalURL.lastPathComponent, slot: slot, job: job,
          subfolder: subfolder, variant: variant, descriptor: descriptor)
        recordStoreRouter.markVariantInProgress(
          assetId: descriptor.id, placement: job.placement, variant: variant,
          relPath: relPath, filename: finalURL.lastPathComponent, subfolder: subfolder)
      }
      try checkOwnership(context, placement: job.placement)

      // Reuse-source copy path: if `(asset, variant)` is already exported under another
      // placement, copy the existing file rather than re-fetching from PhotoKit. On APFS
      // the copy is a CoW clone (no extra disk usage); on non-APFS it's a real copy.
      // PhotoKit fallback only on source-side errors (the prior `.done` record is stale);
      // destination-side errors fail the variant directly because retrying via PhotoKit
      // would hit the same destination problem. The copy works regardless of whether the
      // byte source is a static resource or a rendered edit — once a placement has the
      // file, all other placements just clone it.
      var didCopyFromReuseSource = false
      if let reuseSource {
        // the source file lives at the placement path plus the *source
        // variant's* persisted `subfolder` — NOT recomputed from the current
        // `videoLayout` setting. A mid-life-toggle source could have been written
        // under `.flat` (subfolder == nil) and now we're under `.subfolder`, or vice
        // versa; reading the stored value pins the source to where the writer
        // originally put it.
        let sourceRelPath = reuseSource.relativePath
        let sourceURL = reuseSource.url
        do {
          // Wait for physical IO even on cancellation. The surrounding export owns
          // security-scoped access until this continuation finishes.
          try await measureExportStage(measurement) {
            try await destinationIO.run { [fileSystem] in
              try fileSystem.copyItem(from: sourceURL, to: tempURL)
            }
          }
          try checkOwnership(context, placement: job.placement)
          didCopyFromReuseSource = true
          logger.debug(
            "Reused \(sourceURL.lastPathComponent, privacy: .public) from \(sourceRelPath, privacy: .public) for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public)"
          )
        } catch {
          try checkOwnership(context, placement: job.placement)
          if Self.isSourceSideCopyError(error) {
            if Self.isMissingDirectoryError(error) {
              try await destinationIO.run { try context.directories.revalidateDirectory(relPath) }
              try checkOwnership(context, placement: job.placement)
            }
            try await destinationIO.run { [fileSystem] in
              if fileSystem.fileExists(atPath: tempURL.path) {
                try fileSystem.removeItem(at: tempURL)
              }
            }
            try checkOwnership(context, placement: job.placement)
            // Source missing/unreadable: prior `.done` record is stale. Fall through to
            // PhotoKit re-export. We do NOT mutate the stale record — that placement's
            // corruption surfaces on its next export run.
            logger.warning(
              "Reuse-source missing for id: \(descriptor.id, privacy: .public) (\(error.localizedDescription, privacy: .public)); falling back to PhotoKit"
            )
          } else {
            // Destination-side error: out of space, permission denied, etc. Don't retry
            // via PhotoKit — it would hit the same destination problem. Throw so the
            // caller marks the variant `.failed`.
            throw error
          }
        }
      }
      if !didCopyFromReuseSource {
        do {
          switch producer {
          case .resource(let resource):
            try await withDirectoryRetry(relPath, context: context, placement: job.placement) {
              try await measureExportStage(measurement) {
                try await self.assetResourceWriter.writeResource(
                  resource, forAssetId: descriptor.id, to: tempURL)
              }
            }
          case .render(let request):
            // Preserve cancellation and hard destination failures; translate ordinary
            // renderer errors into the canonical recoverable failure, stable across both
            // "no static resource" and "render attempted and failed" cases. The original
            // error survives in the log for diagnostics.
            do {
              try await withDirectoryRetry(relPath, context: context, placement: job.placement) {
                try await measureExportStage(measurement) {
                  try await self.mediaRenderer.render(request: request, to: tempURL)
                }
              }
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              try checkOwnership(context, placement: job.placement)
              if AutoSyncFailureCategory.classify(error).category.stopsCurrentExportRun {
                throw error
              }
              logger.error(
                "Render failed for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public) error: \(String(describing: error), privacy: .public)"
              )
              throw EditedResourceUnavailableError()
            }
          case .convertHEIC(let request):
            // The intermediate belongs to this attempt and is removed before scope release.
            let heicTempURL = tempURL.appendingPathExtension("heic-source")
            let converted: Result<Void, Error>
            do {
              try await withDirectoryRetry(relPath, context: context, placement: job.placement) {
                try await measureExportStage(measurement) {
                  try await self.assetResourceWriter.writeResource(
                    request.sourceResource, forAssetId: descriptor.id, to: heicTempURL)
                }
              }
              try checkOwnership(context, placement: job.placement)
              try await measureExportStage(measurement) {
                try await self.imageConverter.convertHEIC(
                  at: heicTempURL, to: tempURL, quality: Self.heicJPEGQuality)
              }
              converted = .success(())
            } catch {
              converted = .failure(error)
            }
            await destinationIO.run { [fileSystem] in
              if fileSystem.fileExists(atPath: heicTempURL.path) {
                try? fileSystem.removeItem(at: heicTempURL)
              }
            }
            try checkOwnership(context, placement: job.placement)
            do { try converted.get() } catch is CancellationError {
              throw CancellationError()
            } catch {
              try checkOwnership(context, placement: job.placement)
              if AutoSyncFailureCategory.classify(error).category.stopsCurrentExportRun {
                throw error
              }
              logger.error(
                "HEIC→JPEG conversion failed for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public) error: \(String(describing: error), privacy: .public)"
              )
              throw EditedResourceUnavailableError()
            }
          case .none:
            // Guarded above by `producer.originalFilename` check.
            preconditionFailure("EditedProducer.none reached the write step")
          }
        } catch {
          // A physical producer can fail after teardown, even after B committed.
          // Convert that stale error to cancellation before any caller records it.
          try checkOwnership(context, placement: job.placement)
          throw error
        }
      }
      // Load-bearing: this checkpoint must run BEFORE the atomic move below so that a
      // cancel arriving during the render does not leak a partially-written file into the
      // destination. Owned-stage cleanup follows this operation on every exit, but it
      // can prevent a partial final file only when cancellation is checked before the move.
      try checkOwnership(context, placement: job.placement)

      let committedName = try await commitStaged(
        tempURL, slot: slot, markedName: finalURL.lastPathComponent, descriptor: descriptor,
        job: job, variant: variant, relPath: relPath, subfolder: subfolder,
        acceptsEditedFallback: acceptsEditedFallback, mayAdoptExisting: mayAdoptExisting,
        context: context)
      inFlight = nil
      measurement?.committed()
      logger.info(
        "Exported \(committedName, privacy: .public) variant: \(variant.rawValue, privacy: .public) -> \(destDir.path, privacy: .public) asset: \(descriptor.id, privacy: .public)"
      )
      return slot.chosenStem(forFilename: committedName)
    }
    let result: Result<String?, Error>
    do {
      result = .success(try await writeAndCommit())
    } catch {
      result = .failure(error)
    }
    // Physical cleanup finishes while the caller still owns destination access, even
    // when cancellation or an obsolete generation ended the producer.
    await destinationIO.run { [fileSystem] in
      if fileSystem.fileExists(atPath: tempURL.path) {
        try? fileSystem.removeItem(at: tempURL)
      }
    }
    try checkOwnership(context, placement: job.placement)
    return try result.get()
  }

  func allocatePairedGroupStem(
    baseStem: String, imageExt: String, editedExt: String?, destDir: URL,
    pairOriginalWithSuffix: Bool, pairedVideoExt: String?, job: ExportManager.ExportJob,
    subfolder: String?, assetId: String, context: ExportDestinationContext
  ) async throws -> String {
    let claims = recordStoreRouter.filenameClaimSnapshot(
      placement: job.placement, subfolder: subfolder, of: assetId)
    let resolver = destinationResolver
    let stem = await context.io.run {
      resolver.allocatePairedGroupStem(
        baseStem: baseStem, imageExt: imageExt, editedExt: editedExt, destDir: destDir,
        pairOriginalWithSuffix: pairOriginalWithSuffix, pairedVideoExt: pairedVideoExt,
        isClaimed: claims.isClaimed)
    }
    try checkOwnership(context, placement: job.placement)
    return stem
  }

  func allocateUnusedOrigStem(
    baseStem: String, originalExt: String, destDir: URL, job: ExportManager.ExportJob,
    subfolder: String?, assetId: String, context: ExportDestinationContext
  ) async throws -> String {
    let claims = recordStoreRouter.filenameClaimSnapshot(
      placement: job.placement, subfolder: subfolder, of: assetId)
    let resolver = destinationResolver
    let stem = await context.io.run {
      resolver.allocateUnusedOrigStem(
        baseStem: baseStem, originalExt: originalExt,
        destDir: destDir, isClaimed: claims.isClaimed)
    }
    try checkOwnership(context, placement: job.placement)
    return stem
  }

  private struct PreparedVariant: Sendable {
    let slot: ExportDestinationResolver.Slot
    let url: URL
    let isInterrupted: Bool
  }

  private func prepareVariant(
    variant: ExportVariant, descriptor: AssetDescriptor, originalFilename: String,
    resources: [ResourceDescriptor], destDir: URL, groupStem: String?,
    pairOriginalWithSuffix: Bool, interruptedFilename: String?, job: ExportManager.ExportJob,
    subfolder: String?, context: ExportDestinationContext
  ) async throws -> PreparedVariant {
    let claims = recordStoreRouter.filenameClaimSnapshot(
      placement: job.placement, subfolder: subfolder, exceptVariant: variant, of: descriptor.id)
    let resolver = destinationResolver
    let files = fileSystem
    return try await context.io.run {
      let slot = try resolver.resolveSlot(
        variant: variant, descriptor: descriptor, originalFilename: originalFilename,
        resources: resources, destDir: destDir, groupStem: groupStem,
        pairOriginalWithSuffix: pairOriginalWithSuffix, interruptedFilename: interruptedFilename,
        isClaimed: claims.isClaimed)
      let url = resolver.firstFreeURL(in: slot, isClaimed: claims.isClaimed)
      return PreparedVariant(
        slot: slot, url: url,
        isInterrupted: url.lastPathComponent == interruptedFilename
          && files.fileExists(atPath: url.path))
    }
  }

  private func requireUnclaimed(
    _ name: String, slot: ExportDestinationResolver.Slot, job: ExportManager.ExportJob,
    subfolder: String?, variant: ExportVariant, descriptor: AssetDescriptor
  ) throws {
    guard isClaimed(name, job: job, subfolder: subfolder, variant: variant, of: descriptor) else {
      return
    }
    if case .refuse = slot.policy {
      throw NSError(
        domain: "Export", code: ExportErrorCode.pairedOriginalFilenameConflict.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Paired original filename is recorded for another exported file: \(name). "
            + "If you deleted that file, run File > Import Existing Backup."
        ])
    }
    throw FileIOService.destinationExistsError()
  }

  // MARK: - Helpers

  private func withDirectoryRetry(
    _ relativePath: String, context: ExportDestinationContext, placement: ExportPlacement,
    operation: @MainActor () async throws -> Void
  ) async throws {
    do {
      try await operation()
      try checkOwnership(context, placement: placement)
    } catch {
      try checkOwnership(context, placement: placement)
      guard Self.isMissingDirectoryError(error) else { throw error }
      try await context.io.run { try context.directories.revalidateDirectory(relativePath) }
      try checkOwnership(context, placement: placement)
      try await operation()
      try checkOwnership(context, placement: placement)
    }
  }

  private static func isMissingDirectoryError(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) || error.code == Int(ENOTDIR) {
      return true
    }
    if error.domain == NSCocoaErrorDomain,
      error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
    {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
      return isMissingDirectoryError(underlying)
    }
    return false
  }

  /// Plans the final name for the staged file and commits it. When another file takes the
  /// planned name first, or a file planned for adoption changes, a `.suffix` slot plans
  /// again from the start; a `.refuse` slot fails as a collision. Each plan that picks a
  /// different name re-marks the variant in progress under it.
  private func commitStaged(
    _ stagedURL: URL, slot: ExportDestinationResolver.Slot, markedName: String,
    descriptor: AssetDescriptor, job: ExportManager.ExportJob, variant: ExportVariant,
    relPath: String, subfolder: String?, acceptsEditedFallback: Bool, mayAdoptExisting: Bool,
    context: ExportDestinationContext
  ) async throws -> String {
    let gen = context.generation
    let destinationIO = context.io
    var markedName = markedName
    var collision: Error = FileIOService.destinationExistsError()
    for attempt in 1...Self.maxCommitAttempts {
      let commit = try await planCommit(
        stagedURL, slot: slot, descriptor: descriptor, job: job, variant: variant,
        subfolder: subfolder, mayAdopt: mayAdoptExisting, generation: gen,
        destinationIO: destinationIO)
      try checkOwnership(context, placement: job.placement)
      if commit.recordedName != markedName {
        host?.setCurrentAssetFilename(commit.recordedName)
        try checkOwnership(context, placement: job.placement)
      }
      let accepted = try await recordStoreRouter.withMutationAdmission(placement: job.placement) {
        try checkOwnership(context, placement: job.placement)
        if isClaimed(
          commit.recordedName, job: job, subfolder: subfolder,
          variant: variant, of: descriptor)
        {
          guard case .suffix = slot.policy else { throw FileIOService.destinationExistsError() }
          return false
        }
        if commit.recordedName != markedName {
          markedName = commit.recordedName
          recordStoreRouter.markVariantInProgress(
            assetId: descriptor.id, placement: job.placement, variant: variant,
            relPath: relPath, filename: markedName, subfolder: subfolder)
          try checkOwnership(context, placement: job.placement)
        }
        return true
      }
      guard accepted else {
        collision = FileIOService.destinationExistsError()
        continue
      }
      switch try await commitFile(
        commit, slot: slot, descriptor: descriptor, job: job, variant: variant,
        relPath: relPath, subfolder: subfolder, acceptsEditedFallback: acceptsEditedFallback,
        context: context)
      {
      case .committed(let filename):
        if case .adopt = commit {
          logger.info(
            "Adopted existing identical \(filename, privacy: .public) for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public)"
          )
        }
        return filename
      case .collision(let error):
        guard case .suffix = slot.policy else { throw error }
        collision = error
        logger.notice(
          "\(commit.recordedName, privacy: .public) was taken before its commit (attempt \(attempt, privacy: .public)) for id: \(descriptor.id, privacy: .public)"
        )
      }
    }
    throw collision
  }

  /// Whether a record other than this variant's own names `name` in its folder.
  private func isClaimed(
    _ name: String, job: ExportManager.ExportJob, subfolder: String?, variant: ExportVariant,
    of descriptor: AssetDescriptor
  ) -> Bool {
    recordStoreRouter.isFilenameClaimed(
      name, placement: job.placement, subfolder: subfolder, exceptVariant: variant,
      of: descriptor.id)
  }

  /// Walks the slot off the main actor. Physical reads finish before this returns, even
  /// after cancellation, because the surrounding export holds scoped access until then.
  private func planCommit(
    _ stagedURL: URL, slot: ExportDestinationResolver.Slot, descriptor: AssetDescriptor,
    job: ExportManager.ExportJob, variant: ExportVariant, subfolder: String?, mayAdopt: Bool,
    generation gen: Int, destinationIO: any DestinationIOExecuting
  ) async throws -> FinalCommit {
    // A `.refuse` slot has one name, so there is nothing to plan off the main actor.
    guard case .suffix = slot.policy else { return .move(from: stagedURL, to: slot.naturalURL) }
    let planner = finalNamePlanner
    let router = recordStoreRouter
    let coordinator = queueCoordinator
    let placement = job.placement
    let assetId = descriptor.id
    let result: Result<FinalNamePlanner.Plan, Error> = await runDetached(priority: .utility) {
      do {
        return .success(
          try await planner.plan(
            slot: slot, stagedURL: stagedURL, mayAdopt: mayAdopt, destinationIO: destinationIO,
            isClaimed: { name in
              await router.isFilenameClaimed(
                name, placement: placement, subfolder: subfolder, exceptVariant: variant,
                of: assetId)
            },
            shouldStop: { await coordinator?.isCurrent(gen) != true }))
      } catch {
        return .failure(error)
      }
    }
    try queueCoordinator?.throwIfCancelledOrStale(gen)
    switch try result.get() {
    case .move(let url):
      return .move(from: stagedURL, to: url)
    case .adopt(let url, let storedName, let identity):
      return .adopt(url, storedName: storedName, identity: identity)
    }
  }

  /// An interrupted paired slot is acknowledged through the same bounded commit and
  /// captured-destination barrier as a newly moved file. An adopted file is acknowledged
  /// once `lstat` shows it unchanged since its bytes were compared; it gets no timestamps.
  private func commitFile(
    _ commit: FinalCommit, slot: ExportDestinationResolver.Slot, descriptor: AssetDescriptor,
    job: ExportManager.ExportJob, variant: ExportVariant, relPath: String, subfolder: String?,
    acceptsEditedFallback: Bool, context: ExportDestinationContext
  ) async throws -> CommitOutcome {
    let destinationIO = context.io
    let task: Task<Result<CommitOutcome, Error>, Never>
    do {
      task = try await recordStoreRouter.withMutationAdmission(placement: job.placement) {
        try checkOwnership(context, placement: job.placement)
        if case .interrupted = commit {
          try requireUnclaimed(
            commit.recordedName, slot: slot, job: job, subfolder: subfolder,
            variant: variant, descriptor: descriptor)
        } else if isClaimed(
          commit.recordedName, job: job, subfolder: subfolder, variant: variant, of: descriptor)
        {
          throw FileIOService.destinationExistsError()
        }
        let acknowledge = try recordStoreRouter.captureFinalCommit(
          assetId: descriptor.id, placement: job.placement, variant: variant,
          relPath: relPath, subfolder: subfolder, acceptsEditedFallback: acceptsEditedFallback)
        let task = Task { [fileSystem] () -> Result<CommitOutcome, Error> in
          defer { finalCommitTask = nil }
          do {
            switch commit {
            case .move(let stage, let url):
              try await destinationIO.run {
                try fileSystem.moveItemAtomically(from: stage, to: url)
              }
            case .adopt(let url, _, let identity):
              // A lookup error counts as a change: the variant plans again, and the planning
              // walk's own lookup then reports the real error.
              let current: FileItemIdentity? = await destinationIO.run {
                try? fileSystem.itemIdentity(at: url)
              }
              guard current == identity else { throw FileIOService.destinationExistsError() }
            case .interrupted:
              break
            }
          } catch let error where FileIOService.isDestinationExists(error) {
            await acknowledge(nil)
            return .success(.collision(error))
          } catch {
            await acknowledge(nil)
            return .failure(error)
          }
          // The file is now committed. Finish this bounded acknowledgement even when
          // its run was cancelled or its store switched destinations during physical IO.
          switch commit {
          case .move(_, let url), .interrupted(let url):
            if let createdAt = descriptor.creationDate {
              await destinationIO.run {
                fileSystem.applyTimestamps(creationDate: createdAt, to: url)
              }
            }
          case .adopt:
            break
          }
          await acknowledge(commit.recordedName)
          return .success(.committed(filename: commit.recordedName))
        }
        finalCommitTask = task
        return task
      }
    } catch let error where FileIOService.isDestinationExists(error) {
      return .collision(error)
    }
    let result = await task.value
    // Stale errors and successes cannot reach replacement bookkeeping or UI.
    try checkOwnership(context, placement: job.placement)
    return try result.get()
  }

  private func verifiedInterruptedFilename(
    variant: ExportVariant, descriptor: AssetDescriptor, producer: EditedProducer,
    destDir: URL, relPath: String, job: ExportManager.ExportJob, groupStem: String?,
    subfolder: String?, generation gen: Int, destinationIO: any DestinationIOExecuting
  ) async throws -> String? {
    guard groupStem != nil, variant == .original || variant == .originalPairedVideo,
      case .resource(let resource) = producer,
      let filename = recordStoreRouter.interruptedFilename(
        forAssetId: descriptor.id, placement: job.placement, variant: variant,
        relPath: relPath, subfolder: subfolder)
    else { return nil }
    let destination = exportDestination.selectedFolderURL
    let url = destDir.appendingPathComponent(filename)
    // Await physical inspection even if the run becomes stale, retaining scoped access.
    let size: Int64? = await destinationIO.run { [fileSystem] in
      try? fileSystem.regularFileSize(at: url)
    }
    try queueCoordinator?.throwIfCancelledOrStale(gen)
    guard exportDestination.selectedFolderURL == destination,
      recordStoreRouter.interruptedFilename(
        forAssetId: descriptor.id, placement: job.placement, variant: variant,
        relPath: relPath, subfolder: subfolder) == filename
    else { throw CancellationError() }
    guard let size, size > 0 else { return nil }
    if let expected = resource.fileSize, expected > 0, expected != size { return nil }
    return filename
  }

  /// Distinguishes source-side errors (file missing/unreadable — fall back to PhotoKit)
  /// from destination-side errors (out of space, target permission, target volume removed
  /// — fail the variant directly because a PhotoKit retry would hit the same destination
  /// problem and waste cycles).
  ///
  /// `NSFileReadNoPermissionError` belongs in the source-side bucket: the prior `.done`
  /// file's permissions were changed in Finder (or the volume was remounted read-only),
  /// so reading it fails — but we can still re-fetch from PhotoKit and write a fresh copy
  /// at the destination, which the user owns.
  private static func isSourceSideCopyError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case NSFileReadNoSuchFileError, NSFileNoSuchFileError, NSFileReadUnknownError,
        NSFileReadCorruptFileError, NSFileReadNoPermissionError:
        return true
      default:
        return false
      }
    }
    if nsError.domain == NSPOSIXErrorDomain {
      switch nsError.code {
      case Int(ENOENT), Int(EACCES):
        return true
      default:
        return false
      }
    }
    return false
  }
}
