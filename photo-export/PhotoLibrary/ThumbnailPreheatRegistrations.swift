/// Balances the fixed thumbnail-preheat request across independent consumers.
/// Callers pair register/release batches; duplicate IDs within a batch count once.
/// Resources remain retained until the final registration releases, even when
/// the fetch cache that originally resolved them has since been cleared.
struct ThumbnailPreheatRegistrations<Resource> {
  private struct Entry {
    var count: Int = 0
    var resource: Resource?
  }

  private var entries: [String: Entry] = [:]

  init() {}

  mutating func register(_ ids: [String], resolve: (String) -> Resource?) -> [Resource] {
    var starting: [Resource] = []
    var seen: Set<String> = []
    for id in ids where seen.insert(id).inserted {
      var entry = entries[id] ?? Entry()
      entry.count += 1
      if entry.resource == nil, let resource = resolve(id) {
        entry.resource = resource
        starting.append(resource)
      }
      entries[id] = entry
    }
    return starting
  }

  mutating func release(_ ids: [String]) -> [Resource] {
    var stopping: [Resource] = []
    var seen: Set<String> = []
    for id in ids where seen.insert(id).inserted {
      guard var entry = entries[id] else { continue }
      if entry.count == 1 {
        entries.removeValue(forKey: id)
        if let resource = entry.resource { stopping.append(resource) }
      } else {
        entry.count -= 1
        entries[id] = entry
      }
    }
    return stopping
  }
}
