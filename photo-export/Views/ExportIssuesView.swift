import SwiftUI

/// Settings → Export Issues tab. Plan §"Settings UX" / §"Phase 4":
/// "automatic export failures grouped by destination/scope/asset, retry
/// status, next eligible retry time, actions to retry, ignore/suppress an
/// issue, or reveal diagnostics."
///
/// MVP read-only view: shows the current destination's retry-state entries
/// grouped by `AutoSyncFailureCategory`, then by placement scope, then by
/// asset. Retry / ignore actions land with Phase 3 Slice C (retry-
/// eligibility) — without it, the only meaningful action would be "wait."
struct ExportIssuesView: View {
  @EnvironmentObject private var autoSyncManager: AutoSyncManager

  var body: some View {
    Group {
      if autoSyncManager.currentRetryState.isEmpty {
        emptyState
      } else {
        issuesList
      }
    }
    .frame(minWidth: 460, minHeight: 460)
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.seal")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)
      Text("No Export Issues")
        .font(.headline)
      Text("Nothing has failed for the current destination.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }

  // MARK: - Issues list

  private var issuesList: some View {
    Form {
      ForEach(groupedByCategory, id: \.category) { group in
        Section(header: Self.header(for: group.category, count: group.entries.count)) {
          ForEach(group.entries, id: \.id) { entry in
            FailureRow(entry: entry) {
              autoSyncManager.retryFailedVariant(
                scope: entry.scopeKey,
                assetId: entry.assetId,
                variant: entry.variant
              )
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
    case .destinationUnavailable, .destinationPermission, .destinationNoSpace:
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
    case .destinationPermission, .destinationNoSpace, .assetMissing, .resourceMissing: return .red
    case .unknown: return .secondary
    }
  }

  private static func title(for category: AutoSyncFailureCategory) -> String {
    switch category {
    case .destinationUnavailable: return "Destination Unavailable"
    case .destinationPermission: return "Destination Permission"
    case .destinationNoSpace: return "Destination Out of Space"
    case .assetMissing: return "Asset Missing"
    case .resourceMissing: return "Resource Unavailable"
    case .photoKitTransient: return "Photos Library Transient"
    case .iCloudTransient: return "iCloud / Network"
    case .unknown: return "Other"
    }
  }

  // MARK: - Grouping

  private struct CategoryGroup {
    let category: AutoSyncFailureCategory
    let entries: [FlatFailure]
  }

  /// One row in the issues list. Flattens the `[scopeKey: [assetId:
  /// [variant: entry]]]` nesting so SwiftUI's `ForEach` has a stable
  /// identifier.
  fileprivate struct FlatFailure: Identifiable {
    let id: String  // "<scope>/<assetId>/<variant>"
    let scopeKey: AutoSyncRetryScopeKey
    let assetId: String
    let variant: ExportVariant
    let entry: RetryEntry
  }

  private var groupedByCategory: [CategoryGroup] {
    let flat = Self.flatten(autoSyncManager.currentRetryState)
    let grouped = Dictionary(grouping: flat) { $0.entry.category }
    return AutoSyncFailureCategory.allCases.compactMap { category -> CategoryGroup? in
      guard let entries = grouped[category], !entries.isEmpty else { return nil }
      // Sort within group: most-recent-failure first, then by asset id.
      let sorted = entries.sorted { a, b in
        if a.entry.lastFailedAt != b.entry.lastFailedAt {
          return a.entry.lastFailedAt > b.entry.lastFailedAt
        }
        return a.assetId < b.assetId
      }
      return CategoryGroup(category: category, entries: sorted)
    }
  }

  private static func flatten(_ retry: AutoSyncRetryState) -> [FlatFailure] {
    var out: [FlatFailure] = []
    for (scopeRaw, byAsset) in retry.entriesByPlacement {
      guard let scopeKey = AutoSyncRetryScopeKey(rawValue: scopeRaw) else { continue }
      for (assetId, byVariant) in byAsset {
        for (variantRaw, entry) in byVariant {
          guard let variant = ExportVariant(rawValue: variantRaw) else { continue }
          out.append(
            FlatFailure(
              id: "\(scopeRaw)/\(assetId)/\(variantRaw)",
              scopeKey: scopeKey,
              assetId: assetId,
              variant: variant,
              entry: entry
            ))
        }
      }
    }
    return out
  }
}

private struct FailureRow: View {
  let entry: ExportIssuesView.FlatFailure
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(scopeLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text("•")
          .foregroundStyle(.tertiary)
        Text(entry.variant.rawValue)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
        Spacer()
        if entry.entry.attemptCount > 1 {
          Text("\(entry.entry.attemptCount) attempts")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Text(entry.assetId)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(failureMessage)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Text(timeFooter)
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Retry", action: onRetry)
          .controlSize(.small)
      }
    }
    .padding(.vertical, 2)
  }

  private var scopeLabel: String {
    switch entry.scopeKey {
    case .timeline: return "Timeline"
    case .favorites: return "Favorites"
    case .album(let placementId): return "Album: \(placementId.prefix(8))…"
    }
  }

  /// Human-readable description for this failure. Per-category copy mirrors
  /// the section header so the row reads even when the user can't see the
  /// section context (VoiceOver linear traversal, narrow window). The
  /// underlying `errorSignature` is "<domain>:<code>" — useful for log
  /// hunting but opaque to end-users — exposed under "Show details".
  private var failureMessage: String {
    switch entry.entry.category {
    case .destinationUnavailable: return "Couldn't reach the destination drive."
    case .destinationPermission:
      return "The destination drive rejected the write."
    case .destinationNoSpace:
      return "The destination drive ran out of space."
    case .assetMissing:
      return "The photo couldn't be found in your Photos library."
    case .resourceMissing:
      return "The required file inside Photos wasn't available."
    case .photoKitTransient:
      return "Photos library was temporarily unavailable."
    case .iCloudTransient:
      return "iCloud download or network access failed."
    case .unknown:
      return "Couldn't export — \(entry.entry.errorSignature)"
    }
  }

  private var timeFooter: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let last = formatter.localizedString(
      for: entry.entry.lastFailedAt, relativeTo: Date())
    let retryClause: String
    if let nextEligibleAt = entry.entry.nextEligibleAt {
      if nextEligibleAt > Date() {
        let inWhen = formatter.localizedString(for: nextEligibleAt, relativeTo: Date())
        retryClause = " · auto-retry \(inWhen)"
      } else {
        retryClause = " · eligible to retry now"
      }
    } else if entry.entry.category.isAutomaticallyRetryable {
      // Shouldn't happen — auto-retryable always gets a nextEligibleAt.
      retryClause = ""
    } else {
      retryClause = " · needs action"
    }
    return "Last failed \(last)\(retryClause)"
  }
}
