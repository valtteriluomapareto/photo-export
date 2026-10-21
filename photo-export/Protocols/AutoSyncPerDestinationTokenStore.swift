import Foundation

/// Persists per-destination `lastDurablyRecordedToken` snapshots at
/// `AutoSync/destinations/<destinationId>/lastDurablyRecordedToken.data`.
/// The token records advisory acknowledgement after dirty-state persistence.
/// It is currently loaded but does not drive fetching or resume decisions;
/// the PhotoKit adapter owns an independent global cursor.
///
/// Stored as raw `Data` (NSKeyedArchiver bytes from the global adapter) so the
/// store doesn't depend on PhotoKit types — the reducer treats it opaquely.
@MainActor
protocol AutoSyncPerDestinationTokenStore: AnyObject {
  /// Loads the token for `destinationId`, or nil when none has been recorded yet
  /// (or the file is corrupt — see production decode-error handling).
  func load(destinationId: String) -> Data?

  /// Persists `token` for `destinationId`, replacing any prior value.
  func save(_ token: Data, destinationId: String) throws

  /// Removes any stored token for `destinationId`.
  func deleteToken(destinationId: String) throws
}
