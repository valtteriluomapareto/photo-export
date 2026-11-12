import Testing

@testable import Photo_Export

struct ManualToolbarPresentationTests {
  private func presentation(
    section: LibrarySection = .timeline, items: Set<LibrarySelection> = [],
    focused: LibrarySelection? = nil, version: ExportVersionSelection = .edited,
    availability: ManualExportAvailability = .available, importing: Bool = false,
    active: Bool = false, source: ExportRunSource? = nil
  ) -> ManualToolbarPresentation {
    .init(
      section: section, selectionSet: items, focusedSelection: focused,
      versionSelection: version, availability: availability, destinationHelp: "Reconnect drive",
      isImporting: importing, hasActiveExportWork: active, activeRunSource: source)
  }

  @Test func zeroAndSingleTimelineSelectionKeepGlobalAction() {
    for items: Set<LibrarySelection> in [
      [], [.timelineYear(year: 2026)], [.timelineMonth(year: 2026, month: 1)],
    ] {
      let value = presentation(items: items)
      #expect(value.action == .timelineAll)
      #expect(value.label == "Export All")
    }
  }

  @Test func timelineMultiselectionFiltersOtherSectionAndCountsNormalizedItems() {
    let value = presentation(items: [
      .timelineYear(year: 2026), .timelineMonth(year: 2026, month: 1), .favorites,
    ])
    #expect(value.action == .timelineSelection(.init(years: [2026], months: [])))
    #expect(value.label == "Export 1 Item")
    #expect(value.help.contains("Years cover their months"))
    let single = presentation(items: [.timelineYear(year: 2026), .favorites])
    #expect(single.action == .timelineAll)
  }

  @Test func collectionSingleSelectionAndFocusedSharedAlbumKeepExistingRouting() {
    for item in [LibrarySelection.favorites, .album(collectionId: "A"), .folder(collectionId: "F")]
    {
      let value = presentation(section: .collections, items: [item], focused: item)
      #expect(value.action == .userCollections)
      #expect(value.label == "Export All Albums")
    }
    let shared = presentation(
      section: .collections, focused: .sharedAlbum(collectionId: "S"), version: .editedWithOriginals
    )
    #expect(shared.action == .sharedAlbum("S"))
    #expect(shared.label == "Export Shared Album")
    #expect(shared.help.contains("Include originals is ignored"))
  }

  @Test func collectionMultiSelectionWinsOverSharedFocusAndFiltersTimeline() {
    let items: Set<LibrarySelection> = [
      .favorites, .folder(collectionId: "F"), .sharedAlbum(collectionId: "S"),
    ]
    let value = presentation(
      section: .collections, items: items.union([.timelineYear(year: 2026)]),
      focused: .sharedAlbum(collectionId: "S"))
    #expect(value.action == .collectionsSelection(items))
    #expect(value.label == "Export 3 Items")
    #expect(value.help.contains("Selected folders are expanded"))
  }

  @Test func unavailableHelpHasPriorityAndExistingCrossSectionSharedHelpIsPreserved() {
    let unavailable = presentation(
      focused: .sharedAlbum(collectionId: "S"), availability: .destinationUnavailable)
    #expect(unavailable.help == "Reconnect drive")
    #expect(!unavailable.isEnabled)
    let crossSection = presentation(focused: .sharedAlbum(collectionId: "S"))
    #expect(crossSection.action == .timelineAll)
    #expect(crossSection.help.contains("Include originals is ignored"))
    #expect(presentation(availability: .loadingHistory).help == "Loading export history…")
  }

  @Test func manualBusyAndImportDisableWhileAutomaticWorkCanBeSuperseded() {
    #expect(presentation().isEnabled)
    #expect(!presentation(importing: true).isEnabled)
    #expect(!presentation(active: true).isEnabled)
    #expect(!presentation(active: true, source: .manual).isEnabled)
    #expect(presentation(active: true, source: .autoSync).isEnabled)
    #expect(
      !presentation(availability: .historyUnavailable, active: true, source: .autoSync).isEnabled)
  }

  @Test func versionHelpDistinguishesOriginalCompanionsAndGlobalScope() {
    #expect(presentation().help.contains("in the version Photos shows"))
    #expect(presentation(version: .editedWithOriginals).help.contains("_orig companion"))
    #expect(presentation(section: .collections).help.contains("Shared albums are excluded"))
    #expect(
      presentation(section: .collections, version: .editedWithOriginals).help.contains(
        "_orig companion"))
  }
}
