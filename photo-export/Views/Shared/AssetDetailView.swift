import AppKit
import Photos
import SwiftUI

struct AssetDetailView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @Environment(ExportRecordStore.self) private var exportRecordStore
  @EnvironmentObject private var collectionExportRecordStore: CollectionExportRecordStore

  let asset: AssetDescriptor?
  let placement: ExportPlacement?
  #if DEBUG
    @Environment(\.bodyInvalidationCounter) private var bodyCounter
  #endif

  init(asset: AssetDescriptor?, placement: ExportPlacement?) {
    self.asset = asset
    self.placement = placement
  }

  private struct StatusRow {
    let text: String
    let color: Color
  }

  @State private var imageLoader = AssetDetailImageLoader()

  private struct LoadIdentity: Hashable {
    let assetId: String?
    let contentRevision: Int
  }

  private var loadIdentity: LoadIdentity {
    LoadIdentity(
      assetId: asset?.id,
      contentRevision: asset.map { photoLibraryManager.thumbnailContentRevision(for: $0.id) } ?? 0)
  }

  var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = bodyCounter?.record("asset-detail-body")
    #endif
    let identity = loadIdentity
    VStack(spacing: 12) {
      if let asset {
        let preview = imageLoader.state(for: asset.id)
        ZStack {
          if let fullImage = preview.image {
            Image(nsImage: fullImage)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if preview.isLoading {
            Rectangle()
              .fill(Color.gray.opacity(0.15))
              .overlay(ProgressView().accessibilityLabel("Loading preview"))
          } else if let errorMessage = preview.errorMessage {
            Rectangle()
              .fill(Color.gray.opacity(0.15))
              .overlay(Text(errorMessage).foregroundColor(.red))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        metadataView(for: asset)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.bottom)
      } else {
        VStack(spacing: 8) {
          Spacer()
          Image(systemName: "photo")
            .font(.system(size: 36))
            .foregroundColor(.secondary)
          Text("No image selected")
            .foregroundColor(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: identity) {
      await imageLoader.load(for: identity.assetId, using: photoLibraryManager) {
        guard let id = identity.assetId else { return true }
        return photoLibraryManager.thumbnailContentRevision(for: id) == identity.contentRevision
      }
    }
    .onDisappear { imageLoader.clear() }
  }

  private func metadataView(for asset: AssetDescriptor) -> some View {
    let details = photoLibraryManager.assetDetails(for: asset.id)
    let rows = statusRows(for: asset)
    #if DEBUG
      bodyCounter?.recordText(rows.map(\.text), for: "asset-detail-status")
    #endif

    return VStack(alignment: .leading, spacing: 6) {
      if let name = details?.originalFilename {
        Text(name)
          .fontWeight(.medium)
      }
      if let date = asset.creationDate {
        Text(dateFormatter.string(from: date))
      }
      Text(mediaTypeString(from: asset.mediaType))
      Text("Dimensions: \(asset.pixelWidth) \u{00d7} \(asset.pixelHeight)")
      if let bytes = details?.fileSize {
        Text("File size: \(formattedFileSize(bytes))")
      }
      if asset.mediaType == .video {
        let durationString = String(format: "%.0fs", asset.duration)
        Text("Duration: \(durationString)")
      }
      Text(asset.hasAdjustments ? "Edits: Available in Photos" : "Edits: None in Photos")
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        Text(row.text).foregroundColor(row.color)
      }
    }
    .font(.footnote)
  }

  private func statusRows(for asset: AssetDescriptor) -> [StatusRow] {
    guard let placement else { return [] }
    let variants = RecordStoreRouter(
      timelineStore: exportRecordStore, collectionStore: collectionExportRecordStore
    ).variants(forAssetId: asset.id, placement: placement)
    var labels: [(ExportVariant, String)] = [(.original, "Original")]
    if placement.kind.variantPolicy != .singleResource {
      if asset.isLivePhoto || variants[.originalPairedVideo] != nil {
        labels.append((.originalPairedVideo, "Live Photo video"))
      }
      if asset.hasAdjustments || variants[.edited] != nil { labels.append((.edited, "Edited")) }
      if asset.isLivePhoto || variants[.editedPairedVideo] != nil {
        labels.append((.editedPairedVideo, "Edited Live Photo video"))
      }
    }
    return labels.compactMap { variant, label in
      variants[variant].map { statusRow($0, label: label) }
    }
  }

  private func statusRow(_ variant: ExportVariantRecord, label: String) -> StatusRow {
    switch variant.status {
    case .done:
      let suffix = variant.exportDate.map { " " + dateTimeFormatter.string(from: $0) } ?? ""
      return StatusRow(text: "\(label): Exported\(suffix)", color: .primary)
    case .inProgress:
      return StatusRow(text: "\(label): In progress", color: .primary)
    case .failed:
      if let friendly = ExportVariantRecovery.friendlyCopy(for: variant.reason, label: label) {
        return StatusRow(text: friendly, color: .secondary)
      }
      return StatusRow(
        text: "\(label) failed: \(variant.lastError ?? "Unknown error")", color: .red)
    case .pending:
      return StatusRow(text: "\(label): Pending", color: .primary)
    }
  }

  private func mediaTypeString(from type: PHAssetMediaType) -> String {
    switch type {
    case .image: return "Photo"
    case .video: return "Video"
    case .audio: return "Audio"
    case .unknown: return "Unknown"
    @unknown default: return "Unknown"
    }
  }

  private func formattedFileSize(_ bytes: Int64) -> String {
    Self.byteCountFormatter.string(fromByteCount: bytes)
  }

  private static let byteCountFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    return f
  }()

  private static let dateFormatterMedium: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    return f
  }()

  private static let dateTimeFormatterMedium: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

  private var dateFormatter: DateFormatter { Self.dateFormatterMedium }
  private var dateTimeFormatter: DateFormatter { Self.dateTimeFormatterMedium }
}
