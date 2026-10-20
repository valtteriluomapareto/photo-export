import Darwin
import Foundation
import Testing

@testable import Photo_Export

/// The final no-overwrite commit. On a volume that advertises an exclusive rename,
/// `moveItemAtomically` commits with `renamex_np(RENAME_EXCL)` and no pre-check; elsewhere
/// it checks for an existing file, then moves. Either way an existing destination is
/// refused with `Export`/2 and keeps its bytes.
@Suite struct FileIOServiceTests {
  /// The two commit paths, chosen by the destination volume's capability.
  enum CommitPath: String, CaseIterable, CustomTestStringConvertible {
    case exclusiveRename
    case checkThenMove

    var testDescription: String { rawValue }

    var capability: FileIOService.ExclusiveRenameCapability {
      switch self {
      case .exclusiveRename: return FileIOService.volumeSupportsExclusiveRename
      case .checkThenMove: return { _ in false }
      }
    }
  }

  /// Records every rename call and forwards it to the system call.
  final class RecordingRenamer: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(source: URL, destination: URL, flags: UInt32)] = []

    var calls: [(source: URL, destination: URL, flags: UInt32)] {
      lock.withLock { _calls }
    }

    var renamer: FileIOService.Renamer {
      { [self] source, destination, flags in
        lock.withLock { _calls.append((source, destination, flags)) }
        return FileIOService.systemRename(source, destination, flags)
      }
    }
  }

  private static let exclusiveRenameVolumeRequired: Comment =
    "TMPDIR must be on a volume with VOL_CAP_INT_RENAME_EXCL (APFS or HFS+)"

  private func makeRoot() throws -> URL {
    let root = TestScratch.directory("FileIOService")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func expectDestinationExists(_ body: () throws -> Void) {
    do {
      try body()
      Issue.record("Committing onto an existing file must fail")
    } catch {
      let error = error as NSError
      #expect(error.domain == "Export")
      #expect(error.code == 2)
      #expect(error.localizedDescription == "Destination already exists")
    }
  }

  @Test func existingDestinationIsRefusedAndKeepsItsBytes() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)

    expectDestinationExists {
      try FileIOService().moveItemAtomically(from: source, to: destination)
    }
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    #expect(try Data(contentsOf: source) == Data("new".utf8))
  }

  @Test func missingParentFolderIsCreated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("2025/03/IMG_0001.JPG")
    try Data("new".utf8).write(to: source)

    try FileIOService().moveItemAtomically(from: source, to: destination)

    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  /// A file that appears at the final name after any check and right before the commit
  /// is refused with the collision signature, and its bytes are never replaced. The
  /// exclusive case uses the production capability check; the check-then-move case proves
  /// `moveItem`'s own refusal is reported as `Export`/2, not that its window is closed.
  @Test(arguments: CommitPath.allCases)
  func existingFileAtCommitIsNeverReplaced(path: CommitPath) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    if path == .exclusiveRename {
      try #require(
        FileIOService.volumeSupportsExclusiveRename(root), Self.exclusiveRenameVolumeRequired)
    }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let recorder = RecordingRenamer()
    let hooks = FileIOService.Hooks(beforeCommit: { _, destination in
      try Data("third-party".utf8).write(to: destination)
    })
    let service =
      switch path {
      case .exclusiveRename: FileIOService(renamer: recorder.renamer, hooks: hooks)
      case .checkThenMove:
        FileIOService(renamer: recorder.renamer, capability: { _ in false }, hooks: hooks)
      }

    expectDestinationExists {
      try service.moveItemAtomically(from: source, to: destination)
    }
    let destinationBytes = try String(contentsOf: destination, encoding: .utf8)
    #expect(destinationBytes == "third-party")
    #expect(FileManager.default.fileExists(atPath: source.path))
    switch path {
    case .exclusiveRename: #expect(recorder.calls.map(\.flags) == [UInt32(RENAME_EXCL)])
    case .checkThenMove: #expect(recorder.calls.isEmpty)
    }
  }

  @Test func capableVolumeCommitsWithAnExclusiveRenameAndNoPreCheck() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("2025/03/IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let recorder = RecordingRenamer()
    let service = FileIOService(renamer: recorder.renamer, capability: { _ in true })

    try service.moveItemAtomically(from: source, to: destination)

    #expect(recorder.calls.map(\.source) == [source])
    #expect(recorder.calls.map(\.destination) == [destination])
    #expect(recorder.calls.map(\.flags) == [UInt32(RENAME_EXCL)])
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test func capabilityIsAskedAboutTheDestinationFolderAfterItIsCreated() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("2025/03/IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let asked = LockedBox<[(folder: URL, existed: Bool)]>([])
    let service = FileIOService(capability: { directory in
      var isDirectory: ObjCBool = false
      let existed =
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
      asked.mutate { $0.append((directory, existed)) }
      return FileIOService.volumeSupportsExclusiveRename(directory)
    })

    try service.moveItemAtomically(from: source, to: destination)

    #expect(asked.value.map(\.folder) == [destination.deletingLastPathComponent()])
    #expect(asked.value.map(\.existed) == [true])
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
  }

  @Test func volumeWithoutTheCapabilityChecksThenMoves() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    let recorder = RecordingRenamer()
    let hookCalls = LockedBox(0)
    let service = FileIOService(
      renamer: recorder.renamer, capability: { _ in false },
      hooks: .init(beforeCommit: { _, _ in hookCalls.mutate { $0 += 1 } }))

    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)
    expectDestinationExists {
      try service.moveItemAtomically(from: source, to: destination)
    }
    // The pre-check refuses before reaching the commit call.
    #expect(hookCalls.value == 0)
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))

    try FileManager.default.removeItem(at: destination)
    try service.moveItemAtomically(from: source, to: destination)

    #expect(hookCalls.value == 1)
    #expect(recorder.calls.isEmpty)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  /// A volume that advertises the bit but rejects the flag falls back to check-then-move;
  /// a failed `renamex_np` leaves the stage where it was.
  @Test(arguments: [ENOTSUP, ENOSYS])
  func unsupportedExclusiveRenameFallsBackToCheckThenMove(code: Int32) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("2025/03/IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let renames = LockedBox<[UInt32]>([])
    let service = FileIOService(
      renamer: { _, _, flags in
        renames.mutate { $0.append(flags) }
        return code
      },
      capability: { _ in true })

    try service.moveItemAtomically(from: source, to: destination)

    #expect(renames.value == [UInt32(RENAME_EXCL)])
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }

  @Test(arguments: [ENOTSUP, ENOSYS])
  func unsupportedExclusiveRenameFallbackStillRefusesAnExistingFile(code: Int32) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)
    let service = FileIOService(renamer: { _, _, _ in code }, capability: { _ in true })

    expectDestinationExists {
      try service.moveItemAtomically(from: source, to: destination)
    }
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    #expect(try Data(contentsOf: source) == Data("new".utf8))
  }

  struct ErrnoCase: Sendable, CustomTestStringConvertible {
    let code: Int32
    let category: AutoSyncFailureCategory
    let testDescription: String
  }

  /// Other rename failures surface as the POSIX error, so the export failure
  /// classification sees the same categories as before.
  @Test(arguments: [
    ErrnoCase(code: ENOSPC, category: .destinationNoSpace, testDescription: "ENOSPC"),
    ErrnoCase(code: EACCES, category: .destinationPermission, testDescription: "EACCES"),
    ErrnoCase(code: ENOENT, category: .destinationUnavailable, testDescription: "ENOENT"),
    ErrnoCase(code: EXDEV, category: .unknown, testDescription: "EXDEV"),
  ])
  func renameErrnoMapsToThePOSIXError(errnoCase: ErrnoCase) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let service = FileIOService(renamer: { _, _, _ in errnoCase.code }, capability: { _ in true })

    do {
      try service.moveItemAtomically(from: source, to: destination)
      Issue.record("A failed rename must throw")
    } catch {
      let error = error as NSError
      #expect(error.domain == NSPOSIXErrorDomain)
      #expect(error.code == Int(errnoCase.code))
      #expect(error.userInfo[NSFilePathErrorKey] as? String == destination.path)
      let signal = AutoSyncFailureCategory.classify(error)
      #expect(signal.category == errnoCase.category)
      #expect(signal.errorSignature == "\(NSPOSIXErrorDomain):\(errnoCase.code)")
    }
    #expect(try Data(contentsOf: source) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func renameEEXISTKeepsTheCollisionSignature() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    let service = FileIOService(renamer: { _, _, _ in EEXIST }, capability: { _ in true })

    do {
      try service.moveItemAtomically(from: source, to: destination)
      Issue.record("EEXIST must throw")
    } catch {
      let signal = AutoSyncFailureCategory.classify(error)
      #expect(signal.errorSignature == "Export:2")
      #expect(signal.category == .destinationCollision)
    }
  }

  @Test func scratchVolumeAdvertisesExclusiveRenameAndAMissingFolderDoesNot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // TestScratch lives on the boot APFS volume, which advertises the capability.
    #expect(FileIOService.volumeSupportsExclusiveRename(root))
    #expect(
      !FileIOService.volumeSupportsExclusiveRename(root.appendingPathComponent("missing")))
  }

  struct CapabilityCase: Sendable, CustomTestStringConvertible {
    let capabilities: vol_capabilities_attr_t
    let expected: Bool
    let testDescription: String

    init(_ name: String, format: (UInt32, UInt32), interfaces: (UInt32, UInt32), _ expected: Bool) {
      capabilities = vol_capabilities_attr_t(
        capabilities: (format.0, interfaces.0, 0, 0), valid: (format.1, interfaces.1, 0, 0))
      self.expected = expected
      testDescription = name
    }
  }

  private static let renameExcl = UInt32(VOL_CAP_INT_RENAME_EXCL)
  private static let renameSwap = UInt32(VOL_CAP_INT_RENAME_SWAP)

  /// Pairs are (supported, valid). Only the interfaces word decides.
  @Test(arguments: [
    CapabilityCase(
      "valid and supported", format: (0, 0), interfaces: (renameExcl, renameExcl), true),
    CapabilityCase("valid only", format: (0, 0), interfaces: (0, renameExcl), false),
    CapabilityCase("supported only", format: (0, 0), interfaces: (renameExcl, 0), false),
    CapabilityCase(
      "neighbouring bit", format: (0, 0), interfaces: (renameSwap, renameSwap), false),
    CapabilityCase(
      "bit in the format word", format: (renameExcl, renameExcl), interfaces: (0, 0), false),
  ])
  func capabilityDecoding(capabilityCase: CapabilityCase) {
    #expect(
      FileIOService.advertisesExclusiveRename(capabilityCase.capabilities)
        == capabilityCase.expected)
  }

  // MARK: - Unicode normalization

  private static let nfcName = "Kes\u{E4}.JPG"
  private static let nfdName = "Kesa\u{308}.JPG"

  /// Compares scalars, since Swift's `==` treats the two spellings as equal.
  private func isEitherSpelling(_ name: String) -> Bool {
    [Self.nfcName, Self.nfdName].contains { Array($0.unicodeScalars) == Array(name.unicodeScalars) }
  }

  /// Creates a file whose on-disk name is exactly `name`'s bytes. Foundation's file-system
  /// representation decomposes names, so this goes through `open(2)` directly.
  private func writeExactName(_ name: String, in folder: URL, contents: String) throws {
    let path = folder.path + "/" + name
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    try #require(descriptor >= 0, "open failed: \(errno)")
    defer { close(descriptor) }
    let bytes = Array(contents.utf8)
    try #require(write(descriptor, bytes, bytes.count) == bytes.count)
  }

  /// Either spelling commits to exactly one file, found under both spellings.
  @Test(arguments: CommitPath.allCases)
  func composedAndDecomposedNamesCommit(path: CommitPath) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    if path == .exclusiveRename {
      try #require(
        FileIOService.volumeSupportsExclusiveRename(root), Self.exclusiveRenameVolumeRequired)
    }
    let service = FileIOService(capability: path.capability)

    for (index, name) in [Self.nfcName, Self.nfdName].enumerated() {
      let folder = root.appendingPathComponent("\(index)", isDirectory: true)
      let source = root.appendingPathComponent(".photo-export-stage-\(index).tmp")
      try Data(name.utf8).write(to: source)

      try service.moveItemAtomically(from: source, to: folder.appendingPathComponent(name))

      let listed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      #expect(listed.count == 1)
      #expect(listed.allSatisfy(isEitherSpelling))
      for spelling in [Self.nfcName, Self.nfdName] {
        #expect(
          try Data(contentsOf: folder.appendingPathComponent(spelling)) == Data(name.utf8))
      }
      #expect(!FileManager.default.fileExists(atPath: source.path))
    }
  }

  /// APFS compares names normalization-insensitively, so a file stored in either spelling
  /// blocks a commit in the other one.
  @Test(arguments: CommitPath.allCases)
  func existingFileInTheOtherNormalizationIsRefused(path: CommitPath) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    if path == .exclusiveRename {
      try #require(
        FileIOService.volumeSupportsExclusiveRename(root), Self.exclusiveRenameVolumeRequired)
    }
    let service = FileIOService(capability: path.capability)

    for (existing, committed) in [(Self.nfcName, Self.nfdName), (Self.nfdName, Self.nfcName)] {
      let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let source = root.appendingPathComponent(".photo-export-stage-\(UUID().uuidString).tmp")
      try Data("new".utf8).write(to: source)
      try writeExactName(existing, in: folder, contents: "existing")

      expectDestinationExists {
        try service.moveItemAtomically(from: source, to: folder.appendingPathComponent(committed))
      }
      let listed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      #expect(listed.count == 1)
      #expect(listed.allSatisfy(isEitherSpelling))
      #expect(
        try Data(contentsOf: folder.appendingPathComponent(existing)) == Data("existing".utf8))
      #expect(try Data(contentsOf: source) == Data("new".utf8))
    }
  }
}
