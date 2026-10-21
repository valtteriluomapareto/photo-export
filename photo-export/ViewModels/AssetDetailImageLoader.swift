import AppKit
import Combine
import os

/// Main-actor preview state owned by the detail view. SwiftUI owns the loading
/// task; a separate request token also rejects providers that ignore cancellation.
@MainActor
final class AssetDetailImageLoader: ObservableObject {
  struct State {
    var assetId: String?
    var image: NSImage?
    var isLoading = false
    var errorMessage: String?
  }

  @Published private(set) var state = State()
  private var activeRequest: UUID?
  private let logger = Logger.app(.detailPreview)

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
    isCurrent: @MainActor () -> Bool = { true }
  ) async {
    guard !Task.isCancelled, isCurrent() else { return }
    let request = UUID()
    activeRequest = request
    let retainedImage = state.assetId == assetId ? state.image : nil
    state = State(assetId: assetId, image: retainedImage, isLoading: assetId != nil)
    guard let assetId else { return }
    logger.debug("Preview start id: \(assetId, privacy: .public)")
    do {
      let image = try await service.requestFullImage(for: assetId)
      guard activeRequest == request, isCurrent() else { return }
      guard !Task.isCancelled else {
        state = State(assetId: assetId)
        return
      }
      state = State(assetId: assetId, image: image)
      logger.debug("Preview loaded id: \(assetId, privacy: .public)")
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
      logger.error(
        "Preview failed id: \(assetId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
