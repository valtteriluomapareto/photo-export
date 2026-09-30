import Foundation

/// Independent health for each destination's timeline and collection history.
/// Corrupt snapshots require explicit reset; IO failures use non-destructive Retry.
enum RecordStoreState: Sendable, Equatable {
  case unconfigured
  case ready
  case failed
  case persistenceFailed

  var needsRecovery: Bool { self == .failed || self == .persistenceFailed }
}

struct RecordPersistenceUnavailable: LocalizedError {
  var errorDescription: String? {
    "Export progress could not be saved. Restore storage access and retry saving records."
  }
}
