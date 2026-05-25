import SwiftUI

#if DEBUG
  @MainActor
  final class BodyInvalidationCounter {
    static let shared = BodyInvalidationCounter()

    private var countsByKey: [String: Int] = [:]
    private init() {}

    func record(_ key: String) {
      countsByKey[key, default: 0] += 1
    }

    func count(for key: String) -> Int { countsByKey[key] ?? 0 }
    func snapshot() -> [String: Int] { countsByKey }
    func reset() { countsByKey.removeAll() }
  }
#endif

extension View {
  /// Records one body evaluation under `key`. No-op in Release.
  @MainActor
  func measureBodyInvalidations(_ key: String) -> Self {
    #if DEBUG
      BodyInvalidationCounter.shared.record(key)
    #endif
    return self
  }
}
