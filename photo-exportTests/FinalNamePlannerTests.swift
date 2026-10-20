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

    /// Four-byte reads throughout; `shouldStop` is asked before every one unless
    /// `stopInterval` says otherwise.
    func plan(
      middle: Int = 4, stopInterval: Int = 1, claimed: Set<String> = [],
      stop: @escaping @Sendable () -> Bool = {
        false
      }
    ) async throws -> FinalNamePlanner.Plan {
      try await FinalNamePlanner(
        fileSystem: files, edgeChunkSize: 4, middleChunkSize: middle,
        stopCheckInterval: stopInterval
      ).plan(
        slot: slot, stagedURL: url.appendingPathComponent(".stage.tmp"),
        isClaimed: { claimed.contains($0) }, shouldStop: { stop() })
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
  }

  private static let bytes: [UInt8] = Array(0..<14)

  @Test func chunkRangesReadHeadThenTailThenTheRest() {
    #expect(FinalNamePlanner.chunkRanges(size: 0, edge: 4, middle: 8).isEmpty)
    #expect(FinalNamePlanner.chunkRanges(size: 6, edge: 4, middle: 8).map(\.offset) == [0, 4])
    #expect(FinalNamePlanner.chunkRanges(size: 6, edge: 4, middle: 8).map(\.length) == [4, 2])
    let ranges = FinalNamePlanner.chunkRanges(size: 14, edge: 4, middle: 4)
    #expect(ranges.map(\.offset) == [0, 10, 4, 8])
    #expect(ranges.map(\.length) == [4, 4, 4, 2])
    // The middle is read in larger pieces than the head and the tail.
    let wide = FinalNamePlanner.chunkRanges(size: 30, edge: 4, middle: 8)
    #expect(wide.map(\.offset) == [0, 26, 4, 12, 20])
    #expect(wide.map(\.length) == [4, 4, 8, 8, 6])
  }

  /// Each file is opened once for the whole compare, the existing one past the buffer cache,
  /// and both are closed afterwards.
  @Test func compareKeepsOneHandlePerFile() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    let stage = try folder.write(Self.bytes, ".stage.tmp")
    let natural = try folder.write(Self.bytes, "IMG.JPG")

    _ = try await folder.plan()

    #expect(folder.files.readOpens.map(\.url) == [stage, natural])
    #expect(folder.files.readOpens.map(\.bypassingCache) == [false, true])
    #expect(Set(folder.files.readCloses) == [stage, natural])
    #expect(folder.files.readCloses.count == 2)
    #expect(folder.files.chunkReads.filter { $0.url == natural }.count == 4)
  }

  /// Task cancellation is checked before every read, but the main-actor `shouldStop` only
  /// before the first and then once per interval.
  @Test func stopIsAskedOncePerInterval() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    let bytes: [UInt8] = Array(0..<30)
    _ = try folder.write(bytes, ".stage.tmp")
    _ = try folder.write(bytes, "IMG.JPG")
    let asked = LockedBox(0)

    _ = try await folder.plan(
      stopInterval: 8,
      stop: {
        asked.mutate { $0 += 1 }
        return false
      })

    // Reads of 4, 4, 4, 4, 4, 4, 4 and 2 bytes: asked before the 1st, 3rd, 5th and 7th.
    #expect(asked.value == 4)
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
    #expect(folder.files.readCloses.count == 2)
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
    #expect(folder.files.readCloses.count == 2)
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
    #expect(folder.files.readCloses.count == 2)
  }

  /// Only a regular file is adopted, even when another kind of entry reports the stage's
  /// size and its bytes read the same. Defence in depth: the symlink and folder cases in
  /// `IdenticalFileAdoptionTests` already differ in size or cannot be read.
  @Test func nonRegularEntryWithTheStagedSizeIsNotAdopted() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    let natural = try folder.write(Self.bytes, "IMG.JPG")
    folder.files.identityOverride = { url, identity in
      guard url == natural, let identity else { return identity }
      return FileItemIdentity(
        isRegularFile: false, linkCount: identity.linkCount, device: identity.device, inode: identity.inode,
        size: identity.size, modificationSeconds: identity.modificationSeconds,
        modificationNanoseconds: identity.modificationNanoseconds)
    }

    #expect(try await folder.plan() == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
    #expect(!folder.files.chunkReads.contains { $0.url == natural })
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
    #expect(folder.files.readCloses.count == 2)
  }

  /// Without the name the folder stores, an identical file is passed over too.
  @Test func candidateWithoutAStoredNameIsNotAdopted() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    _ = try folder.write(Self.bytes, "IMG.JPG")
    folder.files.storedNameOverride = { _ in throw CocoaError(.fileReadUnknown) }

    #expect(try await folder.plan() == .move(folder.url.appendingPathComponent("IMG (1).JPG")))
  }

  /// A stored name that is not a spelling of the candidate's (another hard link's name, for
  /// instance) is not recorded; the candidate is passed over.
  @Test func storedNameForAnotherEntryIsNotAdopted() async throws {
    let folder = try Folder()
    defer { folder.cleanup() }
    _ = try folder.write(Self.bytes, ".stage.tmp")
    _ = try folder.write(Self.bytes, "IMG.JPG")
    folder.files.storedNameOverride = { _ in "OTHER.JPG" }

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
