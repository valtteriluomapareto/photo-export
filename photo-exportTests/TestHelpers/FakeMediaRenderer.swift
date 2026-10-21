import AVFoundation
import Foundation

@testable import Photo_Export

/// Test double for `MediaRenderer`. Injection knobs are lock-guarded so
/// parallel Swift Testing runs cannot race on them. The defaults
/// (`shouldCreateFile = true`, no error) cover the common "render
/// succeeded" case in pipeline tests.
final class FakeMediaRenderer: MediaRenderer, @unchecked Sendable {
  struct RenderCall: Equatable {
    let request: MediaRenderRequest
    let url: URL
  }

  private let lock = NSLock()
  private var _renderCalls: [RenderCall] = []
  private var _renderError: Error?
  private var _shouldCreateFile: Bool = true
  private var _fileWriter: ((URL) -> Void)?
  private var _renderLatch: AsyncSemaphore?
  private var _enteredSignal: AsyncSemaphore?
  private var _beforeRenderCheckpoint: AsyncCheckpoint?
  private var _afterRenderCheckpoint: AsyncCheckpoint?

  var beforeRenderCheckpoint: AsyncCheckpoint? {
    get { lock.withLock { _beforeRenderCheckpoint } }
    set { lock.withLock { _beforeRenderCheckpoint = newValue } }
  }

  var afterRenderCheckpoint: AsyncCheckpoint? {
    get { lock.withLock { _afterRenderCheckpoint } }
    set { lock.withLock { _afterRenderCheckpoint = newValue } }
  }

  var renderCalls: [RenderCall] {
    lock.lock()
    defer { lock.unlock() }
    return _renderCalls
  }

  var renderError: Error? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _renderError
    }
    set {
      lock.lock()
      _renderError = newValue
      lock.unlock()
    }
  }

  var shouldCreateFile: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _shouldCreateFile
    }
    set {
      lock.lock()
      _shouldCreateFile = newValue
      lock.unlock()
    }
  }

  var fileWriter: ((URL) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _fileWriter
    }
    set {
      lock.lock()
      _fileWriter = newValue
      lock.unlock()
    }
  }

  /// Installs a latch the next render call must wait on before it does
  /// anything. Used by cancel-during-render tests so the cancel can land
  /// while the renderer is parked, deterministically — no sleeps. The
  /// latch is consumed on first use; subsequent renders proceed without
  /// waiting.
  func arm(latch: AsyncSemaphore) {
    lock.lock()
    _renderLatch = latch
    lock.unlock()
  }

  /// Installs a one-shot signal that fires the moment a `render` call
  /// enters. Tests await this to know "the render is parked at the
  /// latch" rather than guessing via sleeps or polling published state.
  /// Pair with `arm(latch:)` for cancel-during-render scenarios.
  func arm(enteredSignal: AsyncSemaphore) {
    lock.lock()
    _enteredSignal = enteredSignal
    lock.unlock()
  }

  func render(request: MediaRenderRequest, to url: URL) async throws {
    let (latch, enteredSignal): (AsyncSemaphore?, AsyncSemaphore?) = {
      lock.lock()
      defer { lock.unlock() }
      let l = _renderLatch
      let e = _enteredSignal
      _renderLatch = nil
      _enteredSignal = nil
      return (l, e)
    }()
    enteredSignal?.signal()
    if let latch { await latch.wait() }

    lock.lock()
    _renderCalls.append(RenderCall(request: request, url: url))
    lock.unlock()

    if let checkpoint = beforeRenderCheckpoint { await checkpoint.enter() }
    if let err = renderError { throw err }
    if let writer = fileWriter {
      writer(url)
    } else if shouldCreateFile {
      FileManager.default.createFile(atPath: url.path, contents: Data("fake-rendered".utf8))
    }
    if let checkpoint = afterRenderCheckpoint { await checkpoint.enter() }
  }
}

/// Tiny async semaphore for cancel/race tests. One waiter, one signaller.
/// Backed by a lock-guarded continuation to avoid hopping through actors.
final class AsyncSemaphore: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var signalled = false

  init() {}

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if signalled {
        lock.unlock()
        c.resume()
      } else {
        continuation = c
        lock.unlock()
      }
    }
  }

  func signal() {
    lock.lock()
    signalled = true
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume()
  }
}
