import Foundation

/// The destination's published identity, emitted atomically by `ExportDestinationManager`.
///
/// Carries two fields that used to be two separate `@Published` properties:
///
/// - `stableId` — the **stable logical destination id**. This is the keying id for every
///   per-destination store (record stores, AutoSync state, current-run journal, safety
///   confirmation). It is persisted beside the security-scoped bookmark and reused verbatim
///   for as long as that bookmark resolves to the same folder, so it does **not** drift when a
///   network share remounts under a different path. `nil` means "no destination selected, or
///   the selected destination is currently unavailable" — see the unavailable invariant on
///   `ExportDestinationManager`.
/// - `fingerprint` — the volume/path `DestinationFingerprint`. After the stable-id work this is
///   purely the identity-**confidence** signal for the AutoSync safety gate
///   (`identityConfidence`); it is no longer the keying id. It may drift across a network-share
///   remount while `stableId` holds.
///
/// Publishing the two together as one value is load-bearing: a subscriber can never observe a
/// new fingerprint paired with the stale id (or vice versa). The old two-`@Published` pair-write
/// had exactly that gap, and the documented "read `fingerprint?.id`" workaround inverted once the
/// stable id diverged from the fingerprint id.
struct DestinationIdentity: Equatable, Sendable {
  let stableId: String?
  let fingerprint: DestinationFingerprint?

  /// No destination selected, or the selected destination is currently unavailable. The
  /// persisted stable id (if any) is kept privately on the manager for reuse — it is just not
  /// published here, so downstream lifecycle code sees the id go to `nil` and runs its
  /// destination-unavailable handling.
  static let unavailable = DestinationIdentity(stableId: nil, fingerprint: nil)
}
