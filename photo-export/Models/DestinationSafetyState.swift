import Foundation

/// Whether the safety gate allows automatic export to the current destination.
/// Confirmation and migration conflicts block the reducer until the user resolves them.
/// See docs/reference/auto-export-behavior.md#destination-safety.
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
