import Foundation

/// Retains only active queries and prevents late fetches from replacing newer observations.
@MainActor
final class PhotoLibraryQueryObservations<Snapshot> {
  struct Ticket {
    let query: PhotoLibraryQuery
    let revision: Int
    let owner: UUID
  }

  private var consumers: [PhotoLibraryQuery: Int] = [:]
  private var owners: [PhotoLibraryQuery: UUID] = [:]
  private(set) var snapshots: [PhotoLibraryQuery: Snapshot] = [:]

  func begin(_ query: PhotoLibraryQuery) { consumers[query, default: 0] += 1 }

  func end(_ query: PhotoLibraryQuery) {
    guard let count = consumers[query] else { return }
    if count > 1 {
      consumers[query] = count - 1
    } else {
      consumers.removeValue(forKey: query)
      owners.removeValue(forKey: query)
      snapshots.removeValue(forKey: query)
    }
  }

  func isObserved(_ query: PhotoLibraryQuery) -> Bool { consumers[query] != nil }

  func ticket(for query: PhotoLibraryQuery, revision: Int) -> Ticket? {
    guard isObserved(query) else { return nil }
    let owner = UUID()
    owners[query] = owner
    return Ticket(query: query, revision: revision, owner: owner)
  }

  @discardableResult
  func install(_ snapshot: Snapshot, for ticket: Ticket, revision: Int) -> Bool {
    guard ticket.revision == revision, owners[ticket.query] == ticket.owner,
      isObserved(ticket.query)
    else { return false }
    snapshots[ticket.query] = snapshot
    return true
  }

  func changes(_ update: (Snapshot) -> (snapshot: Snapshot, affected: Bool)) -> [PhotoLibraryQuery:
    Bool]
  {
    var changed: [PhotoLibraryQuery: Bool] = [:]
    for (query, snapshot) in snapshots {
      let result = update(snapshot)
      snapshots[query] = result.snapshot
      changed[query] = result.affected
    }
    return changed
  }
}
