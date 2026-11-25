import AppKit
import Photos
import os

/// Standalone `PhotoLibraryService` conformance that serves a curated synthetic
/// Photos library for marketing screenshot capture. Selected at app entry when the
/// user launches with `--screenshot-mode`.
///
/// The manager wraps this independent conformance through `overrideService`.
/// Every service requirement must be implemented here, so new requirements cannot
/// silently inherit production PhotoKit behavior during screenshot capture.
///
/// Thumbnails resolve in two tiers: first a bundled JPEG/PNG/HEIC named after
/// the asset id (looking at both the bundle root and a `screenshots/`
/// subdirectory); if no bundled file is found the service renders a colored
/// gradient placeholder so the app at least renders something usable in every
/// thumbnail slot. The bundled set today covers every id used by the curated
/// tree, so the gradient fallback only fires if a future tree change adds an
/// id without a corresponding bundled photo. Note: placeholder colors are
/// computed from `String.hashValue`, which is randomised per process — they
/// look stable within a single capture run, not across reruns.
@MainActor
final class ScreenshotPhotoLibraryService: NSObject, PhotoLibraryService, ThumbnailReading {

  // Authorization state for the curated mode. Always-authorized; the values are
  // surfaced through the (now-required) protocol properties below so the wrapping
  // `PhotoLibraryManager` can seed its observable authorization bridges.
  var authorizationStatus: PHAuthorizationStatus = .authorized
  var isAuthorized: Bool = true

  private let screenshotLogger = Logger.app(.screenshot)

  /// In-memory cache for rendered placeholder thumbnails — the gradient render is
  /// cheap but doing it on every grid scroll would still flicker. Keyed by
  /// "<assetId>|<width>x<height>".
  private var placeholderCache: [String: NSImage] = [:]

  override init() {
    super.init()
  }

  // MARK: - Curated tree

  /// Hand-built tree mirroring the bundled stock photos under
  /// `photo-export/Resources/screenshots/`. Asset counts on the descriptors
  /// don't matter — views read counts from `countAssets(in:)` /
  /// `cachedCountAssets(in:)`, which return hardcoded numbers that look
  /// plausible in marketing copy.
  ///
  /// Tree shape:
  ///   Favorites (synthetic)
  ///   Family             (top-level album, 6 photos)
  ///   Porvoo             (top-level album, 7 photos)
  ///   Summer             (top-level album, 12 photos)
  ///   Winter             (top-level album, 4 photos)
  ///   Trips/             (folder)
  ///     London           (7 photos)
  ///     Paris            (7 photos)
  ///     Tampere          (3 photos)
  ///
  /// Album descriptor ids are `album:<localIdentifier>`, the shape folder totals look up.
  ///
  /// The `Trips` folder is intentional — it showcases the folder-export
  /// feature (Cmd-click multi-select, "Export Folder" action) in marketing
  /// captures of the Collections surface.
  private static let tree: [PhotoCollectionDescriptor] = {
    let favorites = PhotoCollectionDescriptor(
      id: "favorites", localIdentifier: nil, title: "Favorites",
      kind: .favorites, pathComponents: [], children: [])
    let family = PhotoCollectionDescriptor(
      id: "album:family", localIdentifier: "family", title: "Family",
      kind: .album, pathComponents: [], children: [])
    let porvoo = PhotoCollectionDescriptor(
      id: "album:porvoo", localIdentifier: "porvoo", title: "Porvoo",
      kind: .album, pathComponents: [], children: [])
    let summer = PhotoCollectionDescriptor(
      id: "album:summer", localIdentifier: "summer", title: "Summer",
      kind: .album, pathComponents: [], children: [])
    let winter = PhotoCollectionDescriptor(
      id: "album:winter", localIdentifier: "winter", title: "Winter",
      kind: .album, pathComponents: [], children: [])
    let tripsLondon = PhotoCollectionDescriptor(
      id: "album:london", localIdentifier: "london", title: "London",
      kind: .album, pathComponents: ["Trips"], children: [])
    let tripsParis = PhotoCollectionDescriptor(
      id: "album:paris", localIdentifier: "paris", title: "Paris",
      kind: .album, pathComponents: ["Trips"], children: [])
    let tripsTampere = PhotoCollectionDescriptor(
      id: "album:tampere", localIdentifier: "tampere", title: "Tampere",
      kind: .album, pathComponents: ["Trips"], children: [])
    let trips = PhotoCollectionDescriptor(
      id: "folder:trips", localIdentifier: "trips", title: "Trips",
      kind: .folder, pathComponents: [],
      children: [tripsLondon, tripsParis, tripsTampere])
    // Surface an iCloud shared album in marketing captures so the
    // "Shared Albums" sidebar section renders with a populated grid. Reuses
    // family bundled photos via `assetIdsByAlbum["family-stream"]` — narratively
    // this is a relative's shared family stream, semantically distinct from the
    // user's own "Family" album. The descriptor's `kind == .sharedAlbum` is
    // what routes it into the Shared Albums sidebar section; the screenshot tree
    // appends it last so the partition order matches production.
    let familyStream = PhotoCollectionDescriptor(
      id: "shared-album:family-stream", localIdentifier: "family-stream",
      title: "Family stream", kind: .sharedAlbum, pathComponents: [], children: [])
    return [favorites, family, porvoo, summer, winter, trips, familyStream]
  }()

  /// Each album surfaces this many synthetic assets in the grid. The bundled
  /// photos under `photo-export/Resources/screenshots/` are reused via a modulo
  /// wrap in `bundledImageName(for:)` so the 46 files fill every album's 30
  /// tiles — a sparse 6-tile grid felt empty in marketing captures.
  ///
  /// 30 was picked so each album view scrolls (proves the grid is real, not a
  /// fixed-size mock) without dragging out unreasonably. At a typical 1440×900
  /// capture with the content column at ~520pt this is ~4 cols × ~8 rows.
  private static let assetsPerAlbum = 30

  /// Asset-id lists per album. The asset descriptors are constructed lazily so
  /// `creationDate`s can be relative to launch time (the timeline grid groups by
  /// year/month, so dates anchored to "now" keep the grid populated regardless of
  /// when the screenshots are taken).
  private static let assetIdsByAlbum: [String: [String]] = [
    "family": (1...assetsPerAlbum).map { "family-\($0)" },
    "porvoo": (1...assetsPerAlbum).map { "porvoo-\($0)" },
    "london": (1...assetsPerAlbum).map { "london-\($0)" },
    "paris": (1...assetsPerAlbum).map { "paris-\($0)" },
    "summer": (1...assetsPerAlbum).map { "summer-\($0)" },
    "winter": (1...assetsPerAlbum).map { "winter-\($0)" },
    "tampere": (1...assetsPerAlbum).map { "tampere-\($0)" },
    // Shared album reuses the `family-N` ids so it shows the same bundled
    // photos. Narratively this is a relative who's sharing their stream of
    // family photos; visually it gives the screenshot a populated grid without
    // sourcing a new image set. `assetIdsByAlbum` is the canonical name in this
    // file but the dict is also consulted for `.sharedAlbum` scopes (both cases
    // share the lookup in `fetchAssets(in:)`).
    "family-stream": (1...assetsPerAlbum).map { "family-\($0)" },
  ]

  /// How many distinct bundled photos exist for each album. The image lookup
  /// wraps modulo this count so an asset id `<album>-N` resolves to
  /// `<album>-((N-1) % count + 1)`. When you add or remove bundled photos for
  /// an album, update this dictionary too.
  private static let bundledPhotoCountByAlbum: [String: Int] = [
    "family": 6,
    "porvoo": 7,
    "london": 7,
    "paris": 7,
    "summer": 12,
    "winter": 4,
    "tampere": 3,
  ]

  /// Favorites surfaces 12 highlights mixed across the albums, interleaved so neighbouring
  /// tiles come from different albums. Low indices are each album's chosen "hero" shots.
  private static let favoriteAssetIds: [String] = [
    "summer-1", "family-1", "winter-1", "porvoo-1",
    "london-1", "summer-4", "paris-1", "tampere-1",
    "winter-2", "summer-3", "family-2", "porvoo-2",
  ]

  /// Months the timeline spans, counting the current one. Thirty reaches two years back, which
  /// the `timeline-multi-select` surface highlights.
  private static let timelineMonths = 30
  /// Photos in the current month: the grid the timeline surfaces show.
  private static let currentMonthPhotos = 12

  /// Each timeline id's month (0 is the current month, counting back) and its position in it.
  /// The albums are interleaved so a run of consecutive ids comes from different albums, and
  /// every month holds distinct photos. Family stream repeats the Family ids, so it stays out.
  /// The order puts a Summer photo first: the timeline surfaces select it for the detail pane.
  private static let timelinePlacement: [String: (monthsBack: Int, position: Int)] = {
    let albums = ["summer", "family", "winter", "porvoo", "london", "tampere", "paris"]
    let interleaved = (0..<assetsPerAlbum).flatMap { index in
      albums.compactMap { assetIdsByAlbum[$0]?[index] }
    }
    let olderMonths = timelineMonths - 1
    let perOlderMonth = (interleaved.count - currentMonthPhotos + olderMonths - 1) / olderMonths
    var placement: [String: (monthsBack: Int, position: Int)] = [:]
    for (offset, id) in interleaved.enumerated() {
      if offset < currentMonthPhotos {
        placement[id] = (0, offset)
      } else {
        let older = offset - currentMonthPhotos
        placement[id] = (1 + older / perOlderMonth, older % perOlderMonth)
      }
    }
    return placement
  }()

  /// Timeline ids keyed by `"<year>-<month>"`, in placement order.
  private static let timelineAssetsByMonth: [String: [String]] = {
    let calendar = Calendar(identifier: .gregorian)
    var byKey: [String: [(position: Int, id: String)]] = [:]
    for (id, place) in timelinePlacement {
      let date = creationDate(for: id)
      let key = "\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))"
      byKey[key, default: []].append((place.position, id))
    }
    return byKey.mapValues { $0.sorted { $0.position < $1.position }.map(\.id) }
  }()

  /// A timeline id's date: two days apart within its month, never later than now. Ids outside
  /// the timeline get now.
  private static func creationDate(for id: String) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    guard let place = timelinePlacement[id],
      let month = calendar.date(byAdding: .month, value: -place.monthsBack, to: now),
      let start = calendar.dateInterval(of: .month, for: month)?.start,
      let date = calendar.date(byAdding: .hour, value: place.position * 48 + 10, to: start)
    else { return now }
    return min(date, now)
  }

  /// Curated timeline ids for a month, or for every month of the year when `month` is nil.
  private static func timelineIds(year: Int, month: Int?) -> [String] {
    if let month { return timelineAssetsByMonth["\(year)-\(month)"] ?? [] }
    return timelineAssetsByMonth.filter { $0.key.hasPrefix("\(year)-") }.flatMap(\.value)
  }

  // MARK: - PhotoLibraryService overrides — auth

  func requestAuthorization() async -> Bool {
    isAuthorized = true
    authorizationStatus = .authorized
    return true
  }

  // MARK: - PhotoLibraryService overrides — timeline reads

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    Self.makeDescriptor(id: assetId)
  }

  nonisolated func loadYearsWithCounts() async throws -> [PhotoLibraryYearCount] {
    try await MainActor.run {
      try self.availableYearsWithCounts().map {
        PhotoLibraryYearCount(year: $0.year, count: $0.count)
      }
    }
  }

  nonisolated func loadCollectionTree() async throws -> [PhotoCollectionDescriptor] {
    await MainActor.run { Self.tree }
  }

  func availableYears() throws -> [Int] {
    let years = Set(
      Self.timelineAssetsByMonth.keys.compactMap { Int($0.split(separator: "-").first ?? "") }
    )
    return years.sorted(by: >)
  }

  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    try availableYears().map { year in
      (year: year, count: Self.timelineIds(year: year, month: nil).count)
    }
  }

  // MARK: - PhotoLibraryService overrides — collections

  private func fetchAssets(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?
  ) async throws -> [AssetDescriptor] {
    let ids: [String]
    switch scope {
    case .timeline(let year, let month):
      ids = Self.timelineIds(year: year, month: month)
    case .favorites:
      ids = Self.favoriteAssetIds
    case .album(let collectionId), .sharedAlbum(let collectionId):
      ids = Self.assetIdsByAlbum[collectionId] ?? []
    }
    return ids.map(Self.makeDescriptor(id:))
  }

  nonisolated func countAssets(in scope: PhotoFetchScope) async throws -> Int {
    // The static maps live on the main actor (the class is `@MainActor`). Re-hop
    // so the `nonisolated` contract on the protocol holds while still letting us
    // read the curated data.
    await Task { @MainActor in
      switch scope {
      case .timeline(let year, let month):
        return Self.timelineIds(year: year, month: month).count
      case .favorites:
        return Self.favoriteAssetIds.count
      case .album(let collectionId), .sharedAlbum(let collectionId):
        return Self.assetIdsByAlbum[collectionId]?.count ?? 0
      }
    }.value
  }

  nonisolated func countAdjustedAssets(in scope: PhotoFetchScope) async throws -> Int {
    let total = try await countAssets(in: scope)
    return max(0, total / 4)
  }

  // MARK: - PhotoLibraryService overrides — cached counts

  nonisolated func cachedCountAssets(in scope: PhotoFetchScope) async throws -> Int {
    try await countAssets(in: scope)
  }

  nonisolated func cachedCountAdjustedAssets(in scope: PhotoFetchScope) async throws
    -> Int
  {
    try await countAdjustedAssets(in: scope)
  }

  // MARK: - PhotoLibraryService overrides — thumbnails

  var thumbnailReader: any ThumbnailReading { self }

  func resolveAssets(ids: [String]) async -> [ThumbnailAsset] {
    ids.compactMap { fetchAssetDescriptor(for: $0) }.map(ThumbnailAsset.synthetic)
  }

  func image(for asset: ThumbnailAsset, spec: ThumbnailRequestSpec) async -> CGImage? {
    cachedDecodedThumbnail(
      for: asset.descriptor.id, quantizedSize: spec.size, deliveryMode: spec.delivery)
  }

  func preheat(start: [ThumbnailAsset], stop: [ThumbnailAsset]) async {}

  func coverThumbnails(in scope: PhotoFetchScope, limit: Int) async throws -> [ThumbnailAsset] {
    try await fetchAssets(in: scope, mediaType: nil)
      .prefix(max(0, min(limit, 4))).map(ThumbnailAsset.synthetic)
  }

  func decodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) async -> CGImage? {
    cachedDecodedThumbnail(
      for: assetId, quantizedSize: quantizedSize, deliveryMode: deliveryMode)
  }

  func cachedDecodedThumbnail(
    for assetId: String, quantizedSize: CGSize, deliveryMode: ThumbnailDeliveryMode
  ) -> CGImage? {
    guard let source = image(for: assetId, size: quantizedSize) else { return nil }
    var rect = CGRect(origin: .zero, size: source.size)
    return source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  nonisolated func fetchAssetsProgressive(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?, batchSize: Int
  ) -> AsyncThrowingStream<[AssetDescriptor], any Error> {
    AsyncThrowingStream { continuation in
      Task { @MainActor [weak self] in
        guard let self else {
          continuation.finish()
          return
        }
        do {
          let all = try await self.fetchAssets(in: scope, mediaType: mediaType)
          if !all.isEmpty { continuation.yield(all) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func requestPreview(
    for assetId: String, pixelSize: CGSize,
    onDegraded: @escaping @MainActor @Sendable (NSImage) -> Void
  ) async throws -> NSImage {
    if let image = image(for: assetId, size: pixelSize) { return image }
    throw PhotoLibraryManager.PhotoLibraryError.assetUnavailable
  }

  // MARK: - PhotoLibraryService overrides — resources / details

  func resources(for assetId: String) -> [ResourceDescriptor] {
    [
      ResourceDescriptor(
        type: .photo, originalFilename: "\(assetId).HEIC",
        fileSize: 2_400_000)
    ]
  }

  func assetDetails(for assetId: String) -> AssetDetails? {
    AssetDetails(
      originalFilename: "\(assetId).HEIC",
      fileSize: 2_400_000,
      resources: resources(for: assetId)
    )
  }

  // MARK: - Image resolution

  /// Extensions probed when resolving an asset id to a bundled image. `jpg` /
  /// `jpeg` are listed first because bundled real photos usually use JPEG
  /// resources (both extensions are common — macOS Preview's "Export As"
  /// defaults to `.jpeg`, while command-line tools tend toward `.jpg`).
  /// `heic` for direct Apple-format drops; `png` for UI-mock-style assets
  /// where PNG's lossless compression actually beats JPEG on size + quality.
  /// Mixing formats per-asset is supported — every extension is tried for
  /// every id.
  private static let bundledImageExtensions = ["jpg", "jpeg", "heic", "png"]

  /// Tier 1: bundled image (jpg / jpeg / heic / png). Tier 2: rendered gradient
  /// placeholder. Cached in memory so repeated grid scrolls don't re-render.
  ///
  /// Probes both the bundle root and a `screenshots/` subdirectory. Xcode 16's
  /// synchronized groups flatten `Resources/screenshots/*` to the bundle root
  /// by default; older Xcode setups using folder references preserve the
  /// subdirectory. Trying both keeps the lookup working regardless of which
  /// import shape the project ends up with.
  ///
  /// The asset id is wrapped via `bundledImageName(for:)` so a `family-23`
  /// asset id resolves to the bundled `family-5.jpeg` file (because there
  /// are only 6 bundled family photos and 23 % 6 == 5, then +1 for 1-based
  /// indexing). This lets 46 bundled photos populate ~240 grid tiles without
  /// the user noticing repeats unless they look hard.
  private func image(for assetId: String, size: CGSize) -> NSImage? {
    let resourceName = Self.bundledImageName(for: assetId) ?? assetId
    for ext in Self.bundledImageExtensions {
      if let url = Bundle.main.url(forResource: resourceName, withExtension: ext),
        let img = NSImage(contentsOf: url)
      {
        return img
      }
      if let url = Bundle.main.url(
        forResource: resourceName, withExtension: ext,
        subdirectory: "screenshots"),
        let img = NSImage(contentsOf: url)
      {
        return img
      }
    }
    let cacheKey = "\(assetId)|\(Int(size.width))x\(Int(size.height))"
    if let cached = placeholderCache[cacheKey] { return cached }
    let img = Self.renderPlaceholder(for: assetId, size: size)
    placeholderCache[cacheKey] = img
    return img
  }

  /// Maps an asset id like `family-23` to a bundled filename like `family-5`,
  /// wrapping the index modulo the per-album bundled-photo count. Returns nil
  /// when the id doesn't match the `<album>-<int>` shape or the album isn't
  /// in `bundledPhotoCountByAlbum` — in which case the caller falls back to
  /// looking up the literal asset id (so a future custom id can still resolve
  /// to a bundled file named after it directly).
  static func bundledImageName(for assetId: String) -> String? {
    guard let dashIdx = assetId.lastIndex(of: "-") else { return nil }
    let album = String(assetId[..<dashIdx])
    let indexStr = String(assetId[assetId.index(after: dashIdx)...])
    guard
      let index = Int(indexStr),
      index >= 1,
      let bundledCount = bundledPhotoCountByAlbum[album],
      bundledCount > 0
    else { return nil }
    let wrapped = ((index - 1) % bundledCount) + 1
    return "\(album)-\(wrapped)"
  }

  /// Draws a two-color gradient labelled with the asset id. Deterministic per id:
  /// the same id always produces the same colors. Good enough to make the grid
  /// look like a real Photos library without sourcing real photos.
  private static func renderPlaceholder(for assetId: String, size: CGSize) -> NSImage {
    let hash = abs(assetId.hashValue)
    let hue1 = CGFloat(hash % 360) / 360.0
    let hue2 = CGFloat((hash / 7) % 360) / 360.0
    let top = NSColor(
      calibratedHue: hue1, saturation: 0.55, brightness: 0.85, alpha: 1)
    let bottom = NSColor(
      calibratedHue: hue2, saturation: 0.55, brightness: 0.55, alpha: 1)
    let img = NSImage(size: size)
    img.lockFocus()
    defer { img.unlockFocus() }
    let gradient =
      NSGradient(starting: top, ending: bottom) ?? NSGradient(
        starting: .gray, ending: .darkGray)!
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: 270)
    let label = assetId as NSString
    let labelFont = NSFont.systemFont(
      ofSize: max(12, size.width * 0.06), weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: labelFont,
      .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ]
    let textSize = label.size(withAttributes: attrs)
    let textRect = NSRect(
      x: (size.width - textSize.width) / 2,
      y: (size.height - textSize.height) / 2,
      width: textSize.width, height: textSize.height)
    label.draw(in: textRect, withAttributes: attrs)
    return img
  }

  // MARK: - Descriptor factory

  private static func makeDescriptor(id: String) -> AssetDescriptor {
    // Mark ~1/4 of assets as edited so the "edited photo" indicators surface. Summing the
    // bytes keeps it stable across launches, unlike the per-process `hashValue`.
    let hasAdjustments = id.utf8.reduce(0) { $0 + Int($1) } % 4 == 0
    // The synthetic library's bundled images are JPEG / JPG; mark the UTI
    // accordingly so the HEIC→JPEG conversion feature doesn't
    // incorrectly synthesize JPEG edits for screenshot-mode assets.
    return AssetDescriptor(
      id: id,
      creationDate: creationDate(for: id),
      mediaType: .image,
      pixelWidth: 4032,
      pixelHeight: 3024,
      duration: 0,
      hasAdjustments: hasAdjustments,
      originalUTI: "public.jpeg"
    )
  }
}
