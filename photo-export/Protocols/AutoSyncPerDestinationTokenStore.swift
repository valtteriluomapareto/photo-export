import Foundation

/// Persists per-destination `lastDurablyRecordedToken` snapshots. Plan
/// §"Persistence Keys": `AutoSync/destinations/<destinationId>/lastDurablyRecordedToken.data`.
/// The token is the cursor each destination has caught up to; on resume, the
/// reducer compares it against the global token to decide whether the
/// destination needs a backfill or can pick up incrementally.
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
