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
    let selection = AutoExportScopeSelection(timeline: true, favorites: false, albums: true)

    #expect(selection.includes(.timeline))
    #expect(!selection.includes(.favorites))
    #expect(selection.includes(.albums))
  }

  @Test func enabledScopesIsOrdered() {
    let selection = AutoExportScopeSelection(timeline: true, favorites: true, albums: true)

    #expect(selection.enabledScopes == [.timeline, .favorites, .albums])
  }

  @Test func roundTripsThroughCodable() throws {
    let selection = AutoExportScopeSelection(timeline: true, favorites: false, albums: true)
    let data = try JSONEncoder().encode(selection)
    let decoded = try JSONDecoder().decode(AutoExportScopeSelection.self, from: data)

    #expect(decoded == selection)
  }

  @Test func libraryScopeIsCaseIterableInDefinitionOrder() {
    #expect(AutoExportLibraryScope.allCases == [.timeline, .favorites, .albums])
  }
}
