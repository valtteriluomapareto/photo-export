import Foundation
import Observation

/// Coalesces expensive UI queries without delaying source or preview-content observations.
@Observable
@MainActor
final class LibraryRefreshState {
  private(set) var revision = 0
  private(set) var tree: [PhotoCollectionDescriptor]?
  private(set) var years: [PhotoLibraryYearCount] = []

  @ObservationIgnored private weak var service: (any PhotoLibraryService)?
  @ObservationIgnored private let clock: any AutoSyncClock
  @ObservationIgnored private var scheduled: (any AutoSyncCancellable)?
  @ObservationIgnored private var hasPending = false
  @ObservationIgnored private var pendingChanges: [PhotoLibraryQuery: Bool]?
  @ObservationIgnored private var querySourceRevisions: [PhotoLibraryQuery: Int] = [:]
  @ObservationIgnored private var queryRevisions: [PhotoLibraryQuery: Int] = [:]
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var treeGeneration: Int?
  @ObservationIgnored private var yearsGeneration: Int?
  @ObservationIgnored private var treeTask: Task<[PhotoCollectionDescriptor], Error>?
  @ObservationIgnored private var yearsTask: Task<[PhotoLibraryYearCount], Error>?

  init(service: any PhotoLibraryService, clock: any AutoSyncClock) {
    self.service = service
    self.clock = clock
  }

  func begin(_ query: PhotoLibraryQuery) {
    if queryRevisions[query] == nil {
      queryRevisions[query] = 0
      querySourceRevisions[query] = generation
    }
  }

  func end(_ query: PhotoLibraryQuery) {
    queryRevisions.removeValue(forKey: query)
    querySourceRevisions.removeValue(forKey: query)
  }

  func sourceRevision(for query: PhotoLibraryQuery) -> Int {
    querySourceRevisions[query] ?? generation
  }

  struct QueryRevision: Equatable {
    let query: PhotoLibraryQuery
    let revision: Int
  }

  func queryRefresh(for query: PhotoLibraryQuery) -> QueryRevision {
    QueryRevision(query: query, revision: queryRevision(for: query))
  }

  func queryRevision(for query: PhotoLibraryQuery) -> Int {
    access(keyPath: \.revision)
    return queryRevisions[query] ?? 0
  }

  func invalidate(changes: [PhotoLibraryQuery: Bool]?) {
    generation &+= 1
    for query in querySourceRevisions.keys where changes?[query] != false {
      querySourceRevisions[query] = generation
    }
    treeGeneration = nil
    yearsGeneration = nil
    treeTask?.cancel()
    yearsTask?.cancel()
    treeTask = nil
    yearsTask = nil
    if !hasPending {
      pendingChanges = changes
    } else if let old = pendingChanges, let changes {
      // Missing information is unknown, so only keys known in both events can stay silent.
      pendingChanges = old.reduce(into: [:]) { merged, entry in
        if let changed = changes[entry.key] { merged[entry.key] = entry.value || changed }
      }
    } else {
      pendingChanges = nil
    }
    hasPending = true
    scheduled?.cancel()
    scheduled = clock.schedule(after: 0.5) { [weak self] in self?.flush() }
  }

  /// Also provides a deterministic boundary for callers that need the pending UI refresh now.
  func flush() {
    scheduled?.cancel()
    scheduled = nil
    guard hasPending else { return }
    hasPending = false
    let next = revision &+ 1
    for query in queryRevisions.keys where pendingChanges?[query] != false {
      queryRevisions[query] = next
    }
    pendingChanges = nil
    revision = next
  }

  func loadTree() async {
    guard let service, !Task.isCancelled else { return }
    let captured = generation
    guard treeGeneration != captured else { return }
    let task: Task<[PhotoCollectionDescriptor], Error>
    if let existing = treeTask {
      task = existing
    } else {
      task = Task { try await service.loadCollectionTree() }
      treeTask = task
    }
    let result = try? await task.value
    guard generation == captured, !Task.isCancelled, treeGeneration != captured else { return }
    treeTask = nil
    treeGeneration = captured
    if tree != result { tree = result }
  }

  func loadYears() async {
    guard let service, !Task.isCancelled else { return }
    let captured = generation
    guard yearsGeneration != captured else { return }
    let task: Task<[PhotoLibraryYearCount], Error>
    if let existing = yearsTask {
      task = existing
    } else {
      task = Task { try await service.loadYearsWithCounts() }
      yearsTask = task
    }
    let result = (try? await task.value) ?? []
    guard generation == captured, !Task.isCancelled, yearsGeneration != captured else { return }
    yearsTask = nil
    yearsGeneration = captured
    if years != result { years = result }
  }
}
