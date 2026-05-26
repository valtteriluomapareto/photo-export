import Foundation
import Photos

@testable import Photo_Export

/// Synthesizes 10k–100k-asset libraries for `FakePhotoLibraryService`-backed
/// performance tests. Deterministic — same args produce the same fake.
@MainActor
enum BulkLibraryFixture {
  /// Distributes `timelineAssets` across `years` × 12 months. `largeMonths`
  /// triples are honoured verbatim; the rest of the budget is spread evenly
  /// (integer division, so the actual total may round down). Album/folder
  /// fixtures are populated when `albumFolders > 0`; asset ids never collide
  /// between the timeline and album halves.
  static func makeFakeLibrary(
    timelineAssets: Int = 10_000,
    years: ClosedRange<Int> = 2010...2025,
    largeMonths: [(year: Int, month: Int, count: Int)] = [],
    albumFolders: Int = 0,
    albumsPerFolder: Int = 0,
    assetsPerAlbum: Int = 0
  ) -> FakePhotoLibraryService {
    let fake = FakePhotoLibraryService()
    var assetIndex = 0

    var reservedByYearMonth: [String: Int] = [:]
    for entry in largeMonths {
      reservedByYearMonth["\(entry.year)-\(entry.month)"] = entry.count
    }
    let reservedTotal = reservedByYearMonth.values.reduce(0, +)
    let yearList = Array(years)
    let regularSlots = max(0, yearList.count * 12 - reservedByYearMonth.count)
    let remaining = max(0, timelineAssets - reservedTotal)
    let perMonth = regularSlots > 0 ? remaining / regularSlots : 0

    let calendar = Calendar(identifier: .gregorian)
    var monthlyAssets: [String: [AssetDescriptor]] = [:]
    var yearTotals: [Int: Int] = [:]
    for year in yearList {
      for month in 1...12 {
        let key = "\(year)-\(month)"
        let count = reservedByYearMonth[key] ?? perMonth
        guard count > 0 else { continue }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 15
        components.hour = 12
        let baseDate = calendar.date(from: components)
        var assets: [AssetDescriptor] = []
        assets.reserveCapacity(count)
        for _ in 0..<count {
          assets.append(
            AssetDescriptor(
              id: "bulk-\(assetIndex)",
              creationDate: baseDate,
              mediaType: .image,
              pixelWidth: 4032,
              pixelHeight: 3024,
              duration: 0,
              hasAdjustments: false
            )
          )
          assetIndex += 1
        }
        monthlyAssets[key] = assets
        yearTotals[year, default: 0] += count
      }
    }
    fake.assetsByYearMonth = monthlyAssets
    fake.yearCounts = yearList.compactMap { year in
      guard let total = yearTotals[year], total > 0 else { return nil }
      return (year: year, count: total)
    }

    guard albumFolders > 0 else { return fake }
    var tree: [PhotoCollectionDescriptor] = []
    for folderIndex in 0..<albumFolders {
      var children: [PhotoCollectionDescriptor] = []
      for albumIndex in 0..<albumsPerFolder {
        let albumLocalId = "bulk-album-\(folderIndex)-\(albumIndex)"
        var assets: [AssetDescriptor] = []
        assets.reserveCapacity(assetsPerAlbum)
        for _ in 0..<assetsPerAlbum {
          assets.append(
            AssetDescriptor(
              id: "bulk-album-asset-\(assetIndex)",
              creationDate: Date(timeIntervalSince1970: 1_700_000_000),
              mediaType: .image,
              pixelWidth: 4032,
              pixelHeight: 3024,
              duration: 0,
              hasAdjustments: false
            )
          )
          assetIndex += 1
        }
        fake.assetsByAlbumLocalId[albumLocalId] = assets
        children.append(
          PhotoCollectionDescriptor(
            id: "album-\(albumLocalId)",
            localIdentifier: albumLocalId,
            title: "Album \(folderIndex)-\(albumIndex)",
            kind: .album,
            pathComponents: ["Folder \(folderIndex)"],
            children: []
          )
        )
      }
      tree.append(
        PhotoCollectionDescriptor(
          id: "folder-bulk-folder-\(folderIndex)",
          localIdentifier: "bulk-folder-\(folderIndex)",
          title: "Folder \(folderIndex)",
          kind: .folder,
          pathComponents: [],
          children: children
        )
      )
    }
    fake.collectionTree = tree
    return fake
  }
}
