import Foundation
import Testing

@testable import Photo_Export

struct AutoExportScopeSelectionTests {
  @Test func defaultIsEmpty() {
    let selection = AutoExportScopeSelection()
    #expect(selection.isEmpty)
    #expect(selection.enabledScopes.isEmpty)
  }

  @Test func includesReportsPerScopeFlags() {
    let selection = AutoExportScopeSelection(
      timeline: true, favorites: false, albums: true, sharedAlbums: false)

    #expect(selection.includes(.timeline))
    #expect(!selection.includes(.favorites))
    #expect(selection.includes(.albums))
    #expect(!selection.includes(.sharedAlbums))
  }

  @Test func sharedAlbumsFlagIsIndependentOfAlbums() {
    let onlyShared = AutoExportScopeSelection(sharedAlbums: true)
    #expect(!onlyShared.includes(.albums))
    #expect(onlyShared.includes(.sharedAlbums))
    #expect(onlyShared.enabledScopes == [.sharedAlbums])
  }

  @Test func enabledScopesIsOrdered() {
    let selection = AutoExportScopeSelection(
      timeline: true, favorites: true, albums: true, sharedAlbums: true)

    #expect(selection.enabledScopes == [.timeline, .favorites, .albums, .sharedAlbums])
  }

  @Test func roundTripsThroughCodable() throws {
    let selection = AutoExportScopeSelection(
      timeline: true, favorites: false, albums: true, sharedAlbums: true)
    let data = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(AutoExportScopeSelection.self, from: data)

    #expect(decoded == selection)
  }

  /// Persisted selections from an older app version don't carry the
  /// `sharedAlbums` field. The custom `init(from:)` must default it to `false` so
  /// the existing selection survives upgrade without throwing.
  @Test func decodesLegacyPayloadWithoutSharedAlbumsField() throws {
    let legacyJSON = #"{"timeline":true,"favorites":true,"albums":false}"#
    let data = legacyJSON.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AutoExportScopeSelection.self, from: data)

    #expect(decoded.timeline)
    #expect(decoded.favorites)
    #expect(!decoded.albums)
    #expect(!decoded.sharedAlbums)
  }

  @Test func libraryScopeIsCaseIterableInDefinitionOrder() {
    #expect(
      AutoExportLibraryScope.allCases == [.timeline, .favorites, .albums, .sharedAlbums])
  }
}
