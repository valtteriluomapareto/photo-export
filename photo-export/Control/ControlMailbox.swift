#if DEBUG
  import Darwin
  import Foundation

  @MainActor final class ControlMailbox {
    private let directory: URL
    private let run: String
    private let actions: ControlActions
    private let publish: (Int, Int) throws -> Void
    private let fail: (any Error) -> Void
    private let source: any DispatchSourceFileSystemObject
    private(set) var sequence = 0
    private var draining = false

    init(
      directory: URL, run: String, actions: ControlActions,
      publish: @escaping (Int, Int) throws -> Void,
      fail: @escaping (any Error) -> Void
    ) throws {
      let descriptor = open(directory.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW)
      guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      self.directory = directory
      self.run = run
      self.actions = actions
      self.publish = publish
      self.fail = fail
      source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
      source.setCancelHandler { close(descriptor) }
      source.setEventHandler { [weak self] in
        Task { @MainActor in self?.check() }
      }
      source.activate()
    }

    deinit { source.cancel() }

    func check() {
      guard !draining else { return }
      draining = true
      defer { draining = false }
      do { try drain() } catch { fail(error) }
    }

    private func drain() throws {
      while sequence < Int.max {
        let next = sequence + 1
        let request = directory.appending(path: "req-\(next).json")
        var metadata = stat()
        if lstat(request.path, &metadata) != 0 {
          if errno == ENOENT { return }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let response = directory.appending(path: "res-\(next).json")
        guard lstat(response.path, &metadata) != 0, errno == ENOENT else {
          throw CocoaError(.fileWriteFileExists)
        }
        try publish(next, sequence)
        let outcome: ControlOutcome
        do {
          let data = try readRequest(request)
          let action = try ControlRequest.decode(data, run: run, sequence: next)
          outcome = actions.perform(action)
        } catch let refusal as ControlRefusal {
          outcome = .refused(refusal)
        } catch {
          outcome = .refused(.invalidRequest)
        }
        sequence = next
        try publish(sequence, sequence)
        try writeResponse(outcome, to: response)
      }
    }

    private func readRequest(_ url: URL) throws -> Data {
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw ControlRefusal.invalidRequest }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      var metadata = stat()
      guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_nlink == 1, metadata.st_uid == getuid(),
        metadata.st_size <= ControlRequest.maxBytes
      else { throw ControlRefusal.invalidRequest }
      return try file.read(upToCount: ControlRequest.maxBytes + 1) ?? Data()
    }

    private func writeResponse(_ outcome: ControlOutcome, to url: URL) throws {
      let data = try JSONSerialization.data(
        withJSONObject: outcome.response(run: run, sequence: sequence), options: [.sortedKeys])
      let temporary = directory.appending(path: ".response-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: temporary) }  // best-effort staging cleanup
      try data.write(to: temporary, options: .withoutOverwriting)
      try FileManager.default.linkItem(at: temporary, to: url)
    }
  }
#endif
