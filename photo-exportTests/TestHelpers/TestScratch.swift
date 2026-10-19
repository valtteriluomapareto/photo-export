import Darwin
import Foundation

/// Per-run scratch space for tests. Everything lives under one root,
/// `$TMPDIR/photo-export-tests/run-<pid>-<uuid>/`, removed when the test process exits;
/// roots left by processes that died first are removed on the next run's first use.
/// Each process has its own root, so concurrent runs never touch each other's files.
///
/// Preferences use absolute-path suite names inside the root, so they are stored there
/// rather than in the user's preferences folder.
enum TestScratch {
  private static let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("photo-export-tests", isDirectory: true)

  static let root: URL = {
    sweepAbandonedRoots()
    let root = parent.appendingPathComponent(
      "run-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      preconditionFailure("Cannot create the test scratch root \(root.path): \(error)")
    }
    atexit { try? FileManager.default.removeItem(at: TestScratch.root) }
    return root
  }()

  /// A unique path under the run root. It is not created, as callers expect of a fresh
  /// temporary location.
  static func directory(_ label: String) -> URL {
    root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  /// A unique preferences suite name inside the run root. Pass the same name to every
  /// `UserDefaults(suiteName:)` that should share the suite, and to
  /// `removePersistentDomain(forName:)`.
  static func suiteName(_ label: String) -> String {
    root.appendingPathComponent("\(label)-\(UUID().uuidString)").path
  }

  /// A fresh preferences suite inside the run root.
  static func defaults(_ label: String) -> UserDefaults {
    defaults(suiteName: suiteName(label))
  }

  /// Opens the suite a `suiteName(_:)` call returned, so two objects can share it or a
  /// test can reopen it. Names from anywhere else are rejected, because they would be
  /// stored in the user's preferences folder.
  static func defaults(suiteName name: String) -> UserDefaults {
    precondition(
      name.hasPrefix(root.path + "/"), "Not a TestScratch suite name: \(name)")
    return UserDefaults(suiteName: name)!
  }

  /// Removes sibling run roots whose process no longer exists. `EPERM` means the pid
  /// belongs to a live process of another user, so that root is kept.
  private static func sweepAbandonedRoots() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
    for name in names where name.hasPrefix("run-") {
      let fields = name.split(separator: "-")
      guard fields.count > 2, let pid = pid_t(fields[1]), pid != getpid() else { continue }
      if kill(pid, 0) == -1 && errno == ESRCH {
        try? fm.removeItem(at: parent.appendingPathComponent(name))
      }
    }
  }
}
