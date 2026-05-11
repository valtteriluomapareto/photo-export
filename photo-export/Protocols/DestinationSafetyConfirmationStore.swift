import Foundation

/// Persists "the user has confirmed that this destination's existing contents
/// belong to them and Auto Export can manage it" on a per-destination basis.
/// Plan §"Destination Safety Model" and §"Persistence Keys" call for this
/// state to live at `AutoSync/destinations/<destinationId>/safetyRecord.json`.
///
/// Once a destination is confirmed it stays confirmed across launches — the
/// safety scan only flips a fresh destination ID with pre-existing files
/// into `unsafeNeedsConfirmation`. Switching to a destination the user has
/// already confirmed in the past is `.safe` without re-prompting.
@MainActor
protocol DestinationSafetyConfirmationStore: AnyObject {
  func isConfirmed(destinationId: String) -> Bool
  func confirm(destinationId: String) throws
  /// Removes the confirmation marker. Used when the user resets AutoSync
  /// state from settings, or by tests.
  func unconfirm(destinationId: String) throws
}
