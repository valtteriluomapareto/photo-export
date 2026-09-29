import AppKit
import Photos
import SwiftUI

struct AssetDetailView: View {
  @EnvironmentObject private var photoLibraryManager: PhotoLibraryManager
  @EnvironmentObject private var exportRecordStore: ExportRecordStore

  let asset: AssetDescriptor?

  @StateObject private var imageLoader = AssetDetailImageLoader()

  var body: some View {
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
              .overlay(ProgressView())
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
    .task(id: asset?.id) {
      await imageLoader.load(for: asset?.id, using: photoLibraryManager)
    }
    .onDisappear { imageLoader.clear() }
  }

  private func metadataView(for asset: AssetDescriptor) -> some View {
    let details = photoLibraryManager.assetDetails(for: asset.id)

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
      if let export = exportRecordStore.exportInfo(assetId: asset.id) {
        variantStatusView(export.variants[.original], label: "Original")
        if asset.isLivePhoto {
          variantStatusView(export.variants[.originalPairedVideo], label: "Live Photo video")
        }
        if asset.hasAdjustments {
          variantStatusView(export.variants[.edited], label: "Edited")
          if asset.isLivePhoto {
            variantStatusView(
              export.variants[.editedPairedVideo], label: "Edited Live Photo video")
          }
        }
      }
    }
    .font(.footnote)
  }

  @ViewBuilder
  private func variantStatusView(_ variant: ExportVariantRecord?, label: String) -> some View {
    if let variant {
      switch variant.status {
      case .done:
        if let when = variant.exportDate {
          Text("\(label): Exported \(dateTimeFormatter.string(from: when))")
        } else {
          Text("\(label): Exported")
        }
      case .inProgress:
        Text("\(label): In progress")
      case .failed:
        if let friendly = ExportVariantRecovery.friendlyCopy(
          for: variant.lastError, label: label)
        {
          // Named recoverable case — render in secondary color with copy that doesn't
          // imply user action or guarantee recovery, just describes the retry behaviour.
          Text(friendly)
            .foregroundColor(.secondary)
        } else {
          Text("\(label) failed: \(variant.lastError ?? "Unknown error")")
            .foregroundColor(.red)
        }
      case .pending:
        Text("\(label): Pending")
      }
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
