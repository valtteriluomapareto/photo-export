import Foundation
import Testing

@testable import Photo_Export

/// Pins the collection feedback that the shared start/driver refactor must preserve.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct CollectionExportMessageTests {
  enum Action: CaseIterable, Sendable {
    case favorites, album, sharedAlbum, allSharedAlbumsEmpty, allSharedAlbumsDone

    var message: String {
      switch self {
      case .favorites: "Favorites are already exported."
      case .album: "This album is already exported."
      case .sharedAlbum: "This shared album is already exported."
      case .allSharedAlbumsEmpty: "No shared albums to export."
      case .allSharedAlbumsDone: "All shared albums in this destination are already exported."
      }
    }

    @MainActor
    func start(_ manager: ExportManager) {
      switch self {
      case .favorites: manager.startExportFavorites()
      case .album: manager.startExportAlbum(collectionId: "album")
      case .sharedAlbum: manager.startExportSharedAlbum(collectionId: "shared")
      case .allSharedAlbumsEmpty, .allSharedAlbumsDone: manager.startExportAllSharedAlbums()
      }
    }
  }

  private func finishPreparation(_ manager: ExportManager) async throws {
    let tasks = manager.currentPreparationTasks
    try #require(!tasks.isEmpty)
    for task in tasks { try #require(await finished(task)) }
    await manager.waitForQueueDrained()
  }

  @Test(arguments: Action.allCases)
  func completedCollectionStartPreservesItsExactMessage(action: Action) async throws {
    let h = await ExportManagerHarness(label: "CollectionMessage")
    try await withCleanup {
      if action != .allSharedAlbumsEmpty {
        let asset = TestAssetFactory.makeAsset(id: "asset")
        h.photoLib.resourcesByAssetId[asset.id] = [
          TestAssetFactory.makeResource(originalFilename: "ASSET.JPG")
        ]
        switch action {
        case .favorites: h.photoLib.favoritesAssets = [asset]
        case .album:
          h.photoLib.collectionTree = [
            PhotoCollectionDescriptor(
              id: "album:album", localIdentifier: "album", title: "Album", kind: .album,
              pathComponents: [], children: [])
          ]
          h.photoLib.assetsByAlbumLocalId["album"] = [asset]
        case .sharedAlbum, .allSharedAlbumsDone:
          h.photoLib.collectionTree = [
            PhotoCollectionDescriptor(
              id: "shared:shared", localIdentifier: "shared", title: "Shared", kind: .sharedAlbum,
              pathComponents: [], children: [])
          ]
          h.photoLib.assetsBySharedAlbumLocalId["shared"] = [asset]
        case .allSharedAlbumsEmpty: break
        }
        action.start(h.manager)
        try await finishPreparation(h.manager)
        #expect(h.writer.writeCalls.map(\.assetId) == [asset.id], "the first export is the control")
        #expect(h.manager.emptyRunMessage == nil)
      }
      let writes = h.writer.writeCalls.map(\.assetId)
      action.start(h.manager)
      try await finishPreparation(h.manager)
      #expect(h.manager.emptyRunMessage == action.message)
      #expect(h.manager.totalJobsEnqueued == 0)
      #expect(h.writer.writeCalls.map(\.assetId) == writes)
    } cleanup: {
      h.manager.cancelAndClear()
      await h.manager.waitForQueueDrained()
      try? await h.store.flush()
      try? await h.collectionStore.flush()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
  }
}
