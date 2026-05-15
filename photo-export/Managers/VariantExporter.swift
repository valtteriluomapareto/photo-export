import Foundation
import OSLog

/// Single-asset, single-variant file write path. Owns:
/// - Resource selection per variant (original or edited).
/// - Destination URL allocation (via `ExportDestinationResolver`) and `.tmp` setup.
/// - Stale-`.tmp` cleanup before write; `defer`-based cleanup on every exit path.
/// - In-progress record marking + in-flight tracking handoff.
/// - Reuse-source copy path (cross-placement clone of an existing `.done` write).
/// - Byte production: static resources via `AssetResourceWriter`; rendered media via
///   the `host` in Phase 3a (moves onto the exporter in Phase 3b).
/// - Atomic move of `.tmp` into place + timestamp application.
/// - Per-variant exported / failed record write.
///
/// Per `docs/project/plans/software-architecture-improvement-plan.md` Phase 3a, the
/// rendered-media path is invoked through the `host` so `ExportManager` retains its
/// renderer wiring. Phase 3b moves the rendered-media call onto the exporter and
/// deletes `Host.renderToTempURL`. The cancellation seam (`isCurrent` /
/// `throwIfCancelledOrStale`) and the UI-state mutations are routed through the host
/// per the Cross-Cutting Contracts — those callbacks migrate to
/// `ExportQueueCoordinator` in Phase 4b/5.
@MainActor
final class VariantExporter {

  // MARK: - Host protocol

  /// Hooks the exporter calls back into `ExportManager` for state it does not own:
  /// generation-aware cancellation checks, MainActor-published UI state (current
  /// filename / variant / render activity), bookkeeping-aware failure recording, and
  /// (Phase 3a only) the rendered-media bridge.
  @MainActor
  protocol Host: AnyObject {
    // Cancellation seam — Phase 0 contract. Moves to `ExportQueueCoordinator` in Phase 5
    // when generation ownership transfers; deleted from this protocol then.
    func isCurrent(_ gen: Int) -> Bool
    func throwIfCancelledOrStale(_ gen: Int) throws

    // UI-state mirrors. Moved to coordinator-driven publishers in a later phase.
    func setCurrentAssetFilename(_ name: String?)
    func setCurrentJobVariant(_ variant: ExportVariant?)
    func clearRenderActivity()

    // Bookkeeping-aware failure recording (updates run-summary failure counters in
    // addition to writing the record). The exporter never bypasses this for the
    // sentinel-message path — bookkeeping is load-bearing for `ExportRunSummary`.
    func recordVariantFailed(
      assetId: String, placement: ExportPlacement, variant: ExportVariant,
      sentinelMessage: String, category: AutoSyncFailureCategory, at: Date)

    // Phase 3a rendered-media bridge. Deleted in Phase 3b.
    func renderToTempURL(request: MediaRenderRequest, tempURL: URL) async throws
  }

  // MARK: - Dependencies

  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "VariantExporter")
  private weak var host: Host?
  private let destinationResolver: ExportDestinationResolver
  private let recordStoreRouter: RecordStoreRouter
  private let assetResourceWriter: any AssetResourceWriter
  private let fileSystem: any FileSystemService
  private let exportDestination: any ExportDestination

  init(
    host: Host,
    destinationResolver: ExportDestinationResolver,
    recordStoreRouter: RecordStoreRouter,
    assetResourceWriter: any AssetResourceWriter,
    fileSystem: any FileSystemService,
    exportDestination: any ExportDestination
  ) {
    self.host = host
    self.destinationResolver = destinationResolver
    self.recordStoreRouter = recordStoreRouter
    self.assetResourceWriter = assetResourceWriter
    self.fileSystem = fileSystem
    self.exportDestination = exportDestination
  }

  // MARK: - Public API

  /// Writes a single variant for an asset. Returns the chosen group stem when the
  /// variant's filename was materialised (so later variants can pair against it). Returns
  /// `nil` on recoverable "no resource" failures that are recorded in-store but do not
  /// change the pairing stem.
  ///
  /// `groupStem` is either inherited from a prior done variant record for this asset or,
  /// within the same job, pre-allocated when both variants will be written together.
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
    inFlight: inout (assetId: String, variant: ExportVariant)?
  ) async throws -> String? {
    // Renderer activity must always be cleared on the way out of this function —
    // including on throw — so a render failure or cancel does not leave the toolbar
    // showing `(rendering…)` forever.
    defer { host?.clearRenderActivity() }

    let producer: EditedProducer = {
      switch variant {
      case .original:
        if let resource = ResourceSelection.selectOriginalResource(
          from: resources, mediaType: descriptor.mediaType)
        {
          return .resource(resource)
        }
        return .none
      case .edited:
        return ResourceSelection.selectEditedProducer(
          from: resources, mediaType: descriptor.mediaType, descriptor: descriptor)
      }
    }()

    guard let originalFilename = producer.originalFilename else {
      let errMsg: String
      switch variant {
      case .original: errMsg = "No exportable resource"
      case .edited: errMsg = ExportVariantRecovery.editedResourceUnavailableMessage
      }
      host?.recordVariantFailed(
        assetId: descriptor.id, placement: job.placement, variant: variant,
        sentinelMessage: errMsg, category: .resourceMissing, at: Date())
      logger.error(
        "No \(variant.rawValue, privacy: .public) byte source for id: \(descriptor.id, privacy: .public)"
      )
      return nil
    }

    let (finalURL, chosenStem) = try destinationResolver.resolveDestination(
      variant: variant,
      descriptor: descriptor,
      originalFilename: originalFilename,
      resources: resources,
      destDir: destDir,
      groupStem: groupStem,
      pairOriginalWithSuffix: pairOriginalWithSuffix
    )

    let tempURL = finalURL.appendingPathExtension("tmp")

    // Clean up any stale .tmp sibling for this target filename. Covers crash leftovers
    // that a prior defer could not clean up.
    if fileSystem.fileExists(atPath: tempURL.path) {
      try? fileSystem.removeItem(at: tempURL)
    }
    defer {
      if fileSystem.fileExists(atPath: tempURL.path) {
        try? fileSystem.removeItem(at: tempURL)
      }
    }

    try host?.throwIfCancelledOrStale(gen)
    host?.setCurrentAssetFilename(finalURL.lastPathComponent)
    host?.setCurrentJobVariant(variant)
    inFlight = (assetId: descriptor.id, variant: variant)
    recordStoreRouter.markVariantInProgress(
      assetId: descriptor.id, placement: job.placement, variant: variant,
      relPath: relPath, filename: finalURL.lastPathComponent)

    // Reuse-source copy path: if `(asset, variant)` is already exported under another
    // placement, copy the existing file rather than re-fetching from PhotoKit. On APFS
    // the copy is a CoW clone (no extra disk usage); on non-APFS it's a real copy.
    // PhotoKit fallback only on source-side errors (the prior `.done` record is stale);
    // destination-side errors fail the variant directly because retrying via PhotoKit
    // would hit the same destination problem. The copy works regardless of whether the
    // byte source is a static resource or a rendered edit — once a placement has the
    // file, all other placements just clone it.
    var didCopyFromReuseSource = false
    if let reuse = recordStoreRouter.findReuseSource(
      assetId: descriptor.id, variant: variant, currentPlacement: job.placement),
      let destinationRoot = exportDestination.selectedFolderURL
    {
      let sourceURL =
        destinationRoot
        .appendingPathComponent(reuse.placement.relativePath, isDirectory: true)
        .appendingPathComponent(reuse.filename)
      do {
        try fileSystem.copyItem(from: sourceURL, to: tempURL)
        didCopyFromReuseSource = true
        logger.debug(
          "Reused \(sourceURL.lastPathComponent, privacy: .public) from \(reuse.placement.relativePath, privacy: .public) for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public)"
        )
      } catch {
        if Self.isSourceSideCopyError(error) {
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
      switch producer {
      case .resource(let resource):
        try await assetResourceWriter.writeResource(
          resource, forAssetId: descriptor.id, to: tempURL)
      case .render(let request):
        // Translate any renderer error (other than cancellation) into the canonical
        // recoverable failure so the persisted `lastError` is stable across both
        // "no static resource" and "render attempted and failed" cases. The original
        // error survives in the log for diagnostics.
        do {
          // Phase 3a routes through the host so ExportManager retains its renderer
          // wiring. Phase 3b deletes this hop and calls `mediaRenderer.render` directly.
          guard let host else { throw CancellationError() }
          try await host.renderToTempURL(request: request, tempURL: tempURL)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logger.error(
            "Render failed for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public) error: \(String(describing: error), privacy: .public)"
          )
          throw NSError(
            domain: "Export", code: 9,
            userInfo: [
              NSLocalizedDescriptionKey:
                ExportVariantRecovery.editedResourceUnavailableMessage
            ])
        }
      case .none:
        // Guarded above by `producer.originalFilename` check.
        preconditionFailure("EditedProducer.none reached the write step")
      }
    }
    // Load-bearing: this checkpoint must run BEFORE the atomic move below so that a
    // cancel arriving during the render does not leak a partially-written file into the
    // destination. Reordering this is a correctness regression — temp cleanup is handled
    // by `defer`, but only if we throw before the move.
    try host?.throwIfCancelledOrStale(gen)

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .utility).async { [fileSystem] in
        do {
          self.logger.debug(
            "Move begin: \(tempURL.lastPathComponent, privacy: .public) -> \(finalURL.lastPathComponent, privacy: .public)"
          )
          try fileSystem.moveItemAtomically(from: tempURL, to: finalURL)
          self.logger.debug(
            "Move done -> \(finalURL.lastPathComponent, privacy: .public)")
          continuation.resume(returning: ())
        } catch {
          self.logger.error("Move failed: \(error.localizedDescription, privacy: .public)")
          continuation.resume(throwing: error)
        }
      }
    }
    try host?.throwIfCancelledOrStale(gen)

    if let createdAt = descriptor.creationDate {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { [fileSystem] in
          fileSystem.applyTimestamps(creationDate: createdAt, to: finalURL)
          self.logger.debug(
            "Applied timestamps for id: \(descriptor.id, privacy: .public) variant: \(variant.rawValue, privacy: .public)"
          )
          continuation.resume()
        }
      }
      try host?.throwIfCancelledOrStale(gen)
    }

    recordStoreRouter.markVariantExported(
      assetId: descriptor.id, placement: job.placement, variant: variant,
      relPath: relPath, filename: finalURL.lastPathComponent, exportedAt: Date())
    inFlight = nil
    logger.info(
      "Exported \(finalURL.lastPathComponent, privacy: .public) variant: \(variant.rawValue, privacy: .public) -> \(finalURL.deletingLastPathComponent().path, privacy: .public)"
    )
    return chosenStem
  }

  // MARK: - Helpers

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
      case Int(ENOENT), Int(EACCES), Int(EPERM):
        return true
      default:
        return false
      }
    }
    return false
  }
}
