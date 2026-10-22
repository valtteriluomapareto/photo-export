import SwiftUI

#if DEBUG
  @MainActor
  final class BodyInvalidationCounter {
    private(set) var renderedText: [String: [String]] = [:]
    private(set) var tasks: [Task<Void, Never>] = []
    private var countsByKey: [String: Int] = [:]
    private(set) var renderedActions: [String: () -> Void] = [:]
    init() {}

    func record(_ key: String) {
      countsByKey[key, default: 0] += 1
    }

    func recordText(_ text: [String], for key: String) { renderedText[key] = text }
    func recordTask(_ task: Task<Void, Never>) { tasks.append(task) }

    func count(for key: String) -> Int { countsByKey[key] ?? 0 }
    func recordAction(_ key: String, action: @escaping () -> Void) {
      renderedActions[key] = action
    }
    func snapshot() -> [String: Int] { countsByKey }
    func reset() {
      renderedText.removeAll()
      tasks.removeAll()
      countsByKey.removeAll()
      renderedActions.removeAll()
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
