import Foundation

/// Whether the safety gate allows automatic export to the current destination. Phase 0b
/// will widen this to a richer set of reasons (low-confidence identity, non-empty backup
/// without import, migration conflict, etc.); Phase 2 only needs the binary-plus-conflict
/// shape so the reducer can route between `idle` / `blocked(.destinationUnsafe)`.
enum DestinationSafetyState: Equatable, Sendable {
  /// Automatic export is allowed: empty destination, or non-empty with a confirmation
  /// record matching the current scope selection.
  case safe

  /// Automatic export is blocked because the destination is non-empty and has no
  /// matching confirmation/import state.
  case unsafeNeedsConfirmation

  /// Both `<newId>/` and `<legacyId>/` directories exist. Auto Export blocks until the
  /// user resolves the migration via Settings.
  case unsafeMigrationConflict
}
