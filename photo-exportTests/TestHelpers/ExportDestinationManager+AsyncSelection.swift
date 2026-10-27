import Foundation

@testable import Photo_Export

@MainActor
extension ExportDestinationManager {
  func persistSelectionAndWait(_ url: URL) async {
    applyFolderSelection(url, decision: .newDestination)
    await waitForValidation()
  }

  func selectFolderAndWait(_ url: URL) async {
    processSelectedFolder(url)
    await waitForValidation()
  }

  func keepHistoryAndWait(_ url: URL) async -> Bool {
    await selectFolderKeepingHistory(at: url)
  }

  func revalidateAndWait() async {
    revalidate()
    await waitForValidation()
  }
}
