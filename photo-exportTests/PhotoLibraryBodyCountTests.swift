import AppKit
import Photos
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(2)))
  struct PhotoLibraryBodyCountTests {
    private static let targetSize = CGSize(width: 256, height: 256)

    private struct Grid: View {
      let assets: [AssetDescriptor]
      var body: some View {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(100), spacing: 0), count: 6), spacing: 0
        ) {
          ForEach(assets) { asset in
            ThumbnailView(asset: asset, isSelected: false, isExported: true)
              .frame(width: 100, height: 100)
          }
        }.frame(width: 600, height: 1000)
      }
    }

    private struct LibraryProbe: View {
      let library: PhotoLibraryManager
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record(
          "library-probe:\(library.libraryRevision):\(library.authorizationStatus.rawValue)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    private enum Pixel { case blue, green, white }

    private static func image(_ color: NSColor) -> CGImage {
      let context = CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
      return context.makeImage()!
    }

    @MainActor
    private final class Fixture {
      let service = FakePhotoLibraryService()
      let library: PhotoLibraryManager
      let counter = BodyInvalidationCounter()
      let assets = (0..<60).map { TestAssetFactory.makeAsset(id: "asset-\($0)") }
      let window: NSWindow
      var hq = PhotoLibraryBodyCountTests.image(.blue)

      init() {
        library = PhotoLibraryManager(overrideService: service)
        let fast = PhotoLibraryBodyCountTests.image(.red)
        window = HostedViewHarness.makeWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 1000),
          styleMask: [.borderless])
        service.decodedThumbnailOverride = { [weak self] _, _, mode in
          mode == .fast ? fast : self?.hq
        }
        window.contentView = NSHostingView(
          rootView: Grid(assets: assets)
            .overlay(alignment: .topLeading) { LibraryProbe(library: library, counter: counter) }
            .environment(library).environment(\.bodyInvalidationCounter, counter))
        window.orderFront(nil)
      }

      func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        service.decodedThumbnailOverride = nil
        library.decodedThumbnailCache.clear()
      }

      /// Samples the actual mounted cell images after layout, independently of cache insertion.
      func pixels(blue: Int, green: Int, white: Int) -> Bool {
        guard let view = window.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var counts: [Pixel: Int] = [:]
        for row in 0..<10 {
          for column in 0..<6 {
            let x = (column * 100 + 50) * bitmap.pixelsWide / 600
            let y = (row * 100 + 50) * bitmap.pixelsHigh / 1000
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
              return false
            }
            let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
            if blue > red + 0.3 && blue > green + 0.3 { counts[.blue, default: 0] += 1 }
            if green > red + 0.3 && green > blue + 0.3 { counts[.green, default: 0] += 1 }
            if min(red, green, blue) > 0.6 && max(red, green, blue) - min(red, green, blue) < 0.1 {
              counts[.white, default: 0] += 1
            }
          }
        }
        return counts[.blue, default: 0] == blue && counts[.green, default: 0] == green
          && counts[.white, default: 0] == white
      }

      func cached(_ ids: [String], image: CGImage) -> Bool {
        ids.allSatisfy {
          library.cachedDecodedThumbnail(
            for: $0, quantizedSize: PhotoLibraryBodyCountTests.targetSize,
            deliveryMode: .highQuality) === image
        }
      }

      func bodies() -> [String: Int] {
        Dictionary(
          uniqueKeysWithValues: assets.map {
            ($0.id, counter.count(for: "thumbnail-body:\($0.id)"))
          })
      }

      func deltas(from before: [String: Int]) -> [String: Int] {
        bodies().reduce(into: [:]) { result, entry in
          result[entry.key] = entry.value - before[entry.key, default: 0]
        }
      }

      func quiesce() async {
        var awaited = 0
        while awaited < counter.tasks.count {
          let pending = counter.tasks[awaited...]
          awaited = counter.tasks.count
          for task in pending { _ = await finished(task) }
        }
        window.contentView?.layoutSubtreeIfNeeded()
      }

      func hqCalls() -> [String: Int] {
        service.decodedThumbnailCalls.filter { $0.deliveryMode == .highQuality }.reduce(into: [:]) {
          $0[$1.assetId, default: 0] += 1
        }
      }
    }

    /// Unrelated publications do not invalidate cells. A reload can render for invalidation,
    /// the fast image and the high-quality image, so it has at most three body evaluations.
    @Test func thumbnailCellsRenderOnlyForTheirContent() async throws {
      let f = Fixture()
      defer { f.close() }
      let ids = f.assets.map(\.id)
      try #require(
        await observe(in: f.window) {
          f.bodies().values.allSatisfy { $0 > 0 } && f.cached(ids, image: f.hq)
            && f.pixels(blue: 60, green: 0, white: 0)
        })
      await f.quiesce()
      var before = f.bodies()
      let originalCalls = f.hqCalls()

      f.library.invalidateCache(changedThumbnailAssetIDs: [])
      try #require(await observe(in: f.window) { f.counter.count(for: "library-probe:1:3") > 0 })
      await f.quiesce()
      let emptyDeltas = f.deltas(from: before)
      #expect(emptyDeltas.values.allSatisfy { $0 <= 1 }, "Empty-ID deltas: \(emptyDeltas)")
      #expect(f.hqCalls() == originalCalls)
      #expect(emptyDeltas.values.allSatisfy { $0 == 0 })
      before = f.bodies()

      f.service.authorizationStatus = .limited
      f.service.isAuthorized = true
      #expect(await f.library.requestAuthorization())
      try #require(await observe(in: f.window) { f.counter.count(for: "library-probe:1:4") > 0 })
      await f.quiesce()
      let statusDeltas = f.deltas(from: before)
      #expect(statusDeltas.values.allSatisfy { $0 <= 1 }, "Status-only deltas: \(statusDeltas)")
      #expect(f.hqCalls() == originalCalls)
      #expect(statusDeltas.values.allSatisfy { $0 == 0 })
      before = f.bodies()

      f.hq = Self.image(.green)
      f.library.invalidateCache(changedThumbnailAssetIDs: ["asset-3"])
      try #require(
        await observe(in: f.window) {
          f.counter.count(for: "library-probe:2:4") > 0 && f.cached(["asset-3"], image: f.hq)
            && f.pixels(blue: 59, green: 1, white: 0)
        })
      await f.quiesce()
      let knownDeltas = f.deltas(from: before)
      let nonReloaders = knownDeltas.filter { $0.key != "asset-3" }
      // The shared content revision invalidates each reader once; unchanged task identities
      // keep every other cell's decoded image and do not issue another HQ request.
      #expect(nonReloaders.values.allSatisfy { $0 <= 1 }, "Unchanged-cell deltas: \(nonReloaders)")
      #expect(knownDeltas["asset-3", default: 0] <= 3, "Edited-cell deltas: \(knownDeltas)")
      var expectedCalls = originalCalls
      expectedCalls["asset-3", default: 0] += 1
      #expect(f.hqCalls() == expectedCalls)
      before = f.bodies()

      f.hq = Self.image(.white)
      f.library.invalidateCache()
      try #require(
        await observe(in: f.window) {
          f.counter.count(for: "library-probe:3:4") > 0 && f.cached(ids, image: f.hq)
            && f.pixels(blue: 0, green: 0, white: 60)
        })
      await f.quiesce()
      let globalDeltas = f.deltas(from: before)
      #expect(globalDeltas.values.allSatisfy { $0 <= 3 }, "Global reload deltas: \(globalDeltas)")
      for id in ids { expectedCalls[id, default: 0] += 1 }
      #expect(f.hqCalls() == expectedCalls)
      let measurements = [
        "empty": emptyDeltas, "status": statusDeltas, "known": knownDeltas, "global": globalDeltas,
      ]
      Attachment.record(
        try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]),
        named: "thumbnail-body-counts.json")
    }
  }
#endif
