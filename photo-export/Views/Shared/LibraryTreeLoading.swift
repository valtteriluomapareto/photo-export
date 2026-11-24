import SwiftUI

/// Owns the async tree task without making the window layout observe refresh ticks.
struct LibraryTreeLoading: ViewModifier {
  @Environment(PhotoLibraryManager.self) private var library

  func body(content: Content) -> some View {
    content.task(id: library.libraryRefresh.revision) {
      await library.libraryRefresh.loadTree()
    }
  }
}
