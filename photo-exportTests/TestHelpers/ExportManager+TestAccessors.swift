import Combine
import Foundation

@testable import Photo_Export

@MainActor
extension ExportManager {
  var currentTask: Task<Void, Never>? { queueCoordinator.currentTask }
  var queuedCountsByPlacementId: [String: Int] { queueCoordinator.queuedCountsByPlacementId }
  var isProcessing: Bool { queueCoordinator.isProcessing }
  var importTask: Task<Void, Never>? { importCoordinator?.importTask }
  var currentPreparationTasks: [Task<Void, Never>] {
    preparationTasks.values.filter { $0.generation == generation }.map(\.task)
  }
  var importStagePublisher: AnyPublisher<BackupScanner.ImportStage?, Never> {
    importCoordinator.$importStage.eraseToAnyPublisher()
  }
  var isImportingFlagOnlyPublisher: AnyPublisher<Bool, Never> {
    importCoordinator.$isImporting.eraseToAnyPublisher()
  }
}

extension ExportManager.ExportJob {
  init(
    assetLocalIdentifier: String,
    placement: ExportPlacement,
    selection: ExportVersionSelection,
    livePhotosPaired: Bool = false,
    videoLayout: ExportVideoLayout = .flat
  ) {
    self.init(
      assetLocalIdentifier: assetLocalIdentifier, placement: placement,
      settings: .init(
        selection: selection, livePhotosPaired: livePhotosPaired, videoLayout: videoLayout))
  }

}
