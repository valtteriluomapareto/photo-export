import Foundation

/// Snapshot of the destination state the reducer reacts to. Combines what the lifecycle
/// coordinator publishes (`DestinationIdentitySnapshot` — id + fingerprint) with the
/// availability and safety signals AutoSync needs.
///
/// `nil` `fingerprint` means no destination is selected (or the drive is unmounted with
/// no cached fingerprint). `isAvailable` distinguishes "drive mounted and writable" from
/// "drive selected but currently unreachable" — both still carry a fingerprint, but only
/// the available one can host a run.
struct DestinationSnapshot: Equatable, Sendable {
  let fingerprint: DestinationFingerprint?
  let isAvailable: Bool
  let safety: DestinationSafetyState

  static let none = DestinationSnapshot(
    fingerprint: nil, isAvailable: false, safety: .safe)

  /// Convenience: the destination's id, or `nil` when no destination is selected.
  var id: String? { fingerprint?.id }
}
