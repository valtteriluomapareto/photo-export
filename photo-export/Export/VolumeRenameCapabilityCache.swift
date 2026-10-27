import AppKit
import Foundation
import os

/// Capability answers belong to a mounted volume and expire when the mount table changes.
final class VolumeRenameCapabilityCache: Sendable {
  static let shared = VolumeRenameCapabilityCache()
  private struct State {
    var generation: UInt64 = 0
    var values: [String: Bool] = [:]
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  // Observer tokens never escape this lock; callbacks use the separate capability-state lock.
  private let subscriptions = OSAllocatedUnfairLock(
    uncheckedState: [(NotificationCenter, NSObjectProtocol)]())
  private let identity: @Sendable (URL) -> String?
  private let probe: @Sendable (URL) -> Bool?

  init(
    identity: @escaping @Sendable (URL) -> String? = { FileIOService.mountedVolumeIdentity($0) },
    probe: @escaping @Sendable (URL) -> Bool? = FileIOService.probeExclusiveRename
  ) {
    self.identity = identity
    self.probe = probe
  }

  func supportsExclusiveRename(in directory: URL) -> Bool {
    guard let volume = identity(directory) else { return probe(directory) ?? false }
    let lookup = state.withLock { ($0.generation, $0.values[volume]) }
    if let cached = lookup.1 { return cached }
    guard let supported = probe(directory) else { return false }
    guard identity(directory) == volume else { return false }
    return state.withLock {
      guard $0.generation == lookup.0 else { return false }
      $0.values[volume] = supported
      return supported
    }
  }

  func invalidate() {
    state.withLock {
      $0.generation &+= 1
      $0.values.removeAll()
    }
  }

  func observeMounts(in center: NotificationCenter) {
    subscriptions.withLock {
      guard $0.isEmpty else { return }
      for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.invalidate()
        }
        $0.append((center, token))
      }
    }
  }

  deinit {
    subscriptions.withLock { subscriptions in
      for (center, token) in subscriptions { center.removeObserver(token) }
    }
  }

}
