import Foundation
import Testing

@testable import Photo_Export

/// The walk that picks a staged file's final name, driven with a small chunk size so the
/// compare order is visible.
@Suite struct FinalNamePlannerTests {
  private struct Folder {
    let url = TestScratch.directory("FinalNamePlanner")
    let files = FakeFileSystem()

    init() throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ bytes: [UInt8], _ name: String) throws -> URL {
      let file = url.appendingPathComponent(name)
      try Data(bytes).write(to: file)
      return file
    }

    var slot: ExportDestinationResolver.Slot {
      ExportDestinationResolver.Slot(
        directory: url, filename: "IMG.JPG", policy: .suffix(base: "IMG", ext: "JPG"))
    }

    func plan(
      chunkSize: Int = 4, claimed: Set<String> = [],
      stop: @escaping @Sendable () -> Bool = {
        false
      }
    ) async throws -> FinalNamePlanner.Plan {
      try await FinalNamePlanner(fileSystem: files, chunkSize: chunkSize).plan(
        slot: slot, stagedURL: url.appendingPathComponent(".stage.tmp"),
        isClaimed: { claimed.contains($0) }, shouldStop: { stop() })
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
  }

  private static let bytes: [UInt8] = Array(0..<14)

  @Test func chunkRangesReadHeadThenTailThenTheRest() {
    #expect(FinalNamePlanner.chunkRanges(size: 0, chunkSize: 4).isEmpty)
    #expect(FinalNamePlanner.chunkRanges(size: 6, chunkSize: 4).map(\.offset) == [0, 4])
    #expect(FinalNamePlanner.chunkRanges(size: 6, chunkSize: 4).map(\.length) == [4, 2])
    let ranges = FinalNamePlanner.chunkRanges(size: 14, chunkSize: 4)
    #expect(ranges.map(\.offset) == [0, 10, 4, 8])
    #expect(ranges.map(\.length) == [4, 4, 4, 2])
  }

  @Test func identicalFileIsAdoptedAfterReadingEveryChunk() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    let stage = try folder.write(Self.bytes, ".stage.tmp")
    let natural = try folder.write(Self.bytes, "IMG.JPG")
    let identity = try #require(try FileIOService().itemIdentity(at: natural))

    let plan = try await folder.plan()

    #expect(plan == .adopt(natural, storedName: "IMG.JPG", identity: identity))
    #expect(folder.files.chunkReads.filter { $0.url == stage }.map(\.offset) == [0, 10, 4, 8])
  }

  /// A difference in the tail is found by the second read; the middle is never read.
  @Test func differentTailRejectsAfterTheHeadAndTail() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    var other = Self.bytes
    other[13] ^= 0xff
    let natural = try folder.write(other, "IMG.JPG")

    let plan = try await folder.plan()

    #expect(plan == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
    #expect(folder.files.chunkReads.filter { $0.url == natural }.map(\.offset) == [0, 10])
  }

  @Test func differentMiddleRejectsAfterReadingIt() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    var other = Self.bytes
    other[5] ^= 0xff
    let natural = try folder.write(other, "IMG.JPG")

    #expect(try await folder.plan() == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
    #expect(folder.files.chunkReads.filter { $0.url == natural }.map(\.offset) == [0, 10, 4])
  }

  /// The walk goes past a claimed identical file, a different one and an empty one, and
  /// adopts the first identical, unclaimed candidate after them.
  @Test func walkSkipsClaimedDifferentAndEmptyCandidates() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    _ = try folder.write(Self.bytes, "IMG.JPG")
    _ = try folder.write(Array(Self.bytes.reversed()), "IMG (1).JPG")
    _ = try folder.write([], "IMG (2).JPG")
    let adoptable = try folder.write(Self.bytes, "IMG (3).JPG")
    let identity = try #require(try FileIOService().itemIdentity(at: adoptable))

    let plan = try await folder.plan(claimed: ["IMG.JPG"])

    #expect(plan == .adopt(adoptable, storedName: "IMG (3).JPG", identity: identity))
    // The claimed and empty files are never read.
    let read = Set(folder.files.chunkReads.map(\.url.lastPathComponent))
    #expect(read == [".stage.tmp", "IMG (1).JPG", "IMG (3).JPG"])
  }

  /// A stop request ends the compare before its next chunk.
  @Test func stopRequestEndsTheCompare() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    let natural = try folder.write(Self.bytes, "IMG.JPG")
    let reads = LockedBox(0)
    folder.files.chunkReadHook = { url, _ in
      if url == natural { reads.mutate { $0 += 1 } }
    }

    await #expect(throws: CancellationError.self) {
      try await folder.plan(stop: { reads.value >= 2 })
    }
    #expect(folder.files.chunkReads.filter { $0.url == natural }.map(\.offset) == [0, 10])
  }

  /// A file that cannot be read cannot be shown identical, so it is passed over.
  @Test func unreadableCandidateIsNotAdopted() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    let natural = try folder.write(Self.bytes, "IMG.JPG")
    folder.files.chunkReadHook = { url, _ in
      if url == natural { throw CocoaError(.fileReadNoPermission) }
    }

    #expect(try await folder.plan() == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
  }

  /// Without the name the folder stores, an identical file is passed over too.
  @Test func candidateWithoutAStoredNameIsNotAdopted() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    _ = try folder.write(Self.bytes, "IMG.JPG")
    folder.files.storedNameError = CocoaError(.fileReadUnknown)

    #expect(try await folder.plan() == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
  }

  @Test func refuseSlotAlwaysMovesToItsName() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    let fixed = try folder.write(Self.bytes, "IMG_orig.JPG")
    let slot = ExportDestinationResolver.Slot(
      directory: folder.url, filename: "IMG_orig.JPG", policy: .refuse(stem: "IMG"))

    let plan = try await FinalNamePlanner(fileSystem: folder.files).plan(
      slot: slot, stagedURL: folder.url.appendingPathComponent(".stage.tmp"),
      isClaimed: { _ in false }, shouldStop: { false })

    #expect(plan == .move(fixed))
    #expect(folder.files.chunkReads.isEmpty)
  }
}
