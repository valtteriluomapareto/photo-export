import Foundation

@testable import Photo_Export

@MainActor
final class InMemoryDestinationSafetyConfirmationStore:
  DestinationSafetyConfirmationStore
{
  private var confirmed: Set<String> = []

  var nextConfirmError: Error?

  func isConfirmed(destinationId: String) -> Bool {
    confirmed.contains(destinationId)
  }

  func confirm(destinationId: String) throws {
    if let error = nextConfirmError {
      nextConfirmError = nil
      throw error
    }
    confirmed.insert(destinationId)
  }

  func unconfirm(destinationId: String) throws {
    confirmed.remove(destinationId)
  }
}
