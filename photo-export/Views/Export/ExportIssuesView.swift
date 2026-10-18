import SwiftUI

/// Failed variants from current export records, with matching Auto Export retry history.
struct ExportIssuesView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var autoSyncManager: AutoSyncManager
  @State private var loadedMetadata:
    (request: ExportIssueMetadataRequest, values: [String: ExportIssue.AssetMetadata])?
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @EnvironmentObject private var exportDestinationManager: ExportDestinationManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

  private var snapshot: ExportIssuesProjection.Snapshot {
    ExportIssuesProjection.snapshot(
      destinationId: exportDestinationManager.destinationId,
      timeline: exportRecordStore, collections: collectionExportRecordStore,
      retryState: autoSyncManager.currentRetryState,
      retryDestinationId: autoSyncManager.currentRetryDestinationId)
  }

  private var metadataRequest: ExportIssueMetadataRequest {
    ExportIssueMetadataRequest(
      destinationId: exportDestinationManager.destinationId,
      libraryRevision: photoLibraryManager.libraryRevision, rows: snapshot.rows)
  }

  var body: some View {
    let raw = snapshot
    let request = ExportIssueMetadataRequest(
      destinationId: exportDestinationManager.destinationId,
      libraryRevision: photoLibraryManager.libraryRevision, rows: raw.rows)
    let metadata = loadedMetadata?.request == request ? loadedMetadata?.values ?? [:] : [:]
    let current = ExportIssuesProjection.Snapshot(
      rows: raw.rows.map { $0.enriched(with: metadata[$0.assetId]) },
      unavailableStores: raw.unavailableStores)
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText(current.rows.map(\.assetId), for: "issue-visible-ids")
    #endif
    VStack(spacing: 0) {
      if !current.unavailableStores.isEmpty {
        Text(
          exportDestinationManager.destinationId == nil
            ? "Choose an export destination to view its issues."
            : "\(current.unavailableStores.joined(separator: " and ")) records are unavailable or unsaved. This list may be incomplete."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding()
      }
      if current.rows.isEmpty {
        if current.unavailableStores.isEmpty {
          emptyState
        } else {
          Spacer()
          Text("Export issue information is unavailable.").foregroundStyle(.secondary)
          Spacer()
        }
      } else {
        issuesList(
          current.rows,
          canRetry: current.unavailableStores.isEmpty
            && autoSyncManager.isEnabled && exportDestinationManager.canExportNow)
      }
    }
    .frame(minWidth: 460, minHeight: 460)
    .task(id: request) {
      guard let values = await request.load(using: photoLibraryManager),
        !Task.isCancelled, request == metadataRequest
      else { return }
      loadedMetadata = (request, values)
      #if DEBUG
        bodyCounter?.record(
          "issue-metadata:\(request.destinationId ?? "none"):\(request.libraryRevision)")
      #endif
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.seal").font(.system(size: 48)).foregroundStyle(.secondary)
      Text("No Export Issues").font(.headline)
      Text("No failed versions are recorded for the current destination.")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }

  private func issuesList(_ rows: [ExportIssue], canRetry: Bool) -> some View {
    let grouped = Dictionary(grouping: rows, by: \.category)
    return Form {
      ForEach(AutoSyncFailureCategory.allCases, id: \.self) { category in
        if let entries = grouped[category] {
          Section(header: Self.header(for: category, count: entries.count)) {
            ForEach(entries) { entry in
              FailureRow(
                entry: entry, canRetry: canRetry, autoExportEnabled: autoSyncManager.isEnabled
              ) {
                // A rendered closure can outlive a destination switch or a new failure.
                guard snapshot.rows.contains(where: { $0.matchesFailure(entry) }),
                  let scope = entry.scopeKey,
                  let variant = entry.variant, let retry = entry.retry
                else { return }
                autoSyncManager.retryFailedVariant(
                  scope: scope, assetId: entry.assetId, variant: variant,
                  expectedDestinationId: entry.destinationId, expectedEntry: retry)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private static func header(for category: AutoSyncFailureCategory, count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: Self.icon(for: category))
        .foregroundStyle(Self.tint(for: category))
      Text(Self.title(for: category))
      Text("(\(count))")
        .foregroundStyle(.secondary)
    }
  }

  private static func icon(for category: AutoSyncFailureCategory) -> String {
    switch category {
    case .destinationUnavailable, .destinationPermission, .destinationNoSpace,
      .destinationCollision:
      return "externaldrive.badge.exclamationmark"
    case .assetMissing, .resourceMissing:
      return "photo.badge.exclamationmark"
    case .photoKitTransient:
      return "photo.stack"
    case .iCloudTransient:
      return "icloud.slash"
    case .unknown:
      return "questionmark.circle"
    }
  }

  private static func tint(for category: AutoSyncFailureCategory) -> Color {
    switch category {
    case .destinationUnavailable, .iCloudTransient, .photoKitTransient: return .orange
    case .destinationPermission, .destinationNoSpace, .destinationCollision, .assetMissing,
      .resourceMissing:
      return .red
    case .unknown: return .secondary
    }
  }

  private static func title(for category: AutoSyncFailureCategory) -> String {
    switch category {
    case .destinationUnavailable: return "Destination Unavailable"
    case .destinationPermission: return "Destination Permission"
    case .destinationNoSpace: return "Destination Out of Space"
    case .destinationCollision: return "Destination File Conflict"
    case .assetMissing: return "Asset Missing"
    case .resourceMissing: return "Resource Unavailable"
    case .photoKitTransient: return "Photos Library Transient"
    case .iCloudTransient: return "iCloud / Network"
    case .unknown: return "Other"
    }
  }

}

private struct FailureRow: View {
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif
  @Environment(\.locale) private var locale
  let entry: ExportIssue
  let canRetry: Bool
  let autoExportEnabled: Bool
  let onRetry: () -> Void

  var body: some View {
    let primaryLine =
      "\(entry.filename ?? "Filename unavailable") · \(creationDateLabel) · \(entry.variantLabel)"
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.recordText(
        [primaryLine, entry.assetId], for: "issue-row:\(entry.assetId)")
    #endif
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(primaryLine).font(.callout).foregroundStyle(.secondary)
        Spacer()
        if let attempts = entry.retry?.attemptCount, attempts > 1 {
          Text("\(attempts) attempts").font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(entry.scopeLabel).font(.callout).foregroundStyle(.secondary)
      Text(entry.assetId).font(.caption.monospaced()).foregroundStyle(.tertiary)
        .textSelection(.enabled)
      if entry.variant == nil {
        Text("Version key: \(entry.id.variantRaw)").font(.caption.monospaced())
          .foregroundStyle(.secondary).textSelection(.enabled)
      }
      Text(
        ExportVariantRecovery.friendlyCopy(for: entry.reason, label: entry.variantLabel)
          ?? entry.message
      )
      .font(.callout).fixedSize(horizontal: false, vertical: true)
      HStack {
        Text(timeFooter).font(.caption).foregroundStyle(.tertiary)
        Spacer()
        if entry.retry != nil, entry.scopeKey != nil, entry.variant != nil, !entry.isCovered {
          #if DEBUG
            // swiftlint:disable:next redundant_discardable_let
            let _ = bodyCounter?.recordAction("issue-retry:\(entry.assetId)", action: onRetry)
          #endif
          Button("Retry", action: onRetry).controlSize(.small).disabled(!canRetry)
            .help(
              "Retries using your configured Auto Export scopes. You can also export this item manually."
            )
        }
      }
      if !entry.isCovered, entry.retry == nil {
        Text(
          entry.scopeKey != nil && entry.variant != nil
            ? "Use a manual export to retry this item." : "This item can't be retried here."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  private var creationDateLabel: String {
    guard let date = entry.creationDate else { return "Date unavailable" }
    return date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
  }

  private var timeFooter: String {
    guard let date = entry.failedAt else { return "Failure time unavailable" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let now = Date()
    var result = "Last failed \(formatter.localizedString(for: date, relativeTo: now))"
    if !entry.isCovered, entry.retry != nil, !autoExportEnabled {
      result += " · Auto Export is off"
    } else if !entry.isCovered, let next = entry.retry?.nextEligibleAt {
      result +=
        next > now
        ? " · auto-retry \(formatter.localizedString(for: next, relativeTo: now))"
        : " · eligible to retry now"
    } else if !entry.isCovered, entry.retry != nil {
      result += " · needs action"
    }
    return result
  }
}
