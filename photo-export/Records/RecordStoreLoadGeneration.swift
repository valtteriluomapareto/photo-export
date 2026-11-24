import Synchronization

/// The generation of a record store's newest load, readable off the main actor, so a load that
/// another configure has already replaced can skip decoding a history nobody will install. The
/// store's main-actor check of its own generation stays the one that decides.
final class RecordStoreLoadGeneration: Sendable {
  private let current = Mutex<UInt64>(0)

  func advance(to generation: UInt64) {
    current.withLock { $0 = generation }
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    current.withLock { $0 == generation }
  }
}
