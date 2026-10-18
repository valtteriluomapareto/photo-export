import Foundation

/// Bounds pending UI-change latency without postponing notification during continuous writes.
/// Persistence barriers are independent; terminal owners explicitly flush pending changes.
@MainActor
final class RecordStoreChangeNotifier {
  private let clock: any AutoSyncClock
  private let notify: () -> Void
  private var pending: (any AutoSyncCancellable)?

  init(clock: any AutoSyncClock, notify: @escaping () -> Void) {
    self.clock = clock
    self.notify = notify
  }

  func schedule() {
    guard pending == nil else { return }
    pending = clock.schedule(after: 0.2) { [weak self] in
      guard let self else { return }
      self.pending = nil
      self.notify()
    }
  }

  /// Replaces a pending window with an immediate publication of the current state.
  func notifyNow() {
    pending?.cancel()
    pending = nil
    notify()
  }

  /// No publication when there have been no changes since the previous notification.
  func flushPending() {
    guard pending != nil else { return }
    notifyNow()
  }
}
