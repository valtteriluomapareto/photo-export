import CoreFoundation
import Foundation
import OSLog

/// Opt-in diagnostics for active export intervals. Enable with `--export-watchdog` or the
/// `exportWatchdogEnabled` preference; Release builds retain the same instrumentation.
@MainActor
final class ExportRunWatchdog {
  struct TurnCounts {
    private(set) var over16 = 0
    private(set) var over33 = 0
    private(set) var over100 = 0

    /// Thresholds are cumulative: a long turn also contributes to both shorter thresholds.
    @discardableResult
    mutating func record(milliseconds: Double) -> Bool {
      if milliseconds > 16 { over16 += 1 }
      if milliseconds > 33 { over33 += 1 }
      if milliseconds > 100 { over100 += 1 }
      return milliseconds > 100
    }
  }

  nonisolated static func isEnabled(arguments: [String], preferenceEnabled: Bool) -> Bool {
    arguments.contains("--export-watchdog") || preferenceEnabled
  }

  private let enabled: Bool
  private weak var measurements: ExportMeasurements?
  private let logger = Logger(subsystem: Logger.appSubsystem, category: "Export.Run")
  private var observer: CFRunLoopObserver?
  private var turnStart: UInt64?
  private var counts = TurnCounts()

  init(enabled: Bool = false, measurements: ExportMeasurements? = nil) {
    self.enabled = enabled
    self.measurements = measurements
  }

  func begin() {
    guard enabled, observer == nil else { return }
    counts = TurnCounts()
    turnStart = DispatchTime.now().uptimeNanoseconds
    let activities =
      CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) {
      [weak self] observer, activity in
      MainActor.assumeIsolated {
        guard let self else {
          // An observer whose owner disappeared must not remain attached to the main loop.
          if let observer { CFRunLoopObserverInvalidate(observer) }
          return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if activity == .afterWaiting {
          self.turnStart = now
        } else {
          self.finishTurn(at: now)
        }
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
  }

  func end() {
    guard let observer else { return }
    finishTurn(at: DispatchTime.now().uptimeNanoseconds)
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = nil
    logger.info(
      "Main-thread watchdog turns >16ms=\(self.counts.over16) >33ms=\(self.counts.over33) >100ms=\(self.counts.over100)"
    )
  }

  private func finishTurn(at now: UInt64) {
    guard let start = turnStart else { return }
    turnStart = nil
    measurements?.recordTurn(nanoseconds: now - start)
    let milliseconds = Double(now - start) / 1_000_000
    if counts.record(milliseconds: milliseconds) {
      logger.info(
        "Main-thread watchdog long turn duration=\(milliseconds, format: .fixed(precision: 2))ms")
    }
  }
}
