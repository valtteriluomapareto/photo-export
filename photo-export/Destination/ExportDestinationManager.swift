import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import os

@MainActor
final class ExportDestinationManager: ObservableObject, ExportDestination {
  // MARK: - Published State
  @Published private(set) var selectedFolderURL: URL? {
    didSet { if selectedFolderURL != oldValue { clearDirectoryResolutions() } }
  }
  @Published private(set) var isAvailable: Bool = false {
    didSet { if !isAvailable { clearDirectoryResolutions() } }
  }
  /// `$isAvailable` for subscribers outside this type: synchronous, delivered before the
  /// value is stored, and replaying the current value (pinned by `PublisherParityTests`).
  var isAvailablePublisher: AnyPublisher<Bool, Never> { $isAvailable.eraseToAnyPublisher() }
  @Published private(set) var isWritable: Bool = false
  @Published private(set) var status: ExportDestinationStatus = .noSelection
  var statusMessage: String? { status.statusMessage }

  /// The destination's identity — the **stable logical id** plus the volume/path
  /// `DestinationFingerprint` — published as one atomic value. This replaces the former
  /// `destinationId` / `destinationFingerprint` two-`@Published` pair-write: a subscriber can
  /// no longer observe a new fingerprint paired with a stale id. Subscribers that key
  /// per-destination state MUST read `identity.stableId`; the fingerprint is advisory
  /// (identity-confidence) only. See `DestinationIdentity` and
  /// `docs/reference/architecture-conventions.md` §Destination identity.
  @Published private(set) var identity: DestinationIdentity = .unavailable {
    didSet {
      if identity.stableId != oldValue.stableId { clearDirectoryResolutions() }
    }
  }
  /// `$identity` for subscribers outside this type: synchronous, delivered before the
  /// value is stored, and replaying the current value (pinned by `PublisherParityTests`).
  var identityPublisher: AnyPublisher<DestinationIdentity, Never> {
    $identity.eraseToAnyPublisher()
  }

  /// Read-through of `identity.stableId` for synchronous callers (diagnostics, tests). This is
  /// the keying id every per-destination store uses. `nil` while the destination is
  /// unavailable, even when a stable id is persisted for reuse — the published id follows the
  /// unavailable invariant (see `validate`).
  var destinationId: String? { identity.stableId }

  private let fileSystem: any FileSystemService
  private var directoryGeneration: Int?
  private var directoryAccess: DestinationDirectoryAccess?

  private func clearDirectoryResolutions() { directoryAccess = nil }

  func resetDirectoryResolution() { clearDirectoryResolutions() }

  func prepareDirectoryResolution(generation: Int) {
    guard generation != directoryGeneration else { return }
    directoryGeneration = generation
    clearDirectoryResolutions()
  }

  func captureDirectoryAccess(generation: Int) throws -> any ExportDirectoryResolving {
    prepareDirectoryResolution(generation: generation)
    guard let root = selectedFolderURL else { throw ExportDestinationError.noSelection }
    guard isAvailable else { throw ExportDestinationError.notAvailable }
    guard isWritable else { throw ExportDestinationError.notWritable }
    if let directoryAccess { return directoryAccess }
    let access = DestinationDirectoryAccess(root: root, fileSystem: fileSystem)
    directoryAccess = access
    return access
  }

  func revalidateDirectory(_ relativePath: String) throws {
    try currentDirectoryAccess().revalidateDirectory(relativePath)
  }

  private func currentDirectoryAccess() throws -> any ExportDirectoryResolving {
    try captureDirectoryAccess(generation: directoryGeneration ?? 0)
  }

  // MARK: - Keys & Logger
  private let userDefaults: UserDefaults
  private let bookmarkDefaultsKey: String
  /// UserDefaults key for the persisted stable logical destination id, stored beside the
  /// bookmark. Survives across launches so the same destination keeps the same id even when its
  /// fingerprint drifts (network-share remount under a new path).
  private let stableIdDefaultsKey: String
  private let logger = Logger.app(.exportDestination)

  private var volumeObservers: [NSObjectProtocol] = []
  private let volumeNotificationCenter: NotificationCenter
  private let validationScopeAcquirer: ((URL) -> Bool)?
  private let validationScopeReleaser: ((URL) -> Void)?

  private let validationProbe: any DestinationValidationProbing
  private var validationGeneration = 0
  private var validationTask: Task<Void, Never>?
  private var isValidating = false
  private struct ValidationPresentation {
    let available: Bool
    let writable: Bool
    let status: ExportDestinationStatus
    let identity: DestinationIdentity
  }
  private func invalidateValidation() {
    validationGeneration += 1
    validationTask?.cancel()
    validationTask = nil
  }

  private func publishValidation(_ next: ValidationPresentation) {
    isAvailable = next.available
    isWritable = next.writable
    status = next.status
    if identity != next.identity { identity = next.identity }
  }

  /// The **persisted** stable id, kept privately across launches for reuse. Distinct from the
  /// published `identity.stableId` (the *active* id), which is `nil` while the destination is
  /// unavailable. Seeded on first successful validate of a destination that has none, reused
  /// verbatim afterwards, and refreshed only when the user explicitly picks a *different*
  /// folder (`FolderSelectionDecision.newDestination`).
  private var persistedStableId: String?

  /// Computes the destination fingerprint for a URL. Injectable so the network-share remount
  /// repro is a pure unit test — feed a drifted low-confidence fingerprint for the same folder
  /// and assert the stable id holds. Defaults to the live `URLResourceValues`-backed derivation.
  private let fingerprintProvider: ((URL) -> DestinationFingerprint?)?

  /// Gathers same-vs-different-folder evidence for an explicit pick by resolving the *stored*
  /// bookmark and comparing it against the freshly picked folder. Injectable so the
  /// re-selection rule is testable without round-tripping a real bookmark on a real URL.
  /// `nil` uses `defaultSameFolderEvidence(forPicked:)`.
  private let sameFolderEvidenceProvider: ((URL) -> SameFolderEvidence)?

  /// Resolves the decision for an ambiguous pick (stored bookmark won't resolve). Injectable
  /// so the branch is unit-testable; `nil` presents the production `NSAlert` confirmation
  /// (`resolveAmbiguousSelection(for:)`).
  private let ambiguityResolver: ((URL) -> FolderSelectionDecision)?

  /// Called when the user answers "Same Folder" for a pick that couldn't be compared with the
  /// previous destination, once the selection is saved and the folder is available. The app runs
  /// Import Existing Backup from here so the history is checked against the folder. Called
  /// synchronously after the new identity is published, so the import starts in the same
  /// main-actor turn and AutoSync waits for it instead of running first.
  var onAmbiguousSameFolderChosen: (() -> Void)?

  /// Persists a security-scoped bookmark for a URL, returning success. Injectable so the
  /// save-failure branch of `applyFolderSelection` (which must NOT drop the prior stable id) is
  /// unit-testable; `nil` uses the production `saveBookmark(for:)`.
  private let bookmarkSaver: ((URL) -> Bool)?

  /// Acquires scoped access to the *stored* bookmark URL during evidence-gathering. Injectable
  /// so the "resolves but can't be scoped" → `.ambiguous` branch is unit-testable; `nil` uses
  /// `startAccessingSecurityScopedResource()`.
  private let storedBookmarkScopeAcquirer: ((URL) -> Bool)?

  /// Reads a URL's same-session file identity during evidence-gathering. Injectable so the
  /// canonical-path fallback (file id unreadable) is unit-testable; `nil` uses
  /// `fileResourceIdentifier(of:)`.
  private let fileIdentifierProvider: ((URL) -> (any NSObjectProtocol)?)?

  /// Evidence about whether an explicitly picked folder is the same destination as the one the
  /// stored bookmark points at. Keyed on **bookmark/file identity, not path** — a network
  /// share's path is exactly the drift-prone signal, so "the path differs" must not mint a new
  /// id (that would re-introduce the duplicate re-export through the picker).
  enum SameFolderEvidence: Equatable, Sendable {
    /// Stored bookmark resolved to the same folder as the pick (e.g. re-granting access to the
    /// same backup folder after a stale-bookmark prompt). Keep the stable id.
    case sameAsStored
    /// Stored bookmark resolved to a genuinely different folder. Mint a fresh stable id.
    case differentFromStored
    /// No bookmark stored yet (first-ever selection). No fork risk; seed a fresh id.
    case noStoredBookmark
    /// The stored bookmark exists but won't resolve, so same-vs-different is unknowable. Surface
    /// a confirmation rather than silently forking.
    case ambiguous
  }

  /// The decision the selection flow applies once evidence is gathered (and any ambiguity is
  /// resolved by the user).
  enum FolderSelectionDecision: Equatable, Sendable {
    /// Re-selecting the same destination: keep the persisted stable id and the stashed legacy id
    /// so records stay keyed identically. This is the picker-path guard against duplicate
    /// re-export.
    case sameDestination
    /// A genuinely different destination (or the first-ever selection): forget the prior stable
    /// id and legacy directory so a fresh id is seeded and the directory coordinator does not
    /// migrate the previous destination's records into the new one.
    case newDestination
  }

  /// Hash of the **original** bookmark bytes captured at restore time, before any stale-bookmark
  /// refresh in `restoreBookmarkIfAvailable()` overwrites the bytes in `userDefaults`. This is
  /// the legacy `<oldId>` an upgraded user's `ExportRecords/<oldId>/` directory was named under.
  /// Without this snapshot, refreshing a stale bookmark would change the bytes in defaults, the
  /// coordinator would hash the new bytes, and the existing legacy directory would silently go
  /// missing.
  private var stashedLegacyDestinationId: String?

  // MARK: - Errors
  /// Case order sets each case's bridged `NSError` code, and so the error signatures stored
  /// in Auto Export retry state. Cases with associated values are numbered first, so adding
  /// one anywhere renumbers every case without associated values. The domain comes from the
  /// type name, so renaming or moving the type also changes every stored signature.
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
  var canExportNow: Bool { !isValidating && selectedFolderURL != nil && isAvailable && isWritable }
  /// Import only reads the backup folder — it does not require write access.
  var canImportNow: Bool { !isValidating && selectedFolderURL != nil && isAvailable }

  var exportUnavailableHelp: String { status.exportHelp }

  var destinationWarning: String? { canExportNow ? nil : status.warningMessage }

  var destinationHelp: String {
    let path = selectedFolderURL.map { "Destination: \($0.path)" }
    if status == .ready, let path { return path + " — click to change" }
    return [status.exportHelp, path].compactMap { $0 }.joined(separator: "\n")
  }

  // MARK: - Lifecycle
  init(
    skipRestore: Bool = false,
    userDefaults: UserDefaults,
    bookmarkDefaultsKey: String = "ExportDestinationBookmark",
    stableIdDefaultsKey: String = "ExportDestinationStableId",
    fingerprintProvider: ((URL) -> DestinationFingerprint?)? = nil,
    sameFolderEvidenceProvider: ((URL) -> SameFolderEvidence)? = nil,
    ambiguityResolver: ((URL) -> FolderSelectionDecision)? = nil,
    bookmarkSaver: ((URL) -> Bool)? = nil,
    storedBookmarkScopeAcquirer: ((URL) -> Bool)? = nil,
    fileIdentifierProvider: ((URL) -> (any NSObjectProtocol)?)? = nil,
    volumeNotificationCenter: NotificationCenter? = nil,
    validationScopeAcquirer: ((URL) -> Bool)? = nil,
    validationScopeReleaser: ((URL) -> Void)? = nil,
    fileSystem: any FileSystemService = FileIOService(),
    validationProbe: any DestinationValidationProbing = ProductionDestinationValidationProbe()
  ) {
    precondition(
      (validationScopeAcquirer == nil) == (validationScopeReleaser == nil),
      "Validation scope acquisition and release must be injected together")
    self.volumeNotificationCenter =
      volumeNotificationCenter ?? NSWorkspace.shared.notificationCenter
    self.validationScopeAcquirer = validationScopeAcquirer
    self.validationScopeReleaser = validationScopeReleaser
    self.fileSystem = fileSystem
    self.validationProbe = validationProbe
    self.userDefaults = userDefaults
    self.bookmarkDefaultsKey = bookmarkDefaultsKey
    self.stableIdDefaultsKey = stableIdDefaultsKey
    self.fingerprintProvider = fingerprintProvider
    self.sameFolderEvidenceProvider = sameFolderEvidenceProvider
    self.ambiguityResolver = ambiguityResolver
    self.bookmarkSaver = bookmarkSaver
    self.storedBookmarkScopeAcquirer = storedBookmarkScopeAcquirer
    self.fileIdentifierProvider = fileIdentifierProvider
    self.persistedStableId = userDefaults.string(forKey: stableIdDefaultsKey)
    if !skipRestore {
      restoreBookmarkIfAvailable()
    }
    observeVolumeChanges()
  }

  isolated deinit {
    for observer in volumeObservers {
      volumeNotificationCenter.removeObserver(observer)
    }
  }

  // MARK: - Public API

  /// Marketing-screenshot helper: puts the manager into the "destination
  /// available and writable" state with a synthetic URL whose
  /// `lastPathComponent` is the only piece the toolbar's destination indicator
  /// reads. Never called in production launches — `AppCore` calls it only for a
  /// composition with `isScreenshotMode`. Pair with
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
    setSelectedFolderForTesting(url)
  }

  func selectFolder() {
    if let url = runFolderPanel() {
      processSelectedFolder(url)
    }
  }

  /// Re-picks the previous backup after the folder chosen with "Same Folder" held none of the
  /// export history's files. The pick keeps the history and is checked again: it is never treated
  /// as a different folder, because the stored bookmark now points at the folder just rejected.
  /// Returns whether the check started: false when the user cancels the panel, or the pick
  /// couldn't be saved or isn't available.
  @discardableResult
  func selectFolderKeepingHistory() async -> Bool {
    guard let url = runFolderPanel(),
      applySelection(url, decision: .sameDestination, checkHistory: true)
    else { return false }
    let generation = validationGeneration
    await waitForValidation()
    return generation == validationGeneration && selectedFolderURL == url
      && identity.stableId != nil
  }

  /// Outcome of `useSelectedFolderAsNewDestination()`.
  enum NewDestinationOutcome: Equatable {
    /// A fresh, empty history now belongs to the folder.
    case newHistory
    /// The folder's identity is the one the history already uses, so no new history could start.
    case sameIdentity
    /// The bookmark couldn't be saved; nothing changed.
    case notSaved
  }

  /// Starts a fresh history for the selected folder, leaving the previous history in place for
  /// its own folder.
  func useSelectedFolderAsNewDestination() async -> NewDestinationOutcome {
    guard let url = selectedFolderURL else { return .notSaved }
    let previous = identity.stableId
    guard applyFolderSelection(url, decision: .newDestination) else { return .notSaved }
    let generation = validationGeneration
    await waitForValidation()
    guard generation == validationGeneration, selectedFolderURL == url else { return .notSaved }
    guard let current = identity.stableId, current != previous else { return .sameIdentity }
    return .newHistory
  }

  private func runFolderPanel() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose Export Folder"
    panel.message = "Select a folder where your photos and videos will be exported."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// Resolves the same-vs-different-folder decision for an explicitly picked folder, then
  /// applies it. Split out from `selectFolder()` (which owns the non-testable `NSOpenPanel`) so
  /// the re-selection rule can be unit-tested via the injected `sameFolderEvidenceProvider`.
  func processSelectedFolder(_ url: URL) {
    let selection = selectionDecision(for: url)
    applySelection(url, decision: selection.decision, checkHistory: selection.checkHistory)
  }

  private func selectionDecision(for url: URL) -> (
    decision: FolderSelectionDecision, checkHistory: Bool
  ) {
    let evidence = sameFolderEvidenceProvider?(url) ?? defaultSameFolderEvidence(forPicked: url)
    let decision: FolderSelectionDecision
    switch evidence {
    case .sameAsStored:
      decision = .sameDestination
    case .differentFromStored, .noStoredBookmark:
      decision = .newDestination
    case .ambiguous:
      decision = ambiguityResolver?(url) ?? resolveAmbiguousSelection(for: url)
    }
    return (decision, evidence == .ambiguous && decision == .sameDestination)
  }

  /// Applies a pick and, when `checkHistory`, asks the app to check the export history against
  /// the folder once the selection is saved and the folder is available.
  /// Returns whether the check was requested.
  @discardableResult
  private func applySelection(
    _ url: URL, decision: FolderSelectionDecision, checkHistory: Bool
  ) -> Bool {
    let applied = applyFolderSelection(url, decision: decision) { [weak self] in
      guard let self, checkHistory, self.identity.stableId != nil else { return }
      self.onAmbiguousSameFolderChosen?()
    }
    return checkHistory && applied
  }

  /// The stored bookmark won't resolve, so we can't tell whether the user re-picked the same
  /// backup folder or a new one. Ask; the first button ("Same Folder") is the default.
  private func resolveAmbiguousSelection(for url: URL) -> FolderSelectionDecision {
    let prompt = AmbiguousFolderPrompt(folderName: url.lastPathComponent)
    let alert = NSAlert()
    alert.messageText = prompt.title
    alert.informativeText = prompt.message
    alert.alertStyle = .warning
    for title in prompt.buttons { alert.addButton(withTitle: title) }
    let index =
      alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    return prompt.decision(forButtonAt: index)
  }

  func revealInFinder() {
    guard let url = selectedFolderURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func clearSelection() {
    invalidateValidation()
    let generation = validationGeneration
    isValidating = false
    stashedLegacyDestinationId = nil
    persistedStableId = nil
    userDefaults.removeObject(forKey: stableIdDefaultsKey)
    userDefaults.removeObject(forKey: bookmarkDefaultsKey)
    selectedFolderURL = nil
    guard generation == validationGeneration else { return }
    publishValidation(
      ValidationPresentation(
        available: false, writable: false, status: .noSelection, identity: .unavailable))
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
  /// Delegates to `urlForRelativeDirectory` so all placements share path validation.
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
    try currentDirectoryAccess().urlForRelativeDirectory(
      relativePath, createIfNeeded: createIfNeeded)
  }

  // MARK: - Testing Support

  /// Directly sets the folder URL for unit tests.
  func setSelectedFolderForTesting(_ url: URL) {
    invalidateValidation()
    isValidating = false
    let generation = validationGeneration
    selectedFolderURL = url
    guard generation == validationGeneration else { return }
    publishValidation(
      ValidationPresentation(
        available: true, writable: true, status: .ready, identity: identity))
  }

  #if DEBUG
    // These adapters preserve synchronous callers in the protected regression suites.
    func persistSelectedFolderForTesting(_ url: URL) {
      guard saveSelection(url, decision: .newDestination) else { return }
      revalidateForTesting()
    }

    func selectFolderForTesting(_ url: URL) {
      let selection = selectionDecision(for: url)
      _ = applySelectionForTesting(
        url, decision: selection.decision, checkHistory: selection.checkHistory)
    }

    @discardableResult
    func selectFolderKeepingHistoryForTesting(_ url: URL) -> Bool {
      applySelectionForTesting(url, decision: .sameDestination, checkHistory: true)
    }

    private func applySelectionForTesting(
      _ url: URL, decision: FolderSelectionDecision, checkHistory: Bool
    ) -> Bool {
      guard saveSelection(url, decision: decision) else { return false }
      var checked = false
      let finish = prepareValidation(url: url) { [weak self] in
        guard let self, checkHistory, self.identity.stableId != nil else { return }
        checked = true
        self.onAmbiguousSameFolderChosen?()
      }
      finish?(validationProbe.inspect(url))
      return checked
    }

    func revalidateForTesting() {
      guard let url = selectedFolderURL else { return }
      let finish = prepareValidation(url: url, onValidated: {})
      finish?(validationProbe.inspect(url))
    }
  #endif

  // MARK: - Internal Helpers

  /// Applies an explicit folder selection. The `decision` controls stable-id continuity:
  /// `.sameDestination` keeps the persisted stable id and stashed legacy id (re-grant of the
  /// same folder); `.newDestination` forgets both so a fresh id is seeded by `validate`.
  /// Returns false when the bookmark couldn't be saved and nothing changed.
  @discardableResult
  func applyFolderSelection(
    _ url: URL, decision: FolderSelectionDecision,
    onValidated: @escaping @MainActor () -> Void = {}
  ) -> Bool {
    guard saveSelection(url, decision: decision) else { return false }
    validate(url: url, onValidated: onValidated)
    return true
  }

  private func saveSelection(_ url: URL, decision: FolderSelectionDecision) -> Bool {
    logger.info(
      "User selected export folder: \(url.path, privacy: .public) (decision: \(String(describing: decision), privacy: .public))"
    )
    // Save the new bookmark FIRST. Only once it succeeds do we mutate persisted identity —
    // otherwise a failed save on a `.newDestination` pick would have already dropped the *old*
    // destination's stable id while `selectedFolderURL`/`identity` still point at it, and the
    // next validate/relaunch would reseed the old destination from a possibly-drifted
    // fingerprint and re-key its records.
    guard bookmarkSaver?(url) ?? saveBookmark(for: url) else {
      status = .bookmarkSaveFailed
      return false
    }
    switch decision {
    case .newDestination:
      // Forget the prior destination's legacy hash and stable id. Otherwise a sequence like
      // "restore folder A → user picks new folder B" would leave A's legacy hash in place; the
      // next `currentLegacyDestinationId()` call would return A's hash and the directory
      // coordinator would migrate A's records into B's `<newId>` directory — mixing
      // destinations and stranding A. Clearing the stable id lets `validate` seed a fresh one
      // for B.
      stashedLegacyDestinationId = nil
      persistedStableId = nil
      userDefaults.removeObject(forKey: stableIdDefaultsKey)
    case .sameDestination:
      // Re-granting access to the SAME folder. Keep the stable id (records stay keyed
      // identically) and the stashed legacy id (so the coordinator can still find the original
      // `ExportRecords/<oldId>/` even though the bytes were just overwritten).
      break
    }
    invalidateValidation()
    let generation = validationGeneration
    isValidating = true
    guard generation == validationGeneration else { return false }
    selectedFolderURL = url
    guard generation == validationGeneration else { return false }
    return true
  }

  /// Derives the seed for a new stable destination id from a folder URL.
  ///
  /// Delegates to `DestinationFingerprint.compute(for:)`. With a volume UUID, the digest
  /// combines that UUID and the relative path within the volume, so a mount-point rename
  /// does not change it. Without a UUID, it hashes an empty identity key and the canonical
  /// standardized path. That low-confidence fingerprint can drift across remounts; an
  /// existing destination keeps its persisted stable id instead of recomputing this seed.
  ///
  /// Returns `nil` when no usable identity component can be read (typically because the drive
  /// is unmounted). Callers treat this as "destination not yet available" and wait for the
  /// volume to mount.
  nonisolated static func computeDestinationId(for url: URL) -> String? {
    // Derives the *seed* for a fresh stable id, not a live keying read.
    DestinationFingerprint.compute(for: url)?.fingerprint.id  // keying-id-ok
  }

  /// Computes the full `DestinationFingerprint` for a folder URL. Used by code paths that need
  /// identity-confidence and the structured volume/path components in addition to the id.
  /// Returns `nil` under the same conditions as `computeDestinationId(for:)`.
  nonisolated static func computeDestinationFingerprint(for url: URL) -> DestinationFingerprint? {
    DestinationFingerprint.compute(for: url)?.fingerprint
  }

  /// Legacy destination-id derivation: SHA-256 of the security-scoped bookmark bytes.
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
  /// brand-new selection via `applyFolderSelection(_:decision:)`, with no legacy directory).
  func currentLegacyDestinationId() -> String? {
    if let stashed = stashedLegacyDestinationId { return stashed }
    guard let data = userDefaults.data(forKey: bookmarkDefaultsKey) else { return nil }
    return Self.legacyDestinationId(from: data)
  }

  /// Publishes the unavailable identity (no active stable id, no fingerprint). The *persisted*
  /// stable id is intentionally left untouched for reuse when the destination returns; only the
  /// published active id is cleared. Publishing the persisted id while unavailable would make
  /// the lifecycle coordinator see an unchanged id on unplug and skip its
  /// destination-unavailable handling.
  private func publishUnavailableIdentity() {
    if identity != .unavailable { identity = .unavailable }
  }

  /// Legacy low-confidence id for the currently selected folder. Returns the
  /// volumeIdentifier-based digest the previous code used as the record-store directory name
  /// for drives without a volume UUID; returns nil for high-confidence drives or when no
  /// folder is selected. `ExportRecordsDirectoryCoordinator` accepts this as a secondary
  /// legacy id so existing low-confidence record stores keep working across the upgrade.
  func currentPreV2LowConfidenceLegacyId() -> String? {
    guard let url = selectedFolderURL else { return nil }
    return DestinationFingerprint.preV2LowConfidenceId(for: url)
  }

  /// Default same-vs-different-folder evidence: resolve the *stored* bookmark and compare it to
  /// the freshly picked folder by **same-session file identity** (`fileResourceIdentifier`), not
  /// path. The path is the drift-prone signal a network share changes across remount, so a
  /// path comparison would re-introduce the picker-path duplicate re-export; the file identity
  /// is stable for the lifetime of the mount regardless of where it mounted. Falls back to a
  /// canonical-path comparison only when file ids are unreadable.
  private func defaultSameFolderEvidence(forPicked pickedURL: URL) -> SameFolderEvidence {
    guard let storedData = userDefaults.data(forKey: bookmarkDefaultsKey) else {
      return .noStoredBookmark
    }
    var isStale = false
    guard
      let storedURL = try? URL(
        resolvingBookmarkData: storedData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
    else {
      return .ambiguous
    }
    let acquireScope = storedBookmarkScopeAcquirer ?? { $0.startAccessingSecurityScopedResource() }
    let storedScoped = acquireScope(storedURL)
    // Only balance a real acquire with a real release; an injected acquirer didn't actually scope.
    defer {
      if storedScoped, storedBookmarkScopeAcquirer == nil {
        storedURL.stopAccessingSecurityScopedResource()
      }
    }
    // If scoped access can't be acquired (old drive unplugged / stale bookmark / sandbox-denied
    // — the normal re-grant-after-stale flow), the stored URL is not live: its resource-key and
    // path reads would be unreliable and could block on kernel I/O. Crucially, the canonical-path fallback below would then compare a dead stored
    // path against the fresh pick and, for a network share remounted at a new path, classify the
    // SAME destination as `.differentFromStored` — forking the id and re-exporting. Surface the
    // confirmation instead of guessing.
    guard storedScoped else { return .ambiguous }

    let fileId = fileIdentifierProvider ?? { Self.fileResourceIdentifier(of: $0) }
    if let storedFID = fileId(storedURL), let pickedFID = fileId(pickedURL) {
      return storedFID.isEqual(pickedFID) ? .sameAsStored : .differentFromStored
    }
    // File identity unreadable (rare). An equal canonical path is still strong evidence it's the
    // same folder (two folders can't share a canonical path), so keep `.sameAsStored`. But
    // differing paths are genuinely ambiguous: it could be a genuinely different folder OR the
    // same destination reached through a different path (the drift-prone signal). Minting a new
    // id on a path difference would reintroduce duplicate re-export, so surface the
    // confirmation instead of guessing `.differentFromStored`.
    let storedPath = storedURL.resolvingSymlinksInPath().standardizedFileURL.path
    let pickedPath = pickedURL.resolvingSymlinksInPath().standardizedFileURL.path
    return storedPath == pickedPath ? .sameAsStored : .ambiguous
  }

  /// Same-session-stable file identity for a folder URL, used to compare two URLs for
  /// "same folder" without trusting their paths. Returns `nil` when the resource value can't
  /// be read.
  private static func fileResourceIdentifier(of url: URL) -> (any NSObjectProtocol)? {
    (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
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
      status = .noSelection
      publishUnavailableIdentity()
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
      validate(url: url) { [weak self] in
        guard let self, isStale, self.isAvailable else { return }
        self.logger.info("Bookmark data is stale; refreshing now that destination validated")
        _ = self.saveBookmark(for: url)
      }
      // Refresh a stale bookmark only after `validate` confirms the URL is
      // actually accessible. The synchronous `url.bookmarkData(...)` call
      // inside `saveBookmark` blocks on kernel I/O when the underlying path
      // is unreachable or sandbox-denied, which can stall launch.
      // If the destination isn't usable, the user will be prompted
      // to re-select; the refresh happens naturally on their next selection.

    } catch {
      logger.error(
        "Failed to restore bookmark: \(String(describing: error), privacy: .public)")
      invalidateValidation()
      isValidating = false
      selectedFolderURL = nil
      publishValidation(
        ValidationPresentation(
          available: false, writable: false, status: .permissionRequired, identity: .unavailable))
      // Keep `stashedLegacyDestinationId` (set above from the *original* bytes). A failed
      // resolution is exactly when an upgrader will re-select the same folder; clearing the
      // stash here would make `currentLegacyDestinationId()` fall back to hashing the *new*
      // bookmark bytes, so the directory coordinator couldn't find the existing
      // `ExportRecords/<oldBookmarkHash>/` and would orphan the records. It is cleared only on an
      // explicit `.newDestination` selection or `clearSelection()`.
    }
  }

  func revalidate() {
    guard let url = selectedFolderURL else { return }
    validate(url: url)
  }

  func waitForValidation() async {
    while let task = validationTask {
      let generation = validationGeneration
      await task.value
      if generation == validationGeneration { return }
    }
  }

  func validate(url: URL, onValidated: @escaping @MainActor () -> Void = {}) {
    guard let finish = prepareValidation(url: url, onValidated: onValidated) else { return }
    let probe = validationProbe
    validationTask = Task {
      let result = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(returning: probe.inspect(url))
        }
      }
      finish(result)
    }
  }

  private func prepareValidation(
    url: URL, onValidated: @escaping @MainActor () -> Void
  ) -> (@MainActor (DestinationValidationResult) -> Void)? {
    invalidateValidation()
    let generation = validationGeneration
    // Keep public availability complete while queued work waits for current validation.
    isValidating = true
    let started = validationScopeAcquirer?(url) ?? url.startAccessingSecurityScopedResource()
    guard generation == validationGeneration, selectedFolderURL == url else {
      if started { releaseValidationScope(url) }
      return nil
    }
    guard started else {
      isValidating = false
      publishValidation(
        ValidationPresentation(
          available: false, writable: false, status: .permissionRequired, identity: .unavailable))
      guard generation == validationGeneration, selectedFolderURL == url else { return nil }
      onValidated()
      return nil
    }
    // Injected fingerprints are test values; production resource reads stay on the worker.
    let fingerprint = fingerprintProvider.map { $0(url) }
    let release = validationScopeReleaser
    return { [weak self] result in
      if let release { release(url) } else { url.stopAccessingSecurityScopedResource() }
      guard let self else { return }
      self.finishValidation(
        result, url: url, generation: generation, fingerprint: fingerprint,
        onValidated: onValidated)
      if self.validationGeneration == generation { self.validationTask = nil }
    }
  }

  private func releaseValidationScope(_ url: URL) {
    if let validationScopeReleaser {
      validationScopeReleaser(url)
    } else {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private func finishValidation(
    _ result: DestinationValidationResult, url: URL, generation: Int,
    fingerprint: DestinationFingerprint??, onValidated: @MainActor () -> Void
  ) {
    guard generation == validationGeneration, selectedFolderURL == url else { return }
    var nextIdentity = DestinationIdentity.unavailable
    if result.isAvailable, let fingerprint = fingerprint ?? result.fingerprint {
      if persistedStableId == nil {
        persistedStableId = fingerprint.id  // keying-id-ok: seeds a fresh stable id
        userDefaults.set(persistedStableId, forKey: stableIdDefaultsKey)
      }
      nextIdentity = DestinationIdentity(stableId: persistedStableId, fingerprint: fingerprint)
    }
    isValidating = false
    publishValidation(
      ValidationPresentation(
        available: result.isAvailable, writable: result.isWritable, status: result.status,
        identity: nextIdentity))
    guard generation == validationGeneration, selectedFolderURL == url else { return }
    onValidated()
  }

  private func observeVolumeChanges() {
    let center = volumeNotificationCenter
    let mountObs = center.addObserver(
      forName: NSWorkspace.didMountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.revalidate()
      }
    }
    let unmountObs = center.addObserver(
      forName: NSWorkspace.didUnmountNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        self.revalidate()
      }
    }
    volumeObservers = [mountObs, unmountObs]
  }
}
