import Foundation

/// Snapshot of the destination state the reducer reacts to. Combines what the lifecycle
/// coordinator publishes (the **stable id** + fingerprint) with the availability and safety
/// signals AutoSync needs.
///
/// `stableId == nil` means no destination is selected (or the drive is unmounted / currently
/// unavailable). `isAvailable` distinguishes "drive mounted and writable" from "drive selected
/// but currently unreachable". `fingerprint` is carried for the safety gate's
/// identity-confidence read; it is **not** the keying id — that is `stableId`. The `Equatable`
/// conformance still includes the (potentially drifting) fingerprint deliberately: a metadata
/// refresh on the same stable id flows through as a non-equal value, while `stableId` equality is
/// what prevents a remount from re-keying any per-destination store.
struct DestinationSnapshot: Equatable, Sendable {
  /// The stable logical id — the keying id for every per-destination store. Independent of
  /// `fingerprint?.id`, which is advisory after the stable-id work.
  let stableId: String?
  let fingerprint: DestinationFingerprint?
  let isAvailable: Bool
  let safety: DestinationSafetyState

  static let none = DestinationSnapshot(
    stableId: nil, fingerprint: nil, isAvailable: false, safety: .safe)

  /// Convenience: the destination's keying id, or `nil` when no destination is selected.
  var id: String? { stableId }

  init(
    stableId: String?,
    fingerprint: DestinationFingerprint?,
    isAvailable: Bool,
    safety: DestinationSafetyState
  ) {
    self.stableId = stableId
    self.fingerprint = fingerprint
    self.isAvailable = isAvailable
    self.safety = safety
  }

  /// Test / no-drift convenience: the stable id tracks the fingerprint id. Production builds
  /// snapshots through `DestinationSnapshotAdapter`, which supplies the stable id explicitly so
  /// it can diverge from `fingerprint?.id` across a remount.
  init(
    fingerprint: DestinationFingerprint?,
    isAvailable: Bool,
    safety: DestinationSafetyState
  ) {
    self.init(
      stableId: fingerprint?.id,  // keying-id-ok: no-drift convenience
      fingerprint: fingerprint,
      isAvailable: isAvailable,
      safety: safety)
  }
}
