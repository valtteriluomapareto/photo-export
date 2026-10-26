import SwiftUI

/// The header owns aggregate history reads; partial asset batches show only their size.
struct TimelineGridSummary: View, Equatable {
  @Environment(ExportRecordStore.self) private var records
  let assets: [AssetDescriptor]
  let hasCompleteSnapshot: Bool
  let versionSelection: ExportVersionSelection
  let livePhotosPaired: Bool
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    if !hasCompleteSnapshot {
      LoadingGridSummary(count: assets.count)
    } else if records.state == .loading {
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.recordText(
          [ManualExportAvailability.loadingHistoryText], for: "month-summary")
      #endif
      Label(ManualExportAvailability.loadingHistoryText, systemImage: "clock")
        .foregroundColor(.secondary)
    } else {
      let summary = records.monthSummary(
        assets: assets, selection: versionSelection, livePhotosPaired: livePhotosPaired)
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.record("summaryScan")
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.recordText(
          ["\(summary.exportedCount)/\(summary.totalCount) exported"], for: "month-summary")
      #endif
      AssetGridSummaryLabel(summary: summary)
    }
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.assets == rhs.assets && lhs.hasCompleteSnapshot == rhs.hasCompleteSnapshot
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
  }
}

struct CollectionGridSummary: View, Equatable {
  @Environment(CollectionExportRecordStore.self) private var records
  let assets: [AssetDescriptor]
  let hasCompleteSnapshot: Bool
  let versionSelection: ExportVersionSelection
  let livePhotosPaired: Bool
  let placement: ExportPlacement?
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var counter
  #endif

  var body: some View {
    if !hasCompleteSnapshot {
      LoadingGridSummary(count: assets.count)
    } else {
      let summary = summary()
      #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.record("summary:\(summary.exportedCount)/\(summary.totalCount)")
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter?.recordText(
          ["\(summary.exportedCount)/\(summary.totalCount)"], for: "collection-summary")
      #endif
      AssetGridSummaryLabel(summary: summary)
    }
  }

  private func summary() -> MonthStatusSummary {
    guard let placement else {
      return MonthStatusSummary(
        year: 0, month: 0, exportedCount: 0, totalCount: assets.count, status: .notExported)
    }
    #if DEBUG
      counter?.record("summaryScan")
    #endif
    return records.monthSummary(
      assets: assets, placement: placement, selection: versionSelection,
      livePhotosPaired: livePhotosPaired)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.assets == rhs.assets && lhs.hasCompleteSnapshot == rhs.hasCompleteSnapshot
      && lhs.versionSelection == rhs.versionSelection
      && lhs.livePhotosPaired == rhs.livePhotosPaired
      && lhs.placement == rhs.placement
  }
}

private struct LoadingGridSummary: View {
  let count: Int
  var body: some View {
    Text("\(count) photos").font(.subheadline).foregroundColor(.secondary)
  }
}

private struct AssetGridSummaryLabel: View {
  let summary: MonthStatusSummary
  var body: some View {
    HStack(spacing: 8) {
      switch summary.status {
      case .complete:
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "checkmark.circle.fill"
        )
        .foregroundColor(.green)
      case .partial:
        Label(
          "\(summary.exportedCount)/\(summary.totalCount) exported",
          systemImage: "circle.lefthalf.filled"
        )
        .foregroundColor(.orange)
      case .notExported:
        Label("0/\(summary.totalCount) exported", systemImage: "circle")
          .foregroundColor(.secondary)
      }
      Spacer()
    }
    .font(.subheadline)
  }
}
