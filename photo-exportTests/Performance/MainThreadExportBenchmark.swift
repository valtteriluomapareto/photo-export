import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  func benchTime(_ body: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
  }

  @MainActor
  func seedTimelineSnapshot(root: URL, destinationId: String, count: Int) throws {
    let dir = root.appendingPathComponent(destinationId, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var records: [String: ExportRecord] = [:]
    records.reserveCapacity(count)
    let date = Date(timeIntervalSince1970: 1_600_000_000)
    for i in 0..<count {
      let year = 2000 + (i % 20)
      let month = 1 + (i / 20) % 12
      let id = "hist-\(i)/L0/001"
      records[id] = ExportRecord(
        id: id, year: year, month: month,
        relPath: String(format: "%04d/%02d/", year, month),
        variants: [
          .original: ExportVariantRecord(
            filename: "IMG_\(i % 10_000).HEIC", status: .done, exportDate: date, lastError: nil)
        ])
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(records)
    try data.write(to: dir.appendingPathComponent("export-records.json"))
  }

  @MainActor
  @Suite(
    .serialized, .timeLimit(.minutes(10)),
    .enabled(if: ProcessInfo.processInfo.environment["PHOTO_EXPORT_PERF"] == "1"))
  struct MainThreadExportBenchmark {
    private static let sampleCount = 3

    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    private func frozenDictionaryCopy(_ store: ExportRecordStore) -> Double {
      var records = store.recordsById
      let frozen = records
      let elapsed = withExtendedLifetime(frozen) {
        benchTime {
          records["new"] = ExportRecord(id: "new", year: 2024, month: 1, relPath: "2024/01/")
        }
      }
      #expect(records.count == 500_001)
      return elapsed
    }

    @Test func microCosts() async throws {
      let placement = ExportPlacement.timeline(year: 2024, month: 6)
      var dequeueSamples: [Double] = []
      for _ in 0..<Self.sampleCount {
        var jobs = (0..<500_000).map {
          ExportManager.ExportJob(
            assetLocalIdentifier: "asset-\($0)", placement: placement, selection: .edited)
        }
        let elapsed = benchTime {
          for _ in 0..<50 { _ = jobs.removeFirst() }
        }
        dequeueSamples.append(elapsed / 50)
        #expect(jobs.count == 499_950)
      }
      print(
        String(
          format: "BENCH dequeue n=500000 medianPerCall=%.3fms samples=%ld",
          median(dequeueSamples), Self.sampleCount))

      var copySamples: [Double] = []
      var claimSamples: [Double] = []
      var summarySamples: [Double] = []
      var loadedMutationSamples: [Double] = []
      var checkpointMutationSamples: [Double] = []
      for _ in 0..<Self.sampleCount {
        let root = TestScratch.directory("MainThreadBenchRecords")
        try seedTimelineSnapshot(root: root, destinationId: "D", count: 500_000)
        let store = ExportRecordStore(baseDirectoryURL: root, notificationClock: TestClock())
        store.configure(for: "D")
        defer { store.drainSynchronously() }
        copySamples.append(frozenDictionaryCopy(store))
        claimSamples.append(
          benchTime {
            _ = store.isFilenameClaimed(
              "IMG_1.HEIC", year: 2005, month: 3, subfolder: nil, exceptAsset: "x")
          })
        loadedMutationSamples.append(
          try await store.withMutationAdmission {
            benchTime {
              store.markVariantInProgress(
                assetId: "new-load", variant: .original,
                year: 2024, month: 1, relPath: "2024/01/", filename: "new-load.JPG")
            }
          })
        try await store.checkpointHistory()
        checkpointMutationSamples.append(
          try await store.withMutationAdmission {
            benchTime {
              store.markVariantInProgress(
                assetId: "new-checkpoint", variant: .original,
                year: 2024, month: 1, relPath: "2024/01/", filename: "new-checkpoint.JPG")
            }
          })
        let assets = (0..<50_000).map { TestAssetFactory.makeAsset(id: "hist-\($0)/L0/001") }
        summarySamples.append(
          benchTime {
            _ = store.monthSummary(assets: assets, selection: .edited, livePhotosPaired: false)
          })
      }
      print(
        String(
          format: "BENCH compactionCopy n=500000 median=%.3fms samples=%ld",
          median(copySamples), Self.sampleCount))
      print(
        String(
          format: "BENCH claimBuild n=500000 median=%.3fms samples=%ld",
          median(claimSamples), Self.sampleCount))
      print(
        String(
          format: "BENCH productionMutationAfterLoad n=500000 median=%.3fms samples=%ld",
          median(loadedMutationSamples), Self.sampleCount))
      print(
        String(
          format: "BENCH productionMutationAfterCheckpoint n=500000 median=%.3fms samples=%ld",
          median(checkpointMutationSamples), Self.sampleCount))
      print(
        String(
          format: "BENCH monthSummary assets=50000 median=%.3fms samples=%ld",
          median(summarySamples), Self.sampleCount))
    }

    private enum Layout: String, CaseIterable {
      case noUI, sidebar, progressBar, grid, fullWindow
    }

    @Observable
    final class RenderBarrier { var value = 0 }

    private struct BarrierView: View {
      let barrier: RenderBarrier
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("bench-barrier:\(barrier.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    private struct SidebarHost: View {
      let service: FakePhotoLibraryService
      @State var selection: Set<LibrarySelection>
      var body: some View {
        TimelineSidebarView(selectionSet: $selection, photoLibraryService: service)
          .frame(width: 260)
      }
    }

    private struct GridHost: View {
      let library: PhotoLibraryManager
      let year: Int
      let month: Int
      @State private var selection = AssetSelectionModel()
      var body: some View {
        MonthContentView(
          year: year, month: month, versionSelection: .edited, livePhotosPaired: false,
          onExportMonth: {},
          selectedAsset: Binding(
            get: { selection.asset }, set: { selection.asset = $0 }),
          photoLibraryService: library, assetSelection: selection
        ).equatable().frame(width: 520)
      }
    }

    private struct PacedWriter: AssetResourceWriter {
      func writeResource(_ resource: ResourceDescriptor, forAssetId assetId: String, to url: URL)
        async throws
      {
        try await Task.sleep(for: .milliseconds(50))
        try Data(repeating: 7, count: 12).write(to: url)
      }
    }

    @Test func hostedLayouts() async throws {
      var samples: [Layout: [MainThreadBenchMeter.Measurement]] = [:]
      for _ in 0..<Self.sampleCount {
        for layout in Layout.allCases {
          samples[layout, default: []].append(try await run(layout))
        }
      }
      let baseline = try #require(samples[.noUI])
      for layout in Layout.allCases {
        let values = try #require(samples[layout])
        let busyRelative = zip(values, baseline).map { $0.busy / max($1.busy, 0.000_001) }
        let wallRelative = zip(values, baseline).map { $0.wall / max($1.wall, 0.000_001) }
        print(
          String(
            format:
              "BENCH %@ jobs=60 samples=%ld busyMedian=%.3fms wallMedian=%.3fms busyRelative=%.2fx wallRelative=%.2fx",
            layout.rawValue, Self.sampleCount, median(values.map(\.busy)) * 1000,
            median(values.map(\.wall)) * 1000, median(busyRelative), median(wallRelative)))
      }
    }

    private func run(_ layout: Layout) async throws -> MainThreadBenchMeter.Measurement {
      let root = TestScratch.directory("MainThreadBenchHosted")
      let defaults = TestScratch.defaults("MainThreadBenchHosted")
      defaults.set(true, forKey: "hasCompletedOnboarding")
      let now = Date()
      let year = Calendar.current.component(.year, from: now)
      let month = Calendar.current.component(.month, from: now)
      let service = BulkLibraryFixture.makeFakeLibrary(
        timelineAssets: 50 * 11 + 60, years: year...year,
        largeMonths: [(year: year, month: month, count: 60)])
      for assets in service.assetsByYearMonth.values {
        for asset in assets {
          service.resourcesByAssetId[asset.id] = [
            ResourceDescriptor(type: .photo, originalFilename: "IMG_\(asset.id).HEIC", fileSize: 12)
          ]
        }
      }
      let library = PhotoLibraryManager(overrideService: service)
      let timeline = ExportRecordStore(baseDirectoryURL: root)
      let collections = CollectionExportRecordStore(baseDirectoryURL: root)
      timeline.configure(for: "A")
      collections.configure(for: "A")
      let destination = FakeExportDestination()
      let snapshots = Dictionary(
        uniqueKeysWithValues: service.assetsByYearMonth.values.flatMap { $0 }.map { asset in
          (
            asset.id,
            PhotoKitAssetSnapshot(
              descriptor: asset, resources: service.resourcesByAssetId[asset.id] ?? [])
          )
        })
      let reader = ProductionPhotoKitReader { id, _ in snapshots[id] }
      let manager = ExportManager(
        photoLibraryService: service, photoKitReader: reader, exportDestination: destination,
        exportRecordStore: timeline, collectionExportRecordStore: collections,
        assetResourceWriter: PacedWriter(), fileSystem: FakeFileSystem(), userDefaults: defaults)
      let destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
      destinationManager.configureForScreenshotMode()
      let autoSync = AutoSyncManager()
      let whatsNew = WhatsNewState(userDefaults: defaults, currentVersion: "bench", catalog: [])
      whatsNew.markAsSeen()
      let counter = BodyInvalidationCounter()
      let barrier = RenderBarrier()
      var window: NSWindow?
      defer {
        manager.cancelAndClear()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        timeline.drainSynchronously()
        collections.drainSynchronously()
        destination.cleanup()
      }
      if layout != .noUI {
        let hostedWindow = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 1100, height: 800),
          styleMask: [.titled, .closable])
        let content = Group {
          switch layout {
          case .noUI: EmptyView()
          case .sidebar:
            SidebarHost(service: service, selection: [.timelineMonth(year: year, month: month)])
          case .progressBar: ExportProgressBar()
          case .grid: GridHost(library: library, year: year, month: month)
          case .fullWindow:
            MainWindowRoot(destinationManager: destinationManager, recordStore: timeline)
          }
        }
        .overlay(alignment: .bottomTrailing) { BarrierView(barrier: barrier, counter: counter) }
        .environment(library).environment(timeline).environment(collections)
        .environment(manager).environment(manager.progressState).environment(whatsNew)
        .environmentObject(destinationManager).environmentObject(autoSync)
        .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
        hostedWindow.contentView = NSHostingView(rootView: content)
        hostedWindow.orderFront(nil)
        window = hostedWindow
        try #require(await observe(in: window) { counter.count(for: "bench-barrier:0") > 0 })
        if layout == .sidebar {
          try #require(
            await observe(in: window) {
              counter.count(for: "timeline-month-body:\(year)-\(month)") > 0
            })
        } else if layout == .grid || layout == .fullWindow {
          try #require(
            await observe(in: window) {
              counter.renderedText["grid-assets"] == ["60"]
                && counter.renderedText["month-summary"] == ["0/60 exported"]
            })
        }
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = Array(counter.tasks.dropFirst(awaited))
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        timeline.flushPendingNotifications()
        collections.flushPendingNotifications()
        barrier.value += 1
        try #require(
          await observe(in: window) {
            counter.count(for: "bench-barrier:\(barrier.value)") > 0
          })
      }
      let meter = MainThreadBenchMeter()
      meter.start()
      manager.startExportMonth(year: year, month: month)
      await manager.waitForQueueDrained()
      try await timeline.flush()
      try await collections.flush()
      timeline.flushPendingNotifications()
      collections.flushPendingNotifications()
      if window != nil {
        barrier.value += 1
        try #require(
          await observe(in: window) {
            counter.count(for: "bench-barrier:\(barrier.value)") > 0
          })
      }
      let measurement = meter.stop()
      #expect(manager.totalJobsCompleted == 60)
      return measurement
    }
  }
#endif
