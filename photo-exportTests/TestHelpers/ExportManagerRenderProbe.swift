import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// A sibling render barrier, independent of the production view being measured.
  @MainActor
  struct ExportManagerRenderProbe: View {
    @ObservedObject var manager: ExportManager
    let counter: BodyInvalidationCounter

    static func key(for manager: ExportManager) -> String {
      "manager-probe:\(manager.versionSelection.rawValue):\(manager.livePhotosPairedExport):"
        + "\(manager.queueCount):\(manager.isPaused):\(manager.videoLayout.rawValue)"
    }

    var body: some View {
      // swiftlint:disable:next redundant_discardable_let
      let _ = counter.record(Self.key(for: manager))
      Color.clear.frame(width: 1, height: 1)
    }

    /// Requires another rendering even when cancellation returns to an earlier value key.
    static func change(
      manager: ExportManager, counter: BodyInvalidationCounter, in window: NSWindow?,
      _ mutation: () -> Void
    ) async throws {
      let before = counter.snapshot()
      mutation()
      let key = key(for: manager)
      try #require(await observe(in: window) { counter.count(for: key) > (before[key] ?? 0) })
      var awaited = 0
      while awaited < counter.tasks.count {
        let pending = counter.tasks[awaited...]
        awaited = counter.tasks.count
        for task in pending { _ = await finished(task) }
      }
      window?.contentView?.layoutSubtreeIfNeeded()
    }
  }
#endif
