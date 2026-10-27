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

}
