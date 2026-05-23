import Foundation
import os

@testable import Photo_Export

/// `DirectoryFsyncing` test double that records every directory URL passed
/// to `fsyncDirectory(_:)`. Used to prove that
/// `FileBackedAutoSyncCurrentRunStore` actually invokes the parent-directory
/// fsync after each save and clear — the load-bearing durability detail
/// that distinguishes this store from the existing run-summary store.
///
/// Sendable per the protocol contract. Uses an `OSAllocatedUnfairLock` to
/// serialise mutation because the production caller is `@MainActor` but
/// nothing forbids a future test from invoking the seam from a background
/// queue.
final class RecordingDirectoryFsync: DirectoryFsyncing, @unchecked Sendable {
  private let state = OSAllocatedUnfairLock<[URL]>(initialState: [])

  func fsyncDirectory(_ url: URL) {
    state.withLock { $0.append(url) }
  }

  var fsyncedPaths: [URL] {
    state.withLock { $0 }
  }
}
