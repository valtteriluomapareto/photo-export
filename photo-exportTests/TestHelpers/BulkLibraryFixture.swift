import Foundation
import Photos

@testable import Photo_Export

/// Bulk fixture builder for `FakePhotoLibraryService`. Synthesizes 10k–100k
/// `AssetDescriptor` libraries — distributed across years, with optional
/// "large months" piles and synthetic album trees — so the smoothness work
/// in `docs/project/plans/ui-smoothness-plan.md` Phase 0 can exercise the
/// app's UI seams against realistic asset counts.
///
/// Determinism: same `Spec` produces the same fake every run. Asset ids are
/// stable strings (`bulk-<index>` / `bulk-album-asset-<index>`) so tests can
/// reference specific entries by index when needed.
@MainActor
enum BulkLibraryFixture {
  /// Builds a populated `FakePhotoLibraryService` from `spec`. Use this entry
  /// point when the test owns the fake from the start.
  static func makeFakeLibrary(spec: Spec) -> FakePhotoLibraryService {
    let fake = FakePhotoLibraryService()
    populate(fake, spec: spec)
    return fake
  }

  /// Populates an existing `FakePhotoLibraryService` in place. Useful when the
  /// fake is already wired into a manager hierarchy.
  static func populate(_ fake: FakePhotoLibraryService, spec: Spec) {
    var assetIndex = 0

    // Reserve explicit large-month counts first; the remainder is distributed
    // evenly across the months left over.
    var reservedByYearMonth: [String: Int] = [:]
    for entry in spec.largeMonths {
      reservedByYearMonth["\(entry.year)-\(entry.month)"] = entry.count
    }
    let reservedTotal = reservedByYearMonth.values.reduce(0, +)
    let years = Array(spec.yearRange)
    let regularSlots = max(0, years.count * 12 - reservedByYearMonth.count)
    let remaining = max(0, spec.totalTimelineAssets - reservedTotal)
    let perMonth = regularSlots > 0 ? remaining / regularSlots : 0

    let calendar = Calendar(identifier: .gregorian)
    var monthlyAssets: [String: [AssetDescriptor]] = [:]
    var yearTotals: [Int: Int] = [:]
    for year in years {
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
    fake.yearCounts = years.compactMap { year in
      guard let total = yearTotals[year], total > 0 else { return nil }
      return (year: year, count: total)
    }

    if let albumSpec = spec.albums {
      var tree: [PhotoCollectionDescriptor] = []
      for folderIndex in 0..<albumSpec.folderCount {
        var children: [PhotoCollectionDescriptor] = []
        for albumIndex in 0..<albumSpec.albumsPerFolder {
          let albumLocalId = "bulk-album-\(folderIndex)-\(albumIndex)"
          var assets: [AssetDescriptor] = []
          assets.reserveCapacity(albumSpec.assetsPerAlbum)
          for _ in 0..<albumSpec.assetsPerAlbum {
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
    }
  }

  /// Describes the library to synthesize. All fields have defaults that map to
  /// a "small" 10k-asset library spread across `2010...2025`.
  struct Spec {
    /// Approximate total timeline assets to distribute. The actual total may
    /// differ slightly because per-month counts use integer division; the
    /// remainder lands in unreserved months that round down.
    var totalTimelineAssets: Int
    var yearRange: ClosedRange<Int>
    /// (year, month, count) triples that should receive a specific count
    /// instead of the even-distribution share. Useful for exercising large-
    /// month grids (`MonthContentView` against 5k–20k assets).
    var largeMonths: [LargeMonth]
    /// Optional album/folder tree. `nil` leaves `collectionTree` and
    /// `assetsByAlbumLocalId` empty (matches `FakePhotoLibraryService`'s
    /// default state).
    var albums: AlbumsSpec?

    init(
      totalTimelineAssets: Int = 10_000,
      yearRange: ClosedRange<Int> = 2010...2025,
      largeMonths: [LargeMonth] = [],
      albums: AlbumsSpec? = nil
    ) {
      self.totalTimelineAssets = totalTimelineAssets
      self.yearRange = yearRange
      self.largeMonths = largeMonths
      self.albums = albums
    }
  }

  struct LargeMonth {
    var year: Int
    var month: Int
    var count: Int
  }

  struct AlbumsSpec {
    var folderCount: Int
    var albumsPerFolder: Int
    var assetsPerAlbum: Int
  }
}
