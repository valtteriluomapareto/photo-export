import AppKit
import Foundation
import Photos
import os

/// Owns one asynchronous PhotoKit image request. PhotoKit may call back before
/// `requestImage` returns its ID, after cancellation, or more than once (a degraded
/// image followed by a final image). The lock protects only the small state
/// transition; continuation resumes and PhotoKit cancellation happen outside it.
final class FullImageRequestBridge: @unchecked Sendable {
  typealias Callback = @Sendable (Result<NSImage, Error>?) -> Void

  private struct State {
    var continuation: CheckedContinuation<NSImage, Error>?
    var requestID: PHImageRequestID?
    var isTerminal = false
    var wasCancelled = false
    var didCancelRequest = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let cancelRequest: @Sendable (PHImageRequestID) -> Void

  init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void) {
    self.cancelRequest = cancelRequest
  }

  /// PhotoKit may send a degraded preview before its final response. An error or
  /// cancellation is terminal even if that callback also marks the image degraded.
  static func response(
    image: NSImage?, info: [AnyHashable: Any]?, missingImageError: Error
  ) -> Result<NSImage, Error>? {
    if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true {
      return .failure(CancellationError())
    }
    if let error = info?[PHImageErrorKey] as? Error {
      return .failure(error)
    }
    if (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true {
      return nil
    }
    if let image { return .success(image) }
    return .failure(missingImageError)
  }

  /// `start` must return the ID for the request whose callback it installs. A nil
  /// callback result means a degraded image and leaves the continuation pending.
  /// Cancellation resumes immediately even if PhotoKit never sends a callback.
  @MainActor
  func request(start: (@escaping Callback) -> PHImageRequestID) async throws -> NSImage {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let shouldStart = state.withLock { state in
          guard !state.isTerminal else { return false }
          state.continuation = continuation
          return true
        }
        guard shouldStart else {
          continuation.resume(throwing: CancellationError())
          return
        }

        let requestID = start { [self] result in
          if let result { complete(result) }
        }
        installRequestID(requestID)
      }
    } onCancel: {
      cancel()
    }
  }

  private func installRequestID(_ requestID: PHImageRequestID) {
    let shouldCancel = state.withLock { state in
      state.requestID = requestID
      guard state.wasCancelled, !state.didCancelRequest else { return false }
      state.didCancelRequest = true
      return true
    }
    if shouldCancel { cancelRequest(requestID) }
  }

  private func complete(_ result: Result<NSImage, Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<NSImage, Error>? in
      guard !state.isTerminal else { return nil }
      state.isTerminal = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }

  private func cancel() {
    let (continuation, requestID) = state.withLock { state in
      guard !state.isTerminal else {
        return (nil as CheckedContinuation<NSImage, Error>?, nil as PHImageRequestID?)
      }
      state.isTerminal = true
      state.wasCancelled = true
      let continuation = state.continuation
      state.continuation = nil
      let requestID: PHImageRequestID?
      if let installedID = state.requestID, !state.didCancelRequest {
        state.didCancelRequest = true
        requestID = installedID
      } else {
        requestID = nil
      }
      return (continuation, requestID)
    }
    continuation?.resume(throwing: CancellationError())
    if let requestID { cancelRequest(requestID) }
  }
}
