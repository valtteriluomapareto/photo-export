import Foundation

/// Independent health for each destination's timeline and collection history.
/// Corrupt snapshots require explicit reset; IO failures use non-destructive Retry.
enum RecordStoreState: Sendable, Equatable {
  case unconfigured
  /// The destination's history is being read off the main actor. Records read as empty and
  /// mutations are not accepted until the load finishes.
  case loading
  case ready
  case failed
  case persistenceFailed

  var needsRecovery: Bool { self == .failed || self == .persistenceFailed }
  /// Not waiting for a load to finish.
  var isSettled: Bool { self != .loading }
}

struct RecordPersistenceUnavailable: LocalizedError {
  var errorDescription: String? {
    "Export progress could not be saved. Restore storage access and retry saving records."
  }
}
