import Foundation
import Photos
import Testing

@testable import Photo_Export

struct ProductionAssetResourceWriterTests {
  private func makeTempURL(filename: String = UUID().uuidString) -> URL {
    TestScratch.directory("ProductionWriter").appendingPathComponent(filename)
  }

  @Test func writeResourceUsesResolvedWriteCallback() async throws {
    let resource = ResourceDescriptor(type: .photo, originalFilename: "IMG_0001.JPG")
    let destination = makeTempURL(filename: "success.dat")
    try? FileManager.default.removeItem(at: destination)
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

    var resolvedAssetId: String?
    var resolvedDescriptor: ResourceDescriptor?
    var wroteToURL: URL?

    let backend = ProductionAssetResourceWriter.Backend { assetId, descriptor in
      resolvedAssetId = assetId
      resolvedDescriptor = descriptor
      return ProductionAssetResourceWriter.ResolvedResource(
        type: descriptor.type,
        originalFilename: descriptor.originalFilename,
        writeData: { url, completion in
          wroteToURL = url
          try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          FileManager.default.createFile(atPath: url.path, contents: Data("ok".utf8))
          completion(nil)
        }
      )
    }

    let writer = ProductionAssetResourceWriter(backend: backend)

    try await writer.writeResource(resource, forAssetId: "asset-1", to: destination)

    #expect(resolvedAssetId == "asset-1")
    #expect(resolvedDescriptor == resource)
    #expect(wroteToURL == destination)
    #expect(FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func writeResourcePropagatesResolutionError() async {
    struct ResolutionError: Error {}

    let backend = ProductionAssetResourceWriter.Backend { _, _ in
      throw ResolutionError()
    }
    let writer = ProductionAssetResourceWriter(backend: backend)

    do {
      try await writer.writeResource(
        ResourceDescriptor(type: .photo, originalFilename: "IMG_0001.JPG"),
        forAssetId: "asset-1",
        to: makeTempURL(filename: "resolution-error.dat")
      )
      #expect(Bool(false), "Expected resolution error")
    } catch is ResolutionError {
      // Expected
    } catch {
      #expect(Bool(false), "Unexpected error: \(error.localizedDescription)")
    }
  }

  @Test func writeResourcePropagatesWriteCallbackError() async {
    let expectedError = NSError(
      domain: "Test",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "Write failed"]
    )
    let backend = ProductionAssetResourceWriter.Backend { _, descriptor in
      ProductionAssetResourceWriter.ResolvedResource(
        type: descriptor.type,
        originalFilename: descriptor.originalFilename,
        writeData: { _, completion in
          completion(expectedError)
        }
      )
    }
    let writer = ProductionAssetResourceWriter(backend: backend)

    do {
      try await writer.writeResource(
        ResourceDescriptor(type: .photo, originalFilename: "IMG_0001.JPG"),
        forAssetId: "asset-1",
        to: makeTempURL(filename: "write-error.dat")
      )
      #expect(Bool(false), "Expected write callback error")
    } catch let error as NSError {
      #expect(error.domain == expectedError.domain)
      #expect(error.code == expectedError.code)
    } catch {
      #expect(Bool(false), "Unexpected error: \(error.localizedDescription)")
    }
  }
}
