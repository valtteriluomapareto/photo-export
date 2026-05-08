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
final class UserDefaultsAutoExportScopeStore: AutoExportScopeProviding {
  private let userDefaults: UserDefaults
  private let logger: Logger
  private let subject: CurrentValueSubject<AutoExportScopeSelection, Never>

  static let defaultsKey = "AutoSync.scopeSelection"

  init(
    userDefaults: UserDefaults,
    logger: Logger = Logger(
      subsystem: "com.valtteriluoma.photo-export", category: "AutoSyncScopes")
  ) {
    self.userDefaults = userDefaults
    self.logger = logger
    self.subject = CurrentValueSubject(
      Self.load(from: userDefaults, logger: logger))
  }

  var scopeSelectionPublisher: AnyPublisher<AutoExportScopeSelection, Never> {
    subject.eraseToAnyPublisher()
  }

  /// Current snapshot. Settings UI reads this for checkbox state.
  var selection: AutoExportScopeSelection {
    subject.value
  }

  /// Settings UI writes through this. Persists immediately and pushes the new
  /// value to subscribers.
  func setSelection(_ selection: AutoExportScopeSelection) {
    do {
      let data = try JSONEncoder().encode(selection)
      userDefaults.set(data, forKey: Self.defaultsKey)
    } catch {
      logger.error(
        "Failed to encode scope selection: \(error.localizedDescription, privacy: .public)"
      )
    }
    subject.send(selection)
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
