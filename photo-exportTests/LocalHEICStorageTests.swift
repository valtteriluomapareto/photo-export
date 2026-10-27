import Darwin
import Foundation
import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(2)))
struct LocalHEICStorageTests {
  @Test(arguments: [Int64(0), 1_048_575, 1_048_576, 2_097_152])
  func capacityIsCheckedBeforeAdmittingAnInput(available: Int64) async throws {
    let root = TestScratch.directory("LocalHEICStorage")
    let storage = LocalHEICStorage(root: root, capacity: { _ in available })
    if available < 1_048_576 {
      await #expect(throws: LocalHEICStorage.Failure.self) {
        try await storage.allocate(sourceBytes: nil)
      }
    } else {
      let url = try await storage.allocate(sourceBytes: nil)
      #expect(url.path.hasPrefix(root.path + "/"))
      #expect(url.lastPathComponent.hasSuffix(".heic-source"))
      await storage.remove(url)
    }
  }

  @Test func unknownCapacityDoesNotClaimTheDiskIsFull() async throws {
    let storage = LocalHEICStorage(
      root: TestScratch.directory("LocalHEICUnknownCapacity"), capacity: { _ in nil })
    let first = try await storage.allocate(sourceBytes: -1)
    let second = try await storage.allocate(sourceBytes: nil)
    #expect(first != second)
    try Data("source".utf8).write(to: first)
    await storage.remove(first)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    await storage.remove(second)
  }

  @Test func knownSourceSizeRaisesTheCapacityRequirement() async throws {
    let storage = LocalHEICStorage(
      root: TestScratch.directory("LocalHEICKnownSize"), capacity: { _ in 2_097_152 })
    await #expect(throws: LocalHEICStorage.Failure.self) {
      try await storage.allocate(sourceBytes: 2_097_153)
    }
    let url = try await storage.allocate(sourceBytes: 2_097_152)
    await storage.remove(url)
  }

  @Test func sweepPreservesLiveUnknownAndUnrelatedEntries() async throws {
    let root = TestScratch.directory("LocalHEICSweep")
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    func owner(_ pid: Int32) -> URL {
      root.appendingPathComponent("process-\(pid)-\(UUID().uuidString)")
    }
    let dead = owner(101)
    let live = owner(102)
    let current = owner(103)
    let other = root.appendingPathComponent("unrelated")
    let outside = TestScratch.directory("LocalHEICOutside")
    for dir in [dead, live, current, other, outside] {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: dir.appendingPathComponent("input"))
    }
    let link = owner(101)
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    let storage = LocalHEICStorage(
      root: root, processID: 103, capacity: { _ in nil }, processIsAlive: { $0 != 101 })
    let allocated = try await storage.allocate(sourceBytes: nil)
    #expect(fm.fileExists(atPath: dead.path), "Allocation must leave launch sweeping alone")
    for dir in [live, current, other, outside, link] {
      #expect(fm.fileExists(atPath: dir.appendingPathComponent("input").path))
    }
    await storage.sweepAbandoned()
    #expect(!fm.fileExists(atPath: dead.path))
    #expect(fm.fileExists(atPath: allocated.deletingLastPathComponent().path))
    await storage.remove(allocated)
  }

  @Test func localErrorsRetainLocalProvenance() {
    let local = LocalHEICStorage.localizing(
      NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
    let signal = AutoSyncFailureCategory.classify(local)
    #expect(signal.category == .unknown)
    #expect(signal.localizedDescription.contains("local temporary storage"))
    for code in [ENOSPC, EPERM, ENOENT] {
      let wrapped = NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
      let signal = AutoSyncFailureCategory.classify(LocalHEICStorage.localizing(wrapped))
      #expect(signal.category == .unknown)
      #expect(signal.localizedDescription.contains("local temporary storage"))
    }
    let cloud = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(
      AutoSyncFailureCategory.classify(LocalHEICStorage.localizing(cloud)).category
        == .iCloudTransient)
    #expect(LocalHEICStorage.localizing(CancellationError()) is CancellationError)
  }
}
