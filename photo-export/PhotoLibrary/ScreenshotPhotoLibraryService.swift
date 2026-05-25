import AppKit
import Photos
import os

/// Standalone `PhotoLibraryService` conformance that serves a curated synthetic
/// Photos library for marketing screenshot capture. Selected at app entry when the
/// user launches with `--screenshot-mode`; see
/// `docs/project/archive/screenshot-automation-plan.md`.
///
/// Since issue #67 item 1 this class **does not inherit from PhotoLibraryManager**;
/// it is a peer conformance the manager wraps via its `overrideService` injection
/// point. That structural fix closes the "newly-added PhotoLibraryService method
/// silently inherits production behavior" hole that the override-gate test only
/// partially caught (it pinned existing overrides but not future-added methods —
/// now every `PhotoLibraryService` method must be a real implementation here or
/// the type fails to conform).
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
final class ScreenshotPhotoLibraryService: NSObject, PhotoLibraryService {

  // Authorization state for the curated mode. Always-authorized; the values are
  // surfaced through the (now-required) protocol properties below so the wrapping
  // `PhotoLibraryManager` can mirror them onto its `@Published` properties.
  var authorizationStatus: PHAuthorizationStatus = .authorized
  var isAuthorized: Bool = true

  private let screenshotLogger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "Screenshot")

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
  ///   Trips/             (folder)
  ///     London           (7 photos)
  ///     Paris            (7 photos)
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
    let tripsLondon = PhotoCollectionDescriptor(
      id: "album:trips-london", localIdentifier: "london", title: "London",
      kind: .album, pathComponents: ["Trips"], children: [])
    let tripsParis = PhotoCollectionDescriptor(
      id: "album:trips-paris", localIdentifier: "paris", title: "Paris",
      kind: .album, pathComponents: ["Trips"], children: [])
    let trips = PhotoCollectionDescriptor(
      id: "folder:trips", localIdentifier: "trips", title: "Trips",
      kind: .folder, pathComponents: [],
      children: [tripsLondon, tripsParis])
    // Issue #48: surface an iCloud shared album in marketing captures so the
    // "Shared Albums" sidebar section renders with a populated grid. Reuses
    // family bundled photos via `assetIdsByAlbum["family-stream"]` — narratively
    // this is a relative's shared family stream, semantically distinct from the
    // user's own "Family" album. The descriptor's `kind == .sharedAlbum` is
    // what routes it into the new sidebar section in
    // `PhotoLibraryManager.fetchCollectionTree`; the screenshot tree appends it
    // last so the partition order matches production.
    let familyStream = PhotoCollectionDescriptor(
      id: "shared-album:family-stream", localIdentifier: "family-stream",
      title: "Family stream", kind: .sharedAlbum, pathComponents: [], children: [])
    return [favorites, family, porvoo, trips, familyStream]
  }()

  /// Each album surfaces this many synthetic assets in the grid. The bundled
  /// photos under `photo-export/Resources/screenshots/` are reused via a modulo
  /// wrap in `bundledImageName(for:)` so the same 27 files populate 4 × 30
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
  ]

  /// Favorites surfaces ~12 highlights mixed across the four albums so the
  /// Favorites grid looks plausibly curated (not just one photo per album).
  /// Three per album, taken from the first three indices so the bundled
  /// photos that show up here are the maintainer's chosen "hero" shots.
  private static let favoriteAssetIds: [String] = [
    "family-1", "family-2", "family-3",
    "porvoo-1", "porvoo-2", "porvoo-3",
    "london-1", "london-2", "london-3",
    "paris-1", "paris-2", "paris-3",
  ]

  /// Timeline assets bucketed by year/month. Reuses the same asset ids as the
  /// albums so a user clicking through both surfaces sees consistent thumbnails.
  /// Dates anchored to the current calendar year so the timeline tree's
  /// `availableYears` line up with reality.
  ///
  /// Album iteration order is sorted by album key so the timeline distribution
  /// is stable across launches — `Dictionary.values` is unordered, and an
  /// unordered traversal here would make "which photo lands in May 2026"
  /// non-deterministic across capture runs.
  private static let timelineAssetsByMonth: [String: [String]] = {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    var byKey: [String: [String]] = [:]
    let allIds = assetIdsByAlbum.keys.sorted().flatMap { assetIdsByAlbum[$0] ?? [] }
    for (idx, id) in allIds.enumerated() {
      // Spread across the last 18 months so the timeline year tree shows
      // multiple year and month entries. With ~120 ids and 18 months, every
      // month gets ~7 photos — a populated grid at every selection.
      let monthsBack = idx % 18
      if let date = calendar.date(byAdding: .month, value: -monthsBack, to: now) {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        byKey["\(year)-\(month)", default: []].append(id)
      }
    }
    return byKey
  }()

  // MARK: - PhotoLibraryService overrides — auth

  func requestAuthorization() async -> Bool {
    isAuthorized = true
    authorizationStatus = .authorized
    return true
  }

  // MARK: - PhotoLibraryService overrides — timeline reads

  func fetchAssets(
    year: Int, month: Int? = nil, mediaType: PHAssetMediaType? = nil
  ) async throws -> [AssetDescriptor] {
    let ids: [String]
    if let month {
      ids = Self.timelineAssetsByMonth["\(year)-\(month)"] ?? []
    } else {
      // Union of every month in the requested year.
      ids = Self.timelineAssetsByMonth
        .filter { $0.key.hasPrefix("\(year)-") }
        .flatMap { $0.value }
    }
    return ids.map(Self.makeDescriptor(id:))
  }

  func fetchAssetDescriptor(for assetId: String) -> AssetDescriptor? {
    Self.makeDescriptor(id: assetId)
  }

  func countAssets(year: Int, month: Int) throws -> Int {
    Self.timelineAssetsByMonth["\(year)-\(month)"]?.count ?? 0
  }

  func countAssets(year: Int) throws -> Int {
    Self.timelineAssetsByMonth
      .filter { $0.key.hasPrefix("\(year)-") }
      .reduce(0) { $0 + $1.value.count }
  }

  func countAdjustedAssets(year: Int, month: Int) async throws -> Int {
    // Mark ~1/4 of the month's assets as having adjustments — enough to surface
    // the "edited photo" badge in the year/month sidebar.
    let total = try countAssets(year: year, month: month)
    return max(0, total / 4)
  }

  func countAdjustedAssets(year: Int) async throws -> Int {
    let total = try countAssets(year: year)
    return max(0, total / 4)
  }

  func availableYears() throws -> [Int] {
    let years = Set(
      Self.timelineAssetsByMonth.keys.compactMap { Int($0.split(separator: "-").first ?? "") }
    )
    return years.sorted(by: >)
  }

  func availableYearsWithCounts() throws -> [(year: Int, count: Int)] {
    try availableYears().map { year in
      (year: year, count: (try? countAssets(year: year)) ?? 0)
    }
  }

  // MARK: - PhotoLibraryService overrides — collections

  func fetchCollectionTree() throws -> [PhotoCollectionDescriptor] {
    Self.tree
  }

  func fetchAssets(
    in scope: PhotoFetchScope, mediaType: PHAssetMediaType?
  ) async throws -> [AssetDescriptor] {
    let ids: [String]
    switch scope {
    case .timeline(let year, let month):
      return try await fetchAssets(year: year, month: month, mediaType: mediaType)
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
        if let month {
          return Self.timelineAssetsByMonth["\(year)-\(month)"]?.count ?? 0
        }
        return Self.timelineAssetsByMonth
          .filter { $0.key.hasPrefix("\(year)-") }
          .reduce(0) { $0 + $1.value.count }
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

  func startCachingThumbnails(for assets: [AssetDescriptor]) {
    // No-op — placeholder thumbnails are cheap to materialise on demand.
  }

  func stopCachingThumbnails(for assets: [AssetDescriptor]) {
    // No-op.
  }

  func loadThumbnail(
    for assetId: String, allowNetwork: Bool = true
  ) async -> NSImage? {
    image(for: assetId, size: CGSize(width: 256, height: 256))
  }

  func loadThumbnailHighQuality(
    for assetId: String, pixelSize: CGSize? = nil, allowNetwork: Bool = true
  ) async -> NSImage? {
    image(for: assetId, size: pixelSize ?? CGSize(width: 1024, height: 1024))
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
    let target = deliveryMode == .fast ? quantizedSize : quantizedSize
    guard let source = image(for: assetId, size: target) else { return nil }
    var rect = CGRect(origin: .zero, size: source.size)
    return source.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  func requestFullImage(for assetId: String) async throws -> NSImage {
    if let img = image(for: assetId, size: CGSize(width: 2048, height: 2048)) {
      return img
    }
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
  /// `jpeg` are listed first because the plan's size budget assumes JPEG for
  /// real photos (both extensions are common — macOS Preview's "Export As"
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
  /// indexing). This lets 27 bundled photos populate ~120 grid tiles without
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
  private static func bundledImageName(for assetId: String) -> String? {
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
    // Anchor each asset's creation date to a deterministic offset from "now" so
    // the timeline tree groups them into multiple months without being affected
    // by which day the screenshot run happens.
    let hash = abs(id.hashValue)
    let daysAgo = hash % 540  // ~18 months
    let creationDate = Calendar(identifier: .gregorian).date(
      byAdding: .day, value: -daysAgo, to: Date())
    // Mark ~1/4 of assets as edited so the "edited photo" indicators surface.
    let hasAdjustments = (hash % 4) == 0
    // The synthetic library's bundled images are JPEG / JPG; mark the UTI
    // accordingly so the HEIC→JPEG conversion feature (issue #47) doesn't
    // incorrectly synthesize JPEG edits for screenshot-mode assets.
    return AssetDescriptor(
      id: id,
      creationDate: creationDate,
      mediaType: .image,
      pixelWidth: 4032,
      pixelHeight: 3024,
      duration: 0,
      hasAdjustments: hasAdjustments,
      originalUTI: "public.jpeg"
    )
  }
}
