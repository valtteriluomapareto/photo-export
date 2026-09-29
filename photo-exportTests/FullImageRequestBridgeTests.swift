import AppKit
import Foundation
import Photos
import Testing

@testable import Photo_Export

/// Drives the same request/continuation bridge used by PhotoLibraryManager, with
/// synchronous fake PhotoKit callbacks so cancellation ordering is controlled.
@MainActor
struct FullImageRequestBridgeTests {
  private enum RequestFailure: Error, Sendable {
    case failed
  }

  private final class RequestDriver: @unchecked Sendable {
    let requestID: PHImageRequestID = 42
    // Configure before starting a request; the request and cancellation paths
    // read these values but never mutate them while work is in flight.
    var beforeReturningID: (() -> Void)?
    var respondsToCancel = false

    private let lock = NSLock()
    private var callback: FullImageRequestBridge.Callback?
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var cancelledIDs: [PHImageRequestID] = []

    var cancellations: [PHImageRequestID] {
      lock.withLock { cancelledIDs }
    }

    var didStart: Bool {
      lock.withLock { started }
    }

    func start(_ callback: @escaping FullImageRequestBridge.Callback) -> PHImageRequestID {
      let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        self.callback = callback
        started = true
        let waiter = startWaiter
        startWaiter = nil
        return waiter
      }
      waiter?.resume()
      beforeReturningID?()
      return requestID
    }

    func waitForStart() async {
      if lock.withLock({ started }) { return }
      await withCheckedContinuation { continuation in
        let alreadyStarted = lock.withLock { () -> Bool in
          if started { return true }
          startWaiter = continuation
          return false
        }
        if alreadyStarted { continuation.resume() }
      }
    }

    func fire(_ result: Result<NSImage, Error>?) {
      let callback = lock.withLock { self.callback }
      callback?(result)
    }

    func cancel(_ requestID: PHImageRequestID) {
      lock.withLock { cancelledIDs.append(requestID) }
      // PhotoKit is allowed to call back synchronously from cancellation. This
      // would deadlock if the bridge invoked `cancelRequest` while holding its lock.
      if respondsToCancel { fire(.failure(CancellationError())) }
    }
  }

  private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<NSImage, Error>?

    func store(_ task: Task<NSImage, Error>) {
      lock.withLock { self.task = task }
    }

    func cancel() {
      let task = lock.withLock { self.task }
      task?.cancel()
    }
  }

  @Test(arguments: [false, true])
  func cancelAfterRequestIDResumesWithoutWaitingForCallback(respondsToCancel: Bool) async {
    let driver = RequestDriver()
    driver.respondsToCancel = respondsToCancel
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    let task = Task { try await bridge.request(start: driver.start) }

    await driver.waitForStart()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must throw even when PhotoKit never supplies an image.")
    } catch is CancellationError {
      // Expected with and without a reentrant cancellation callback.
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(driver.cancellations == [driver.requestID])
  }

  @Test func alreadyCancelledTaskDoesNotStartPhotoKitRequest() async {
    let driver = RequestDriver()
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    // This test is main-actor isolated, so the newly created task cannot run
    // until the first await below. Cancellation is already set at entry.
    let task = Task { try await bridge.request(start: driver.start) }
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("An already-cancelled task must throw.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(!driver.didStart)
    #expect(driver.cancellations.isEmpty)
  }

  @Test func cancelBeforeRequestIDInstallationCancelsTheLateID() async {
    let driver = RequestDriver()
    let taskBox = TaskBox()
    driver.beforeReturningID = { taskBox.cancel() }
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    let task = Task { try await bridge.request(start: driver.start) }
    taskBox.store(task)

    do {
      _ = try await task.value
      Issue.record("Cancellation during requestImage must throw.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Expected CancellationError, got \(error)")
    }
    #expect(driver.cancellations == [driver.requestID])
    driver.fire(.success(NSImage(size: NSSize(width: 1, height: 1))))
    #expect(driver.cancellations == [driver.requestID])
  }

  @Test func degradedResponseWaitsForFinalImage() async throws {
    let driver = RequestDriver()
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    let task = Task { try await bridge.request(start: driver.start) }
    await driver.waitForStart()

    let degradedImage = NSImage(size: NSSize(width: 1, height: 1))
    let finalImage = NSImage(size: NSSize(width: 2, height: 2))
    driver.fire(
      FullImageRequestBridge.response(
        image: degradedImage,
        info: [PHImageResultIsDegradedKey: NSNumber(value: true)],
        missingImageError: PhotoLibraryManager.PhotoLibraryError.assetUnavailable))
    driver.fire(.success(finalImage))

    let returned = try await task.value
    #expect(returned === finalImage)
    #expect(driver.cancellations.isEmpty)
  }

  @Test func degradedErrorAndCancellationAreTerminal() {
    let error = NSError(domain: "test", code: 7)
    let degradedError = FullImageRequestBridge.response(
      image: nil,
      info: [
        PHImageResultIsDegradedKey: NSNumber(value: true),
        PHImageErrorKey: error,
      ],
      missingImageError: PhotoLibraryManager.PhotoLibraryError.assetUnavailable)
    if case .some(.failure(let receivedError)) = degradedError {
      #expect((receivedError as NSError) === error)
    } else {
      Issue.record("A degraded callback with an error must terminate the request.")
    }

    let degradedCancellation = FullImageRequestBridge.response(
      image: nil,
      info: [
        PHImageResultIsDegradedKey: NSNumber(value: true),
        PHImageCancelledKey: NSNumber(value: true),
      ],
      missingImageError: PhotoLibraryManager.PhotoLibraryError.assetUnavailable)
    if case .some(.failure(let receivedError)) = degradedCancellation {
      #expect(receivedError is CancellationError)
    } else {
      Issue.record("A degraded callback marked cancelled must terminate the request.")
    }
  }

  @Test func finalCallbackWinsOverLaterCancellationAndDuplicates() async throws {
    let driver = RequestDriver()
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    let task = Task { try await bridge.request(start: driver.start) }
    await driver.waitForStart()

    let image = NSImage(size: NSSize(width: 2, height: 2))
    driver.fire(.success(image))
    task.cancel()
    driver.fire(.failure(NSError(domain: "late", code: 1)))

    let returned = try await task.value
    #expect(returned === image)
    #expect(driver.cancellations.isEmpty)
  }

  @Test func synchronousTerminalCallbackBeforeIDInstallationWins() async {
    let driver = RequestDriver()
    driver.beforeReturningID = { driver.fire(.failure(RequestFailure.failed)) }
    let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
    let task = Task { try await bridge.request(start: driver.start) }

    do {
      _ = try await task.value
      Issue.record("The synchronous terminal callback must throw.")
    } catch RequestFailure.failed {
      // Expected; the callback arrived before the request ID.
    } catch {
      Issue.record("Expected RequestFailure.failed, got \(error)")
    }
    task.cancel()
    driver.fire(.failure(RequestFailure.failed))
    #expect(driver.cancellations.isEmpty)
  }

  @Test func concurrentTerminalCallbackAndCancellationResumeExactlyOnce() async {
    for _ in 0..<32 {
      let driver = RequestDriver()
      let bridge = FullImageRequestBridge(cancelRequest: driver.cancel)
      let taskBox = TaskBox()
      let task = Task { try await bridge.request(start: driver.start) }
      taskBox.store(task)
      await driver.waitForStart()

      let start = DispatchSemaphore(value: 0)
      let group = DispatchGroup()
      group.enter()
      DispatchQueue.global().async {
        start.wait()
        driver.fire(.failure(RequestFailure.failed))
        group.leave()
      }
      group.enter()
      DispatchQueue.global().async {
        start.wait()
        taskBox.cancel()
        group.leave()
      }
      start.signal()
      start.signal()
      await withCheckedContinuation { continuation in
        group.notify(queue: .global()) { continuation.resume() }
      }

      do {
        _ = try await task.value
        Issue.record("A failure/cancellation race must not produce an image.")
      } catch is CancellationError {
        #expect(driver.cancellations == [driver.requestID])
      } catch RequestFailure.failed {
        #expect(driver.cancellations.isEmpty)
      } catch {
        Issue.record("Unexpected terminal error: \(error)")
      }
    }
  }
}
