import Foundation
import SwiftUI

/// Formats already-read variant history; the status view retains its keyed store dependency.
struct AssetDetailStatusRow: Equatable {
  let text: String
  let color: Color

  static func rows(
    asset: AssetDescriptor, kind: ExportPlacement.Kind,
    variants: [ExportVariant: ExportVariantRecord]
  ) -> [Self] {
    var labels: [(ExportVariant, String)] = [(.original, "Original")]
    if kind.variantPolicy != .singleResource {
      if asset.isLivePhoto || variants[.originalPairedVideo] != nil {
        labels.append((.originalPairedVideo, "Live Photo video"))
      }
      if asset.hasAdjustments || variants[.edited] != nil { labels.append((.edited, "Edited")) }
      if asset.isLivePhoto || variants[.editedPairedVideo] != nil {
        labels.append((.editedPairedVideo, "Edited Live Photo video"))
      }
    }
    return labels.compactMap { variant, label in
      variants[variant].map { make($0, label: label) }
    }
  }

  private static func make(_ variant: ExportVariantRecord, label: String) -> Self {
    switch variant.status {
    case .done:
      let suffix = variant.exportDate.map { " " + Self.dateTimeFormatter.string(from: $0) } ?? ""
      return Self(text: "\(label): Exported\(suffix)", color: .primary)
    case .inProgress:
      return Self(text: "\(label): In progress", color: .primary)
    case .failed:
      if let friendly = ExportVariantRecovery.friendlyCopy(for: variant.reason, label: label) {
        return Self(text: friendly, color: .secondary)
      }
      return Self(
        text: "\(label) failed: \(variant.lastError ?? "Unknown error")", color: .red)
    case .pending:
      return Self(text: "\(label): Pending", color: .primary)
    }
  }

  private static let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()
}
