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

  /// Between `beginLaunch()` and `endLaunch()`.
  static var isLaunchInProgress: Bool { launchInterval != nil }

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

  /// Signposter for record-store load timing. Each `Configure` interval
  /// spans a load from its configure call until it is installed or
  /// discarded (for `beginConfigure(for:)`, until the store settles), so
  /// the launch + destination-switch costs of the file read, snapshot
  /// decode, JSONL replay, and counter rebuild can be read off Instruments /
  /// Console.app without a Time Profiler trace.
  /// `nonisolated` so `ConfigureSignpost.end()` can dispatch from any
  /// context — `OSSignposter` is `Sendable` and the property is an
  /// immutable `let`.
  nonisolated static let recordStoreSignposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "RecordStore")

  /// Begin a `Configure` interval for the named store. Returns a handle
  /// whose `end()` closes the interval, from any thread.
  /// The handle captures the label internally so callers don't repeat it
  /// at both call sites (`"timeline"` or `"collection"`). Each interval has
  /// its own signpost id, so the overlapping intervals of both stores and of
  /// a replaced load pair their begin and end correctly.
  static func beginConfigure(label: String) -> ConfigureSignpost {
    let state = recordStoreSignposter.beginInterval(
      "Configure", id: recordStoreSignposter.makeSignpostID(), "store=\(label)")
    return ConfigureSignpost(state: state, label: label)
  }
}

struct ConfigureSignpost: Sendable {
  fileprivate let state: OSSignpostIntervalState
  fileprivate let label: String

  func end() {
    AppDiagnostics.recordStoreSignposter.endInterval(
      "Configure", state, "store=\(label)")
  }
}
