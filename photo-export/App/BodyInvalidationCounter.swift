import SwiftUI

#if DEBUG
  /// Per-host numeric budget/lifecycle measurements and owned task handles.
  @MainActor
  final class BodyInvalidationCounter {
    private(set) var tasks: [Task<Void, Never>] = []
    private var countsByKey: [String: Int] = [:]
    init() {}

    func record(_ key: String) {
      countsByKey[key, default: 0] += 1
    }

    func recordTask(_ task: Task<Void, Never>) { tasks.append(task) }

    func count(for key: String) -> Int { countsByKey[key] ?? 0 }
    func snapshot() -> [String: Int] { countsByKey }
    func reset() {
      tasks.removeAll()
      countsByKey.removeAll()
    }
  }

  private struct BodyInvalidationCounterKey: EnvironmentKey {
    static let defaultValue: BodyInvalidationCounter? = nil
  }

  extension EnvironmentValues {
    /// Optional instrumentation owned by the hosted view under test.
    var bodyInvalidationCounter: BodyInvalidationCounter? {
      get { self[BodyInvalidationCounterKey.self] }
      set { self[BodyInvalidationCounterKey.self] = newValue }
    }
  }
#endif
