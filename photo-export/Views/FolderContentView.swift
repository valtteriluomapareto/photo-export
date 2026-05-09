import SwiftUI

/// Phase 1 placeholder for the folder content pane. Renders the folder's title and a
/// flat list of its direct children so sidebar-selection routing can be verified.
/// Phase 2 replaces the body with the album-tile grid + "Export Folder" action and
/// adds an export-summary header. The view's API (`folderId` + `selection` binding)
/// is the final shape — only the body changes.
struct FolderContentView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager

  let folderId: String
  let title: String
  @Binding var selection: LibrarySelection?
  @Binding var selectedAsset: AssetDescriptor?

  /// Stored to lock in the Phase 2 init shape (parallel to `CollectionContentView`)
  /// even though the placeholder reads through `photoLibraryManager` directly.
  private let photoLibraryService: any PhotoLibraryService

  init(
    folderId: String,
    title: String,
    selection: Binding<LibrarySelection?>,
    selectedAsset: Binding<AssetDescriptor?>,
    photoLibraryService: any PhotoLibraryService
  ) {
    self.folderId = folderId
    self.title = title
    self._selection = selection
    self._selectedAsset = selectedAsset
    self.photoLibraryService = photoLibraryService
  }

  @State private var folder: PhotoCollectionDescriptor?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.top, 8)

      if let folder, !folder.children.isEmpty {
        List {
          ForEach(folder.children, id: \.id) { child in
            Button {
              switch child.kind {
              case .album:
                selection = .album(collectionId: child.localIdentifier ?? "")
              case .folder:
                selection = .folder(collectionId: child.localIdentifier ?? "")
              case .favorites:
                break
              }
              selectedAsset = nil
            } label: {
              HStack(spacing: 8) {
                Image(
                  systemName: child.kind == .folder ? "folder" : "rectangle.stack"
                )
                .foregroundColor(.secondary)
                Text(child.title.isEmpty ? "Untitled" : child.title)
                Spacer()
              }
            }
            .buttonStyle(.plain)
          }
        }
      } else if folder != nil {
        emptyState
      } else {
        ProgressView("Loading…")
      }
    }
    .padding(.horizontal)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: folderId + "|\(photoLibraryManager.libraryRevision)") {
      folder = findFolder(folderId: folderId)
    }
  }

  private var emptyState: some View {
    VStack {
      Spacer()
      Text("This folder is empty")
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func findFolder(folderId: String) -> PhotoCollectionDescriptor? {
    let tree = (try? photoLibraryManager.fetchCollectionTree()) ?? []
    return search(folderId: folderId, in: tree)
  }

  private func search(folderId: String, in tree: [PhotoCollectionDescriptor])
    -> PhotoCollectionDescriptor?
  {
    for descriptor in tree {
      if descriptor.kind == .folder, descriptor.localIdentifier == folderId {
        return descriptor
      }
      if let found = search(folderId: folderId, in: descriptor.children) {
        return found
      }
    }
    return nil
  }
}
