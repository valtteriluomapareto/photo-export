import Foundation

/// Called from reconciliation's detached worker; performs no record mutations.
struct ReconciliationFileChecker: ReconciliationFileChecking {
  func isFile(atPath path: String) async -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }
}
