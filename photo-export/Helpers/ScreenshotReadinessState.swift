import Foundation

/// Pure capture readiness bookkeeping. A completion only retires its own work token.
struct ScreenshotReadinessState {
  var contentReady = false
  var windowID: Int?
  private(set) var generation = 0
  private(set) var pending: [UUID: String] = [:]

  var canLayout: Bool { contentReady && (windowID ?? 0) > 0 && pending.isEmpty }

  mutating func begin(_ label: String) -> UUID {
    let token = UUID()
    pending[token] = label
    generation += 1
    return token
  }

  mutating func finish(_ token: UUID) {
    if pending.removeValue(forKey: token) != nil { generation += 1 }
  }

  mutating func invalidateLayout() { generation += 1 }
}
