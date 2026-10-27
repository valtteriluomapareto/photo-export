import AppKit
import Darwin
import Foundation
import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(2)))
struct FileIOThroughputTests {
  @Test func timestampsUseOneCombinedSetterAndPreserveBothDates() throws {
    let root = TestScratch.directory("TimestampSetter")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("file")
    try Data("bytes".utf8).write(to: file)
    let calls = LockedBox(0)
    let service = FileIOService(timestampSetter: { date, url in
      calls.mutate { $0 += 1 }
      try FileIOService.systemTimestampSetter(date, url)
    })
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    service.applyTimestamps(creationDate: date, to: file)
    #expect(calls.value == 1)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(attributes[.creationDate] as? Date == date)
    #expect(attributes[.modificationDate] as? Date == date)
    #expect(try Data(contentsOf: file) == Data("bytes".utf8))
  }

  @Test func timestampFailureIsBestEffortAndAttemptedOnce() throws {
    let calls = LockedBox(0)
    let file = TestScratch.directory("TimestampFailure").appendingPathComponent("missing")
    let service = FileIOService(timestampSetter: { _, _ in
      calls.mutate { $0 += 1 }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    })
    service.applyTimestamps(creationDate: Date(timeIntervalSince1970: 0), to: file)
    #expect(calls.value == 1)
  }

  @Test(arguments: [true, false])
  func capabilityIsProbedOncePerMountedVolume(supported: Bool) throws {
    let root = TestScratch.directory("RenameCapability")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let probes = LockedBox(0)
    let volume = LockedBox("mount-a")
    let cache = VolumeRenameCapabilityCache(
      identity: { _ in volume.value },
      probe: { _ in
        probes.mutate { $0 += 1 }
        return supported
      })
    let service = FileIOService(capabilityCache: cache)
    for n in 0..<2 {
      let source = root.appendingPathComponent("source-\(n)")
      let destination = root.appendingPathComponent("dir-\(n)/result")
      try Data("bytes".utf8).write(to: source)
      try service.moveItemAtomically(from: source, to: destination)
      #expect(try Data(contentsOf: destination) == Data("bytes".utf8))
    }
    #expect(probes.value == 1)
    volume.mutate { $0 = "mount-b" }
    #expect(cache.supportsExclusiveRename(in: root) == supported)
    #expect(probes.value == 2)
  }

  @Test func unknownProbesDoNotPoisonTheCacheAndMountEventsInvalidateIt() {
    let root = TestScratch.directory("UnknownCapability")
    let probes = LockedBox(0)
    let cache = VolumeRenameCapabilityCache(
      identity: { _ in "mount" },
      probe: { _ in
        var count = 0
        probes.mutate {
          $0 += 1
          count = $0
        }
        return count == 1 ? nil : true
      })
    #expect(!cache.supportsExclusiveRename(in: root))
    #expect(cache.supportsExclusiveRename(in: root))
    #expect(cache.supportsExclusiveRename(in: root))
    #expect(probes.value == 2)
    let center = NotificationCenter()
    cache.observeMounts(in: center)
    center.post(name: NSWorkspace.didUnmountNotification, object: nil)
    #expect(cache.supportsExclusiveRename(in: root))
    #expect(probes.value == 3)
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    #expect(cache.supportsExclusiveRename(in: root))
    #expect(probes.value == 4)
  }

  @Test func anInvalidatedHeldProbeCannotRepopulateTheCache() async {
    let root = TestScratch.directory("HeldCapability")
    let entered = AsyncCheckpoint()
    let release = DispatchSemaphore(value: 0)
    let probes = LockedBox(0)
    let cache = VolumeRenameCapabilityCache(
      identity: { _ in "same-device-and-path" },
      probe: { _ in
        var count = 0
        probes.mutate {
          $0 += 1
          count = $0
        }
        if count == 1 {
          Task { await entered.enter() }
          release.wait()
          return true
        }
        return false
      })
    let old = Task.detached { cache.supportsExclusiveRename(in: root) }
    await entered.waitForEnter(count: 1)
    cache.invalidate()
    #expect(!cache.supportsExclusiveRename(in: root))
    release.signal()
    #expect(await old.value == false)
    await entered.releaseAll()
    #expect(!cache.supportsExclusiveRename(in: root))
    #expect(probes.value == 2)
  }
}
