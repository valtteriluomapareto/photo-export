import Foundation

/// Per-variant failure surfaced on an `ExportRunSummary`. AutoSync's reducer
/// reads these to record failures into `AutoSyncRetryState` (Phase 3 Slice B),
/// and the Export Issues UI (Phase 4) reads them to group failures by category
/// / scope / asset.
///
/// `category` is the retry-policy bucket; `errorSignature` is the stable
/// identity used by the retry store to recognise "same failure recurring."
/// `localizedDescription` is the user-visible message — it can change with
/// locale, which is why it is not part of the signature.
struct ExportRunFailureDetail: Equatable, Codable, Sendable {
  let assetId: String
  let placement: ExportPlacement
  let variant: ExportVariant
  let category: AutoSyncFailureCategory
  let errorSignature: String
  let localizedDescription: String
  let failedAt: Date
}
