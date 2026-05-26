import Foundation
import os

/// Process-level `OSSignposter` channel for app launch and sidebar
/// selection events. Shares the `com.valtteriluoma.photo-export` subsystem
/// with the existing catch-up signposter so Instruments groups them.
@MainActor
enum AppDiagnostics {
  static let signposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "AppLifecycle")

  private static var launchInterval: OSSignpostIntervalState?

  static func beginLaunch() {
    guard launchInterval == nil else { return }
    launchInterval = signposter.beginInterval("AppLaunch")
  }

  static func endLaunch() {
    if let state = launchInterval {
      signposter.endInterval("AppLaunch", state)
      launchInterval = nil
    }
  }

  /// `kind` is the short tag for the new selection: `"month"`, `"year"`,
  /// `"favorites"`, `"album"`, `"sharedAlbum"`, `"folder"`, or `"none"`.
  static func selectionChanged(kind: String) {
    signposter.emitEvent("SelectionChanged", "kind=\(kind)")
  }

  /// Signposter for record-store load timing. Wraps each
  /// `configure(for:)` body so the launch + destination-switch costs of
  /// snapshot decode, JSONL replay, and counter rebuild can be read off
  /// Instruments / Console.app without a Time Profiler trace.
  /// `nonisolated` so `ConfigureSignpost.end()` can dispatch from any
  /// context — `OSSignposter` is `Sendable` and the property is an
  /// immutable `let`.
  nonisolated static let recordStoreSignposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "RecordStore")

  /// Begin a `Configure` interval for the named store. Returns a handle
  /// whose `end()` closes the interval — typically called from a `defer`.
  /// The handle captures the label internally so callers don't repeat it
  /// at both call sites (`"timeline"` or `"collection"`).
  static func beginConfigure(label: String) -> ConfigureSignpost {
    let state = recordStoreSignposter.beginInterval("Configure", "store=\(label)")
    return ConfigureSignpost(state: state, label: label)
  }
}

struct ConfigureSignpost {
  fileprivate let state: OSSignpostIntervalState
  fileprivate let label: String

  func end() {
    AppDiagnostics.recordStoreSignposter.endInterval(
      "Configure", state, "store=\(label)")
  }
}
