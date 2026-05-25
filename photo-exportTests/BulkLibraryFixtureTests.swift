import XCTest

@testable import Photo_Export

@MainActor
final class BulkLibraryFixtureTests: XCTestCase {
  func testTimelineLibraryDistributesAssetsAcrossYearsAndMonths() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      spec: .init(totalTimelineAssets: 12_000, yearRange: 2020...2025)
    )
    let totalAssets = fake.assetsByYearMonth.values.map(\.count).reduce(0, +)
    // Even distribution across 6 years × 12 months = 72 slots; 12_000 / 72
    // truncates to 166 per month, so the actual total is 72 × 166 = 11_952.
    XCTAssertEqual(totalAssets, 11_952)
    XCTAssertEqual(fake.yearCounts.map(\.year), Array(2020...2025))
    XCTAssertEqual(fake.yearCounts.map(\.count), Array(repeating: 1_992, count: 6))
  }

  func testLargeMonthsReceiveTheExactRequestedCount() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      spec: .init(
        totalTimelineAssets: 20_000,
        yearRange: 2024...2024,
        largeMonths: [.init(year: 2024, month: 6, count: 10_000)]
      )
    )
    XCTAssertEqual(fake.assetsByYearMonth["2024-6"]?.count, 10_000)
    // 20_000 total - 10_000 reserved = 10_000 spread across the 11 remaining
    // months of 2024 (909 per month, truncated).
    XCTAssertEqual(fake.assetsByYearMonth["2024-7"]?.count, 909)
  }

  func testAlbumsSpecPopulatesCollectionTreeAndPerAlbumAssets() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      spec: .init(
        totalTimelineAssets: 0,
        yearRange: 2024...2024,
        albums: .init(folderCount: 2, albumsPerFolder: 3, assetsPerAlbum: 50)
      )
    )
    XCTAssertEqual(fake.collectionTree.count, 2)
    let folder0 = fake.collectionTree[0]
    XCTAssertEqual(folder0.kind, .folder)
    XCTAssertEqual(folder0.children.count, 3)
    let firstAlbumId = folder0.children[0].localIdentifier
    XCTAssertNotNil(firstAlbumId)
    XCTAssertEqual(fake.assetsByAlbumLocalId[firstAlbumId!]?.count, 50)
    // 2 folders × 3 albums × 50 assets each = 300 album assets.
    let totalAlbumAssets = fake.assetsByAlbumLocalId.values.map(\.count).reduce(0, +)
    XCTAssertEqual(totalAlbumAssets, 300)
  }

  func testAssetIdsAreUniqueAcrossTimelineAndAlbums() {
    let fake = BulkLibraryFixture.makeFakeLibrary(
      spec: .init(
        totalTimelineAssets: 1_000,
        yearRange: 2024...2024,
        albums: .init(folderCount: 1, albumsPerFolder: 2, assetsPerAlbum: 20)
      )
    )
    var seen = Set<String>()
    for (_, assets) in fake.assetsByYearMonth {
      for asset in assets {
        XCTAssertTrue(seen.insert(asset.id).inserted, "Duplicate id: \(asset.id)")
      }
    }
    for (_, assets) in fake.assetsByAlbumLocalId {
      for asset in assets {
        XCTAssertTrue(seen.insert(asset.id).inserted, "Duplicate id: \(asset.id)")
      }
    }
  }
}
