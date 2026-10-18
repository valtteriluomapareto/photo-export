import Foundation

struct ExportIssue: Identifiable, Equatable {
  enum Source: Hashable {
    case timeline
    case collection(String)
  }
  struct Key: Hashable {
    let source: Source
    let assetId: String
    let variantRaw: String
  }
  let id: Key
  let destinationId: String
  let scopeLabel: String
  let scopeKey: AutoSyncRetryScopeKey?
  let message: String
  let reason: ExportVariantReason?
  let failedAt: Date?
  let retry: RetryEntry?
  var filename: String?
  var creationDate: Date?

  struct AssetMetadata: Equatable, Sendable {
    let creationDate: Date?
    let originalFilename: String?
  }

  var assetId: String { id.assetId }
  var variant: ExportVariant? { ExportVariant(rawValue: id.variantRaw) }
  var variantLabel: String {
    switch variant {
    case .original: return "Original"
    case .edited: return "Edited"
    case .originalPairedVideo: return "Live Photo video"
    case .editedPairedVideo: return "Edited Live Photo video"
    case nil: return "Unknown version"
    }
  }

  static func nonemptyFilename(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  func enriched(with metadata: AssetMetadata?) -> Self {
    var result = self
    result.filename =
      Self.nonemptyFilename(filename) ?? Self.nonemptyFilename(metadata?.originalFilename)
    result.creationDate = metadata?.creationDate
    return result
  }

  /// Presentation refreshes do not replace the authoritative failed attempt.
  func matchesFailure(_ other: Self) -> Bool {
    id == other.id && destinationId == other.destinationId && scopeLabel == other.scopeLabel
      && scopeKey == other.scopeKey && message == other.message && reason == other.reason
      && failedAt == other.failedAt && retry == other.retry
  }

  var category: AutoSyncFailureCategory { retry?.category ?? .unknown }
  var isCovered: Bool {
    reason == .editedUnavailableOriginalBackedUp || reason == .pairedVideoUnavailable
  }
}

/// Pure projection shared by Settings and its regression tests. No persistence or scheduling.
enum ExportIssuesProjection {
  static func make(
    destinationId: String = "", timeline: [String: ExportRecord] = [:],
    collections: [String: [String: CollectionExportRecordStore.RecordBody]] = [:],
    placements: [String: ExportPlacement] = [:],
    retryState: AutoSyncRetryState = .empty, retryDestinationId: String? = nil,
    assetMetadata: [String: ExportIssue.AssetMetadata] = [:]
  ) -> [ExportIssue] {
    var result: [ExportIssue] = []
    func append(
      source: ExportIssue.Source, assetId: String, rawVariant: String, record: ExportVariantRecord,
      scope: AutoSyncRetryScopeKey?, label: String, originalFilename: String?
    ) {
      guard record.status == .failed else { return }
      let metadata: RetryEntry?
      if retryDestinationId == destinationId, let scope,
        let variant = ExportVariant(rawValue: rawVariant),
        let failedAt = record.failureDate,
        let entry = retryState.entry(scope: scope, assetId: assetId, variant: variant),
        samePersistedFailureTime(record: failedAt, retry: entry.lastFailedAt)
      {
        metadata = entry
      } else {
        metadata = nil
      }
      result.append(
        ExportIssue(
          id: .init(source: source, assetId: assetId, variantRaw: rawVariant),
          destinationId: destinationId, scopeLabel: label, scopeKey: scope,
          message: record.lastError ?? "Failure details unavailable", reason: record.reason,
          failedAt: record.failureDate, retry: metadata,
          filename: ExportIssue.nonemptyFilename(record.filename)
            ?? ExportIssue.nonemptyFilename(originalFilename)
        ).enriched(with: assetMetadata[assetId]))
    }
    for record in timeline.values {
      for (variant, value) in record.variants where value.status == .failed {
        append(
          source: .timeline, assetId: record.id, rawVariant: variant.rawValue, record: value,
          scope: .timeline,
          label: "Timeline \(String(format: "%04d-%02d", record.year, record.month))",
          originalFilename: record.variants[.original]?.filename)
      }
    }
    for (placementId, assets) in collections {
      let placement = placements[placementId]
      let scope = placement.map { AutoSyncManager.retryScopeKey(for: $0) }
      for (assetId, body) in assets {
        for (variant, value) in body.variants where value.status == .failed {
          append(
            source: .collection(placementId), assetId: assetId, rawVariant: variant, record: value,
            scope: scope, label: placement?.displayName ?? "Unknown placement \(placementId)",
            originalFilename: body.variants[ExportVariant.original.rawValue]?.filename)
        }
      }
    }
    return result.sorted {
      if $0.failedAt != $1.failedAt {
        return ($0.failedAt ?? .distantPast) > ($1.failedAt ?? .distantPast)
      }
      if $0.scopeLabel != $1.scopeLabel { return $0.scopeLabel < $1.scopeLabel }
      if $0.assetId != $1.assetId { return $0.assetId < $1.assetId }
      if $0.id.variantRaw != $1.id.variantRaw { return $0.id.variantRaw < $1.id.variantRaw }
      return String(describing: $0.id.source) < String(describing: $1.id.source)
    }
  }

  /// JSONL ISO8601 records retain whole seconds; retry JSON retains fractions.
  /// Only a whole-second record may match its persisted second. Subsecond memory
  /// values must match exactly. Legacy schemas cannot disambiguate events in one second.
  private static func samePersistedFailureTime(record: Date, retry: Date) -> Bool {
    if record == retry { return true }
    let seconds = record.timeIntervalSince1970
    return seconds.rounded(.down) == seconds
      && retry.timeIntervalSince1970.rounded(.down) == seconds
  }

  struct Snapshot {
    let rows: [ExportIssue]
    let unavailableStores: [String]
  }

  @MainActor
  static func snapshot(
    destinationId: String?, timeline: ExportRecordStore, collections: CollectionExportRecordStore,
    retryState: AutoSyncRetryState, retryDestinationId: String?
  ) -> Snapshot {
    let timelineMatches = destinationId != nil && timeline.destinationId == destinationId
    let collectionsMatch = destinationId != nil && collections.destinationId == destinationId
    var unavailable: [String] = []
    if !timelineMatches || timeline.state != .ready { unavailable.append("Timeline") }
    if !collectionsMatch || collections.state != .ready { unavailable.append("Collections") }
    return Snapshot(
      rows: make(
        destinationId: destinationId ?? "",
        timeline: timelineMatches ? timeline.recordsById : [:],
        collections: collectionsMatch ? collections.recordBodies : [:],
        placements: collectionsMatch ? collections.placements : [:],
        retryState: retryState, retryDestinationId: retryDestinationId),
      unavailableStores: unavailable)
  }
}
