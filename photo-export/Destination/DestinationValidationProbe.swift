import Foundation

/// Complete physical validation evidence; installation and stable identity belong to MainActor.
struct DestinationValidationResult: Sendable {
  let isAvailable: Bool
  let isWritable: Bool
  let status: ExportDestinationStatus
  let fingerprint: DestinationFingerprint?
}

protocol DestinationValidationProbing: Sendable {
  func inspect(_ url: URL) -> DestinationValidationResult
}

struct ProductionDestinationValidationProbe: DestinationValidationProbing {
  func inspect(_ url: URL) -> DestinationValidationResult {
    let reachable = (try? url.checkResourceIsReachable()) == true
    let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    let writable = FileManager.default.isWritableFile(atPath: url.path)
    let status: ExportDestinationStatus =
      !reachable ? .unreachable : !directory ? .notDirectory : !writable ? .readOnly : .ready
    return DestinationValidationResult(
      isAvailable: reachable && directory, isWritable: reachable && directory && writable,
      status: status,
      fingerprint: reachable && directory
        ? DestinationFingerprint.compute(for: url)?.fingerprint : nil)
  }
}
