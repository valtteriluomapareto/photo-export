import Foundation
import Testing

@testable import Photo_Export

/// The final no-overwrite commit. `moveItemAtomically` refuses an existing destination with
/// `Export`/2 before moving. The window between that check and the move is tracked in #326.
@Suite struct FileIOServiceTests {
  private func makeRoot() throws -> URL {
    let root = TestScratch.directory("FileIOService")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func existingDestinationIsRefusedAndKeepsItsBytes() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(".photo-export-stage.tmp")
    let destination = root.appendingPathComponent("IMG_0001.JPG")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)

    do {
      try FileIOService.moveItemAtomically(from: source, to: destination)
      Issue.record("Moving onto an existing file must fail")
    } catch {
      let error = error as NSError
      #expect(error.domain == "Export")
      #expect(error.code == 2)
      #expect(error.localizedDescription == "Destination already exists")
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

    try FileIOService.moveItemAtomically(from: source, to: destination)

    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: source.path))
  }
}
