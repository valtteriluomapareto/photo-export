import Foundation
import Testing

@testable import Photo_Export

@MainActor
struct BulkLibraryFixtureTests {
  @Test func timelineLibraryDistributesAssetsAcrossYearsAndMonths() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      timelineAssets: 12_000, years: 2020...2025)
    let totalAssets = fake.assetsByYearMonth.values.map(\.count).reduce(0, +)
    // 12_000 / 72 = 166 per month → 72 × 166 = 11_952.
    #expect(totalAssets == 11_952)
    #expect(fake.yearCounts.map(\.year) == Array(2020...2025))
    #expect(fake.yearCounts.map(\.count) == Array(repeating: 1_992, count: 6))
  }

  @Test func largeMonthsReceiveTheExactRequestedCount() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      timelineAssets: 20_000,
      years: 2024...2024,
      largeMonths: [(year: 2024, month: 6, count: 10_000)])
    #expect(fake.assetsByYearMonth["2024-6"]?.count == 10_000)
    // 10_000 remaining / 11 months = 909.
    #expect(fake.assetsByYearMonth["2024-7"]?.count == 909)
  }

  @Test func albumsPopulateCollectionTreeAndPerAlbumAssets() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      timelineAssets: 0,
      years: 2024...2024,
      albumFolders: 2,
      albumsPerFolder: 3,
      assetsPerAlbum: 50)
    #expect(fake.collectionTree.count == 2)
    let folder0 = fake.collectionTree[0]
    #expect(folder0.kind == .folder)
    #expect(folder0.children.count == 3)
    let firstAlbumId = folder0.children[0].localIdentifier
    #expect(firstAlbumId != nil)
    if let id = firstAlbumId {
      #expect(fake.assetsByAlbumLocalId[id]?.count == 50)
    }
    let totalAlbumAssets = fake.assetsByAlbumLocalId.values.map(\.count).reduce(0, +)
    #expect(totalAlbumAssets == 300)
  }

  @Test func assetIdsAreUniqueAcrossTimelineAndAlbums() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      timelineAssets: 1_000,
      years: 2024...2024,
      albumFolders: 1,
      albumsPerFolder: 2,
      assetsPerAlbum: 20)
    var seen = Set<String>()
    for (_, assets) in fake.assetsByYearMonth {
      for asset in assets {
        #expect(seen.insert(asset.id).inserted, "Duplicate id: \(asset.id)")
      }
    }
    for (_, assets) in fake.assetsByAlbumLocalId {
      for asset in assets {
        #expect(seen.insert(asset.id).inserted, "Duplicate id: \(asset.id)")
      }
    }
  }
}
