import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// While the timeline history loads, the Month and Year panes say so instead of showing
  /// counts from the empty in-memory history.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct HistoryLoadingSummaryTests {
    enum Pane: CaseIterable, Sendable { case month, year }

    @MainActor
    private struct Host: View {
      let pane: Pane
      let service: FakePhotoLibraryService
      @State private var selection: LibrarySelection?
      @State private var selectedAsset: AssetDescriptor?

      var body: some View {
        switch pane {
        case .month:
          MonthContentView(
            year: 2026, month: 1, versionSelection: .edited, livePhotosPaired: false,
            onExportMonth: {}, selectedAsset: $selectedAsset, photoLibraryService: service
          )
          .equatable()
        case .year:
          YearContentView(
            year: 2026, selection: $selection, selectedAsset: $selectedAsset,
            photoLibraryService: service)
        }
      }
    }

    private static let loading = ["Loading export history\u{2026}"]

    @Test(arguments: Pane.allCases)
    func summaryReadsLoadingWhileHistoryLoads(pane: Pane) async throws {
      let root = TestScratch.directory("HistoryLoadingSummary")
      let defaultsName = TestScratch.suiteName("HistoryLoadingSummary")
      let defaults = TestScratch.defaults(suiteName: defaultsName)
      let io = HeldReadIO()
      let service = FakePhotoLibraryService()
      let counter = BodyInvalidationCounter()
      let timeline = ExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
      let collections = CollectionExportRecordStore(baseDirectoryURL: root, recordLogIO: io)
      let manager = ExportManager(
        photoLibraryService: service, exportDestination: FakeExportDestination(),
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
        userDefaults: defaults)
      let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 700, height: 500),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        io.releaseAll()
        timeline.flushForTesting()
        collections.flushForTesting()
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsName)
      }

      let asset = TestAssetFactory.makeAsset(
        id: "january",
        creationDate: Calendar.current.date(
          from: DateComponents(year: 2026, month: 1, day: 10)))
      service.yearCounts = [(2026, 1)]
      service.assetsByYearMonth["2026-1"] = [asset]
      timeline.configure(for: "A")
      timeline.markVariantExported(
        assetId: asset.id, variant: .original, year: 2026, month: 1, relPath: "2026/01/",
        filename: "JANUARY.JPG", exportedAt: Date())
      try await timeline.flush()
      timeline.configure(for: nil)
      collections.configure(for: "A")
      let snapshot = root.appendingPathComponent("A")
        .appendingPathComponent(ExportRecordStore.Constants.snapshotFileName)
      io.hold(snapshot)
      timeline.beginConfigure(for: "A")

      let key = pane == .month ? "month-summary" : "year-summary"
      window.contentView = NSHostingView(
        rootView: Host(pane: pane, service: service)
          .environmentObject(PhotoLibraryManager(overrideService: service))
          .environmentObject(timeline)
          .environmentObject(collections)
          .environmentObject(manager)
          .environmentObject(ExportDestinationManager(skipRestore: true, userDefaults: defaults))
          .environment(\.bodyInvalidationCounter, counter))
      window.orderFront(nil)

      try #require(await eventually("the summary renders") { counter.renderedText[key] != nil })
      #expect(counter.renderedText[key] == Self.loading)

      io.release(snapshot)
      await timeline.waitUntilSettled()
      #expect(
        await eventually("the summary leaves the loading text") {
          counter.renderedText[key].map { $0 != Self.loading } ?? false
        })
      let expected = pane == .month ? ["1/1 exported"] : ["1 photo"]
      #expect(
        await eventually("the summary shows \(expected)") { counter.renderedText[key] == expected })
    }
  }
#endif
