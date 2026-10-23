import CoreFoundation
import Foundation

#if DEBUG
  /// Measures active main-run-loop time separately from the paced writer's suspended time.
  @MainActor
  final class MainThreadBenchMeter {
    struct Measurement {
      let wall: Double
      let busy: Double
    }

    private var observer: CFRunLoopObserver?
    private var startTime: UInt64 = 0
    private var turnStart: UInt64?
    private var busy: Double = 0

    func start() {
      startTime = DispatchTime.now().uptimeNanoseconds
      turnStart = startTime
      let activities =
        CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
      observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) {
        [weak self] _, activity in
        MainActor.assumeIsolated {
          guard let self else { return }
          let now = DispatchTime.now().uptimeNanoseconds
          if activity == .afterWaiting {
            self.turnStart = now
          } else if let start = self.turnStart {
            self.busy += Double(now - start) / 1_000_000_000
            self.turnStart = nil
          }
        }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() -> Measurement {
      let now = DispatchTime.now().uptimeNanoseconds
      if let turnStart { busy += Double(now - turnStart) / 1_000_000_000 }
      if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
      observer = nil
      turnStart = nil
      return Measurement(wall: Double(now - startTime) / 1_000_000_000, busy: busy)
    }
  }
#endif
