import AppKit
import Observation
import os

/// Main-actor preview state owned by the detail view. SwiftUI owns the loading
/// task; a separate request token also rejects providers that ignore cancellation.
@Observable
@MainActor
final class AssetDetailImageLoader {
  struct State {
    var assetId: String?
    var image: NSImage?
    var isLoading = false
    var errorMessage: String?
  }

  private(set) var state = State()
  @ObservationIgnored private var activeRequest: UUID?
  /// Static: `@State` builds a throwaway loader on each parent body run.
  private static let logger = Logger.app(.detailPreview)

  /// SwiftUI may render a new selection before its task starts. Never display
  /// the previous selection's image or error during that interval.
  func state(for assetId: String) -> State {
    state.assetId == assetId ? state : State(assetId: assetId, isLoading: true)
  }

  func clear() {
    activeRequest = nil
    state = State()
  }

  /// The predicate rejects a revised asset even before SwiftUI starts the next
  /// task. UUID ownership still rejects overlapping requests for the same revision.
  func load(
    for assetId: String?, using service: any PhotoLibraryService,
    pixelSize: CGSize = CGSize(width: 2560, height: 2560),
    isCurrent: @escaping @MainActor () -> Bool = { true }
  ) async {
    guard !Task.isCancelled, isCurrent() else { return }
    let request = UUID()
    activeRequest = request
    var retainedImage = state.assetId == assetId ? state.image : nil
    if retainedImage == nil, let assetId {
      // Match the grid's decoded thumbnail bucket without starting another fetch.
      let thumbnailSize = CGSize(width: 256, height: 256)
      if let cached = service.cachedDecodedThumbnail(
        for: assetId, quantizedSize: thumbnailSize, deliveryMode: .highQuality)
        ?? service.cachedDecodedThumbnail(
          for: assetId, quantizedSize: thumbnailSize, deliveryMode: .fast)
      {
        retainedImage = NSImage(cgImage: cached, size: .zero)
      }
    }
    state = State(assetId: assetId, image: retainedImage, isLoading: assetId != nil)
    guard let assetId else { return }
    Self.logger.debug("Preview start id: \(assetId, privacy: .public)")
    do {
      let cancelled = OSAllocatedUnfairLock(initialState: false)
      let image = try await withTaskCancellationHandler {
        try await service.requestPreview(for: assetId, pixelSize: pixelSize) {
          [weak self] image in
          guard let self, !cancelled.withLock({ $0 }), self.activeRequest == request,
            isCurrent(), self.state.isLoading
          else { return }
          self.state = State(assetId: assetId, image: image, isLoading: true)
        }
      } onCancel: {
        cancelled.withLock { $0 = true }
      }
      guard activeRequest == request, isCurrent() else { return }
      guard !Task.isCancelled else {
        state = State(assetId: assetId)
        return
      }
      state = State(assetId: assetId, image: image)
      Self.logger.debug("Preview loaded id: \(assetId, privacy: .public)")
    } catch {
      guard activeRequest == request, isCurrent() else { return }
      guard !Task.isCancelled, !(error is CancellationError) else {
        state = State(assetId: assetId)
        return
      }
      state = State(
        assetId: assetId,
        errorMessage:
          "Failed to load image: \(error.localizedDescription) Select another photo, then return to retry."
      )
      Self.logger.error(
        "Preview failed id: \(assetId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
