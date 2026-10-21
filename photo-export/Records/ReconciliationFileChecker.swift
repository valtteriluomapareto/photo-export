import Darwin
import Foundation

/// Called from reconciliation's detached worker; performs no record mutations.
struct ReconciliationFileChecker: ReconciliationFileChecking {
  func isFile(atPath path: String) async throws -> Bool {
    var metadata = stat()
    guard stat(path, &metadata) == 0 else {
      let code = errno
      if code == ENOENT || code == ENOTDIR { return false }
      throw ReconciliationVerificationError(path: path, detail: String(cString: strerror(code)))
    }
    guard metadata.st_mode & S_IFMT == S_IFREG else {
      throw ReconciliationVerificationError(path: path, detail: "The target is not a regular file")
    }
    return true
  }

  func validateRoot(atPath path: String) async throws {
    do {
      _ = try FileManager.default.contentsOfDirectory(atPath: path)
    } catch {
      throw ReconciliationVerificationError(path: path, detail: error.localizedDescription)
    }
  }

  /// Reject unusable history instead of inventing a probe path or deleting it.
  static func filePath(
    root: URL, placement: ExportPlacement, filename: String?, subfolder: String?
  ) throws -> String {
    func safeComponent(_ value: String) -> Bool {
      !value.isEmpty && value != "." && value != ".." && !value.contains("/")
        && !value.contains("\0")
    }
    let relative = placement.relativePath
    guard let filename, safeComponent(filename), !relative.isEmpty, relative.hasSuffix("/"),
      !relative.hasPrefix("/"), !relative.contains("\0"),
      relative.split(separator: "/").allSatisfy({ safeComponent(String($0)) }),
      subfolder.map(safeComponent) ?? true
    else {
      throw ReconciliationVerificationError(
        path: root.path, detail: "History contains an invalid file location")
    }
    if placement.kind == .timeline {
      guard let date = placement.timelineYearMonth, (1...9999).contains(date.year),
        (1...12).contains(date.month)
      else {
        throw ReconciliationVerificationError(
          path: root.path, detail: "History contains an invalid month")
      }
    }
    let path = ExportMediaPathPolicy.relativePath(placement: placement, subfolder: subfolder)
    return root.appendingPathComponent(path).appendingPathComponent(filename).path
  }
}

struct ReconciliationVerificationError: LocalizedError {
  let path: String
  let detail: String
  var errorDescription: String? {
    "Could not verify \(path): \(detail). History for this check was kept."
  }
}
