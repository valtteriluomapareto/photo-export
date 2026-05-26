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
  static let recordStoreSignposter = OSSignposter(
    subsystem: "com.valtteriluoma.photo-export",
    category: "RecordStore")

  /// Begin a `Configure` interval for the named store. Pair with
  /// `endConfigure(_:)` (typically via `defer`). `label` distinguishes the
  /// two stores in the trace: `"timeline"` or `"collection"`.
  static func beginConfigure(label: String) -> OSSignpostIntervalState {
    recordStoreSignposter.beginInterval("Configure", "store=\(label)")
  }

  static func endConfigure(_ state: OSSignpostIntervalState, label: String) {
    recordStoreSignposter.endInterval("Configure", state, "store=\(label)")
  }
}
