import Combine
import Foundation
import os

/// Production `AutoExportScopeProviding` backed by `UserDefaults`. Persists
/// `AutoExportScopeSelection` as JSON under the key `AutoSync.scopeSelection`.
/// Defaults to all scopes off — Auto Export blocks on `.noScopesSelected` until
/// the user picks at least one in Settings → Auto Export.
///
/// Plan §"Persistence Keys": `AutoSync.scopeSelection` is a global preference,
/// not per-destination. Settings UI calls `setSelection(_:)` to write; AutoSync
/// subscribes to `scopeSelectionPublisher` to react.
@MainActor
final class UserDefaultsAutoExportScopeStore: ObservableObject, AutoExportScopeProviding {
  /// Current snapshot. Settings UI reads this for checkbox state. `@Published`
  /// so SwiftUI views observe writes; AutoSyncManager subscribes via
  /// `scopeSelectionPublisher` (the same upstream — `$selection`) so a single
  /// `setSelection(_:)` call drives both the UI re-render and the reducer
  /// dispatch.
  @Published private(set) var selection: AutoExportScopeSelection

  private let userDefaults: UserDefaults
  private let logger: Logger

  static let defaultsKey = "AutoSync.scopeSelection"

  init(
    userDefaults: UserDefaults,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncScopes")
  ) {
    self.userDefaults = userDefaults
    self.logger = logger
    self.selection = Self.load(from: userDefaults, logger: logger)
  }

  var scopeSelectionPublisher: AnyPublisher<AutoExportScopeSelection, Never> {
    $selection.eraseToAnyPublisher()
  }

  /// Settings UI writes through this. Persists immediately and pushes the new
  /// value to both UI observers and AutoSyncManager.
  func setSelection(_ selection: AutoExportScopeSelection) {
    do {
      let data = try JSONEncoder().encode(selection)
      userDefaults.set(data, forKey: Self.defaultsKey)
    } catch {
      logger.error(
        "Failed to encode scope selection: \(error.localizedDescription, privacy: .public)"
      )
    }
    self.selection = selection
  }

  private static func load(from userDefaults: UserDefaults, logger: Logger)
    -> AutoExportScopeSelection
  {
    guard let data = userDefaults.data(forKey: Self.defaultsKey) else {
      return AutoExportScopeSelection()
    }
    do {
      return try JSONDecoder().decode(AutoExportScopeSelection.self, from: data)
    } catch {
      logger.error(
        "Failed to decode scope selection at \(Self.defaultsKey, privacy: .public): \(error.localizedDescription, privacy: .public). Returning default."
      )
      return AutoExportScopeSelection()
    }
  }
}
