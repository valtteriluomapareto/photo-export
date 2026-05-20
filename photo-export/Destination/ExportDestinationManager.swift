import AppKit
import CryptoKit
import Foundation
import SwiftUI
import os

@MainActor
final class ExportDestinationManager: ObservableObject, ExportDestination {
  // MARK: - Published State
  @Published private(set) var selectedFolderURL: URL?
  @Published private(set) var isAvailable: Bool = false
  @Published private(set) var isWritable: Bool = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var destinationId: String?
  /// Structured form of the same identity carried by `destinationId`. Both are kept in sync —
  /// `destinationFingerprint?.id == destinationId` always holds *between* mutations. The
  /// two `@Published` writes are not transactional, so a subscriber to `$destinationFingerprint`
  /// that reads `destinationId` synchronously may observe a brief moment where the id has not
  /// yet caught up; downstream code should subscribe to `$destinationFingerprint` and read
  /// the id via `fingerprint?.id` to avoid the gap. All callers inside this class go through
  /// `setIdentity(fingerprint:)` so the field-pair stays consistent.
  @Published private(set) var destinationFingerprint: DestinationFingerprint?

  // MARK: - Keys & Logger
  private let userDefaults: UserDefaults
  private let bookmarkDefaultsKey: String
  private let logger = Logger(
    subsystem: "com.valtteriluoma.photo-export", category: "ExportDestination")

  private var volumeObservers: [NSObjectProtocol] = []

  /// Hash of the **original** bookmark bytes captured at restore time, before any stale-bookmark
  /// refresh in `restoreBookmarkIfAvailable()` overwrites the bytes in `userDefaults`. This is
  /// the legacy `<oldId>` an upgraded user's `ExportRecords/<oldId>/` directory was named under.
  /// Without this snapshot, refreshing a stale bookmark would change the bytes in defaults, the
  /// coordinator would hash the new bytes, and the existing legacy directory would silently go
  /// missing.
  private var stashedLegacyDestinationId: String?

  // MARK: - Errors
  enum ExportDestinationError: LocalizedError, Equatable {
    static func == (lhs: ExportDestinationError, rhs: ExportDestinationError) -> Bool {
      switch (lhs, rhs) {
      case (.noSelection, .noSelection),
        (.notAvailable, .notAvailable),
        (.notWritable, .notWritable),
        (.invalidYear, .invalidYear),
        (.invalidMonth, .invalidMonth),
        (.scopeAccessDenied, .scopeAccessDenied),
        (.pathTooLong, .pathTooLong):
        return true
      case (.notDirectory(let l), .notDirectory(let r)):
        return l == r
      case (.failedToCreateFolder(let lURL, _), .failedToCreateFolder(let rURL, _)):
        return lURL == rURL
      case (.invalidRelativePath(let l), .invalidRelativePath(let r)):
        return l == r
      default:
        return false
      }
    }
    case noSelection
    case notAvailable
    case notWritable
    case invalidYear
    case invalidMonth
    case scopeAccessDenied
    case pathTooLong
    case notDirectory(URL)
    case failedToCreateFolder(URL, underlying: Error)
    /// The relative path supplied to `urlForRelativeDirectory` was rejected at the
    /// destination boundary. The associated message names the specific failure (absolute
    /// path, `..` segment, escapes root, non-directory intermediate, etc.) so the log
    /// surfaces what to fix.
    case invalidRelativePath(String)

    var errorDescription: String? {
      switch self {
      case .noSelection: return "No export folder selected."
      case .notAvailable: return "Export folder is not reachable (drive unplugged?)."
      case .notWritable: return "Export folder is read-only."
      case .invalidYear: return "Invalid year."
      case .invalidMonth: return "Invalid month."
      case .scopeAccessDenied:
        return "Could not access the selected folder due to sandbox restrictions."
      case .pathTooLong: return "The generated export path is too long."
      case .notDirectory(let url): return "Path exists but is not a folder: \(url.path)"
      case .failedToCreateFolder(let url, let underlying):
        return "Failed to create folder at \(url.path): \(underlying.localizedDescription)"
      case .invalidRelativePath(let message):
        return "Invalid relative path: \(message)"
      }
    }
  }

  // MARK: - Public Computed
  var canExportNow: Bool { selectedFolderURL != nil && isAvailable && isWritable }
  /// Import only reads the backup folder — it does not require write access.
  var canImportNow: Bool { selectedFolderURL != nil && isAvailable }

  // MARK: - Lifecycle
  init(
    skipRestore: Bool = false,
    userDefaults: UserDefaults = .standard,
    bookmarkDefaultsKey: String = "ExportDestinationBookmark"
  ) {
    self.userDefaults = userDefaults
    self.bookmarkDefaultsKey = bookmarkDefaultsKey
    if !skipRestore {
      restoreBookmarkIfAvailable()
    }
    observeVolumeChanges()
  }

  deinit {
    for observer in volumeObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  // MARK: - Public API

  /// Marketing-screenshot helper: puts the manager into the "destination
  /// available and writable" state with a synthetic URL whose
  /// `lastPathComponent` is the only piece the toolbar's destination indicator
  /// reads. Never called in production launches —
  /// `photo_exportApp.init` gates this on
  /// `PhotoLibraryManager.isRunningInScreenshotMode`. Pair with
  /// `init(skipRestore: true)` so the user's real bookmark doesn't show up
  /// briefly before this override lands.
  ///
  /// The path prefix is junk on purpose: a real folder is not required, the
  /// safety scan and any other consumers of `selectedFolderURL.path` should
  /// treat the destination as empty (no actual files to enumerate). The
  /// destination identity is set to `nil` so the record stores stay
  /// unconfigured — screenshot launches never write export records.
  func configureForScreenshotMode(displayName: String = "Backup Folder") {
    let url = URL(
      fileURLWithPath: "/private/var/photo-export-screenshot-mode/\(displayName)",
      isDirectory: true)
    selectedFolderURL = url
    isAvailable = true
    isWritable = true
    statusMessage = nil
  }

  func selectFolder() {
    let panel = NSOpenPanel()
    panel.title = "Choose Export Folder"
    panel.message = "Select a folder where your photos and videos will be exported."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"

    if panel.runModal() == .OK, let url = panel.url {
      setSelectedFolder(url)
    }
  }

  func revealInFinder() {
    guard let url = selectedFolderURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func clearSelection() {
    selectedFolderURL = nil
    isAvailable = false
    isWritable = false
    statusMessage = "No export folder selected"
    setIdentity(nil)
    stashedLegacyDestinationId = nil
    userDefaults.removeObject(forKey: bookmarkDefaultsKey)
    logger.info("Cleared export destination selection")
  }

  /// Call before performing file operations that require access.
  /// Returns the URL that was scoped, or nil if access could not be acquired.
  /// The caller MUST pass the returned URL to `endScopedAccess(for:)` when done.
  func beginScopedAccess() -> URL? {
    guard let url = selectedFolderURL else { return nil }
    return url.startAccessingSecurityScopedResource() ? url : nil
  }

  func endScopedAccess(for url: URL) {
    url.stopAccessingSecurityScopedResource()
  }

  /// Returns the URL for the <root>/<year>/<month>/ folder, optionally creating it.
  /// Month is formatted as two digits ("01" … "12").
  ///
  /// Backed by `urlForRelativeDirectory` after Phase 3 of the collections-export plan.
  /// Year/month-specific validation (positive year, month in `1...12`) lives here; the
  /// generic destination-escape validation lives in `urlForRelativeDirectory`.
  func urlForMonth(year: Int, month: Int, createIfNeeded: Bool = true) throws -> URL {
    guard year > 0 else { throw ExportDestinationError.invalidYear }
    guard (1...12).contains(month) else { throw ExportDestinationError.invalidMonth }
    let relativePath = "\(year)/\(String(format: "%02d", month))/"
    return try urlForRelativeDirectory(relativePath, createIfNeeded: createIfNeeded)
  }

  /// Resolves a relative directory under the export root. Rejects any path that escapes
  /// the root, contains `..`/absolute-path segments, lands at or beneath a non-directory
  /// intermediate, or exceeds the platform path length.
  ///
  /// The path is split on `/`, individual components are inspected (no `.`/`..`/empty
  /// components other than a possible trailing slash), and the resolved URL is verified
  /// to lie within the canonical root using `standardizedFileURL`. Symlink escapes are
  /// caught by canonicalizing every parent that already exists on disk and asserting the
  /// canonical path still has the root as a prefix.
  func urlForRelativeDirectory(_ relativePath: String, createIfNeeded: Bool) throws -> URL {
    guard let root = selectedFolderURL else { throw ExportDestinationError.noSelection }
    guard isAvailable else { throw ExportDestinationError.notAvailable }
    guard isWritable else { throw ExportDestinationError.notWritable }
    guard !relativePath.isEmpty else {
      throw ExportDestinationError.invalidRelativePath("path is empty")
    }
    guard !relativePath.hasPrefix("/") else {
      throw ExportDestinationError.invalidRelativePath("absolute path: \(relativePath)")
    }

    // Split on forward slash. Trailing slash is allowed (collection placements include it
    // by convention); empty interior components are not (would be a `//` segment).
    let trimmed =
      relativePath.hasSuffix("/")
      ? String(relativePath.dropLast()) : relativePath
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    for component in components {
      if component.isEmpty {
        throw ExportDestinationError.invalidRelativePath(
          "empty component in path: \(relativePath)")
      }
      if component == ".." {
        throw ExportDestinationError.invalidRelativePath(
          ".. segment in path: \(relativePath)")
      }
      if component == "." {
        throw ExportDestinationError.invalidRelativePath(
          ". segment in path: \(relativePath)")
      }
    }

    // Build the target URL by appending components.
    var target = root
    for component in components {
      target = target.appendingPathComponent(component, isDirectory: true)
    }

    // Path-length guard (PATH_MAX is 1024 on macOS; reserve some headroom for the
    // filename that will be appended later).
    if target.path.utf8.count >= 1000 { throw ExportDestinationError.pathTooLong }

    // Symlink-escape protection: resolve symlinks on the deepest existing prefix and
    // verify it still lies under the root's canonical path. If the user has placed a
    // symlink at `<root>/Collections/Albums/Trip` pointing outside the destination, the
    // resolved path would not have the root as a prefix.
    let rootCanonical = root.standardizedFileURL.resolvingSymlinksInPath().path
    let targetCanonical = Self.canonicalizeExistingPrefix(of: target).path
    // Boundary-safe prefix check: a bare `hasPrefix(rootCanonical)` would let
    // `/tmp/Backup-old/Trip` slip past a root of `/tmp/Backup`. Accept either equal-to-
    // root (zero-length tail) or root-followed-by-slash. `rootCanonical` itself never
    // ends with `/` (FileManager's standardized paths drop the trailing slash) so we
    // append it explicitly here.
    let rootBoundary = rootCanonical + "/"
    if targetCanonical != rootCanonical && !targetCanonical.hasPrefix(rootBoundary) {
      throw ExportDestinationError.invalidRelativePath(
        "path resolves outside the export root: \(relativePath)")
    }

    // Verify each existing intermediate component is a directory (or doesn't exist yet,
    // in which case `ensureDirectoryExists` will create it).
    let fileManager = FileManager.default
    var probe = root
    for component in components {
      probe = probe.appendingPathComponent(component, isDirectory: true)
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: probe.path, isDirectory: &isDir) {
        if !isDir.boolValue {
          throw ExportDestinationError.notDirectory(probe)
        }
      } else {
        // Stop probing; remaining segments don't exist yet.
        break
      }
    }

    if createIfNeeded {
      try ensureDirectoryExists(at: target)
    } else {
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: target.path, isDirectory: &isDir) {
        if !isDir.boolValue { throw ExportDestinationError.notDirectory(target) }
      }
    }

    return target
  }

  /// Walks `url` upward until it finds an ancestor that exists on disk, then resolves
  /// symlinks on that ancestor to get a canonical path. The non-existing tail is
  /// re-appended so the result is still the requested URL — but with the symlink-resolved
  /// existing prefix substituted in. Used by `urlForRelativeDirectory` to detect
  /// symlink-escape attacks where a parent component is a symlink pointing outside the
  /// root.
  private static func canonicalizeExistingPrefix(of url: URL) -> URL {
    let fileManager = FileManager.default
    var components: [String] = []
    var current = url
    while !fileManager.fileExists(atPath: current.path) {
      components.insert(current.lastPathComponent, at: 0)
      let parent = current.deletingLastPathComponent()
      // Stop at the filesystem root to avoid infinite loops on malformed input.
      if parent.path == current.path { break }
      current = parent
    }
    var result = current.standardizedFileURL.resolvingSymlinksInPath()
    for component in components {
      result = result.appendingPathComponent(component, isDirectory: true)
    }
    return result
  }

  /// Ensures the directory exists at the given URL, creating with intermediates.
  func ensureDirectoryExists(at url: URL) throws {
    var isDir: ObjCBool = false
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
      if !isDir.boolValue { throw ExportDestinationError.notDirectory(url) }
      return
    }
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
      logger.info("Ensured directory: \(url.path, privacy: .public)")
    } catch {
      logger.error(
        "Failed to create directory: \(url.path, privacy: .public) error: \(String(describing: error), privacy: .public)"
      )
      throw ExportDestinationError.failedToCreateFolder(url, underlying: error)
    }
  }

  // MARK: - Testing Support

  /// Directly sets the folder URL for unit tests.
  func setSelectedFolderForTesting(_ url: URL) {
    selectedFolderURL = url
    isAvailable = true
    isWritable = true
    statusMessage = nil
  }

  /// Exercises the production bookmark save path for unit tests.
  func persistSelectedFolderForTesting(_ url: URL) {
    setSelectedFolder(url)
  }

  // MARK: - Internal Helpers
  private func setSelectedFolder(_ url: URL) {
    logger.info("User selected export folder: \(url.path, privacy: .public)")
    // Clear any stashed legacy id from a prior bookmark restore. Otherwise a sequence
    // like "restore folder A → user picks new folder B" would leave A's legacy hash in
    // place; the next `currentLegacyDestinationId()` call would return A's hash and the
    // directory coordinator would migrate A's records into B's `<newId>` directory —
    // mixing destinations and stranding A.
    stashedLegacyDestinationId = nil
    guard saveBookmark(for: url) else {
      statusMessage = "Failed to save access to selected folder"
      return
    }
    selectedFolderURL = url
    validate(url: url)
  }

  /// Derives a stable `destinationId` for a folder URL.
  ///
  /// Delegates to `DestinationFingerprint.compute(for:)`. The id is bug-for-bug compatible with
  /// the pre-Phase-0 derivation: `SHA-256(volumeUUID || U+0000 || volumeRelativePath)` for
  /// drives with a volume UUID, falling back to `String(describing: volumeIdentifier)` for
  /// drives without one (low-confidence identity). Survives bookmark refresh on the same drive
  /// and rename of the drive, since the path component is taken in the volume's coordinate
  /// system rather than the absolute mount path.
  ///
  /// Returns `nil` when no usable identity component can be read (typically because the drive
  /// is unmounted). Callers treat this as "destination not yet available" and wait for the
  /// volume to mount.
  static func computeDestinationId(for url: URL) -> String? {
    DestinationFingerprint.compute(for: url)?.fingerprint.id
  }

  /// Computes the full `DestinationFingerprint` for a folder URL. Used by code paths that need
  /// identity-confidence and the structured volume/path components in addition to the id.
  /// Returns `nil` under the same conditions as `computeDestinationId(for:)`.
  static func computeDestinationFingerprint(for url: URL) -> DestinationFingerprint? {
    DestinationFingerprint.compute(for: url)?.fingerprint
  }

  /// Pre-Phase-0 destination-id derivation: SHA-256 of the security-scoped bookmark bytes.
  /// Kept around exclusively so `ExportRecordsDirectoryCoordinator` can locate legacy
  /// `ExportRecords/<oldId>/` directories during the lazy migration.
  static func legacyDestinationId(from bookmarkData: Data) -> String {
    let digest = SHA256.hash(data: bookmarkData)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Returns the legacy `<oldId>` for the currently selected folder, or `nil` if no bookmark
  /// is stored. Used by `ExportRecordsDirectoryCoordinator` during destination configure to
  /// decide whether a legacy `ExportRecords/<oldId>/` directory needs renaming.
  ///
  /// Prefers the `stashedLegacyDestinationId` snapshot captured during
  /// `restoreBookmarkIfAvailable()` — that's the hash of the *original* bookmark bytes, which
  /// is what the upgraded user's existing `ExportRecords/<oldId>/` directory was named under.
  /// Falls back to hashing the current bookmark bytes only when no snapshot exists (e.g. a
  /// brand-new selection via `setSelectedFolder`, where there is no legacy directory anyway).
  func currentLegacyDestinationId() -> String? {
    if let stashed = stashedLegacyDestinationId { return stashed }
    guard let data = userDefaults.data(forKey: bookmarkDefaultsKey) else { return nil }
    return Self.legacyDestinationId(from: data)
  }

  /// Sets `destinationFingerprint` and `destinationId` together. Pair-write helper kept
  /// private so the class's own callers can't desynchronize the two `@Published` properties.
  /// Note: `@Published` emits one event per write, so subscribers see two emissions per
  /// call (fingerprint then id); by the time both have fired the pair is consistent. Mid-
  /// emission reads must use `$destinationFingerprint` and read `fingerprint?.id` rather
  /// than `destinationId` directly.
  private func setIdentity(_ fingerprint: DestinationFingerprint?) {
    destinationFingerprint = fingerprint
    destinationId = fingerprint?.id
  }

  /// Pre-Phase-0a low-confidence legacy id for the currently selected folder. Returns the
  /// volumeIdentifier-based digest the previous code used as the record-store directory name
  /// for drives without a volume UUID; returns nil for high-confidence drives or when no
  /// folder is selected. `ExportRecordsDirectoryCoordinator` accepts this as a secondary
  /// legacy id so existing low-confidence record stores keep working across the upgrade.
  func currentPreV2LowConfidenceLegacyId() -> String? {
    guard let url = selectedFolderURL else { return nil }
    return DestinationFingerprint.preV2LowConfidenceId(for: url)
  }

  private func saveBookmark(for url: URL) -> Bool {
    do {
      let data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      userDefaults.set(data, forKey: bookmarkDefaultsKey)
      return true
    } catch {
      logger.error(
        "Failed to create bookmark: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  private func restoreBookmarkIfAvailable() {
    guard let data = userDefaults.data(forKey: bookmarkDefaultsKey) else {
      statusMessage = "No export folder selected"
      setIdentity(nil)
      return
    }
    // Capture the legacy hash from the *original* bytes before any stale-bookmark refresh.
    // The coordinator relies on this to find existing `ExportRecords/<oldId>/` directories
    // written by previous app versions; refreshing the bookmark would otherwise change the
    // hash and silently orphan those records.
    stashedLegacyDestinationId = Self.legacyDestinationId(from: data)
    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      selectedFolderURL = url
      validate(url: url)
      // Refresh a stale bookmark only after `validate` confirms the URL is
      // actually accessible. The synchronous `url.bookmarkData(...)` call
      // inside `saveBookmark` blocks on kernel I/O when the underlying path
      // is unreachable or sandbox-denied — that's the launch beachball in
      // issue #92. If the destination isn't usable, the user will be prompted
      // to re-select; the refresh happens naturally on their next selection.
      if isStale && isAvailable {
        logger.info("Bookmark data is stale; refreshing now that destination validated")
        _ = saveBookmark(for: url)
      }
    } catch {
      logger.error(
        "Failed to restore bookmark: \(String(describing: error), privacy: .public)")
      statusMessage = "Export folder permission needs to be re-selected"
      selectedFolderURL = nil
      isAvailable = false
      isWritable = false
      setIdentity(nil)
      stashedLegacyDestinationId = nil
    }
  }

  private func validate(url: URL) {
    // Temporarily acquire access for validation
    let didStart = url.startAccessingSecurityScopedResource()
    defer { if didStart { url.stopAccessingSecurityScopedResource() } }

    // When scoped access can't be acquired — typically because the bookmark
    // is stale, sandbox-denied, or the underlying volume is unreachable —
    // every subsequent resource-key read and FileManager call on this URL
    // would block on the kernel I/O timeout. Bail out instead: publish
    // unavailable state and let the user re-select. Issue #92.
    guard didStart else {
      isAvailable = false
      isWritable = false
      statusMessage = "Export folder permission needs to be re-selected"
      setIdentity(nil)
      return
    }

    // Check reachability
    var reachable = false
    do {
      reachable = try url.checkResourceIsReachable()
    } catch {
      reachable = false
    }

    // Ensure it is a directory
    let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
    let isDirectory = resourceValues?.isDirectory == true

    // Determine writability (best-effort)
    let writable = FileManager.default.isWritableFile(atPath: url.path)

    isAvailable = reachable && isDirectory
    isWritable = isAvailable && writable

    if !isDirectory {
      statusMessage = "Selected path is not a folder"
    } else if !reachable {
      statusMessage = "Export folder is not reachable (drive unplugged?)"
    } else if !writable {
      statusMessage = "Export folder is read-only"
    } else {
      statusMessage = nil
    }

    // Derive the stable fingerprint once the volume is reachable. When the drive is
    // unmounted, volume-resource keys are unreadable; clear both the id and the fingerprint
    // so the rest of the app treats the destination as unavailable until the drive comes back.
    if isAvailable {
      setIdentity(Self.computeDestinationFingerprint(for: url))
    } else {
      setIdentity(nil)
    }
  }

  private func observeVolumeChanges() {
    let center = NSWorkspace.shared.notificationCenter
    let mountObs = center.addObserver(
      forName: NSWorkspace.didMountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        guard let url = self.selectedFolderURL else { return }
        self.validate(url: url)
      }
    }
    let unmountObs = center.addObserver(
      forName: NSWorkspace.didUnmountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        guard let url = self.selectedFolderURL else { return }
        self.validate(url: url)
      }
    }
    volumeObservers = [mountObs, unmountObs]
  }
}
