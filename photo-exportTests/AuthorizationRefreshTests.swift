import AppKit
import Combine
import Photos
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct AuthorizationRefreshTests {
    @MainActor
    private struct Host: View {
      @ObservedObject var library: PhotoLibraryManager
      let notifications: NotificationCenter
      let counter: BodyInvalidationCounter
      var body: some View {
        let route = library.isAuthorized ? "authorized" : "authorization"
        let _ = counter.recordText([route], for: "authorization-route")
        Group {
          if library.isAuthorized {
            Text("Authorized content")
          } else {
            AuthorizationView(
              activationNotifications: notifications, photoLibraryManager: library)
          }
        }
      }
    }

    @MainActor
    private final class URLCapture {
      var urls: [URL] = []
    }

    @MainActor
    private final class Fixture {
      let service = FakePhotoLibraryService()
      let notifications = NotificationCenter()
      let counter = BodyInvalidationCounter()
      let library: PhotoLibraryManager
      let opened = URLCapture()
      let window: NSWindow

      init(status: PHAuthorizationStatus = .denied) {
        service.authorizationStatus = status
        service.isAuthorized = PhotoLibraryManager.isAuthorizationSufficient(status)
        library = PhotoLibraryManager(overrideService: service)
        library.observeAppActivation(notificationCenter: notifications)
        let capture = opened
        let content = Host(library: library, notifications: notifications, counter: counter)
          .environment(\.bodyInvalidationCounter, counter)
          .environment(\.openURL, OpenURLAction { url in
            capture.urls.append(url)
            return .handled
          })
        window = NSWindow(
          contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
      }

      func show() { window.orderFront(nil) }
      func activate() {
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
      }
      func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        counter.reset()
      }
    }

    private func observe(
      _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await eventually("observed condition", sourceLocation: sourceLocation) { condition() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PHAuthorizationStatus.authorized, .limited])
    func activationLeavesDeniedPaneAfterAccessIsGranted(status: PHAuthorizationStatus) async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      try #require(await observe { f.counter.count(for: "authorization-initial-check-complete") > 0 })
      let revision = f.library.libraryRevision
      // Status is authoritative even if a service's separate convenience flag is stale.
      f.service.authorizationStatus = status
      f.activate()
      #expect(await observe { f.counter.renderedText["authorization-route"] == ["authorized"] })
      #expect(f.library.authorizationStatus == status && f.library.isAuthorized)
      #expect(f.library.libraryRevision == revision + 1)
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    /// The refresh runs app-wide, not only while the access screen shows, so a revoke made
    /// while the app was in the background shows the access screen on return.
    @Test(.timeLimit(.minutes(1)), arguments: [PHAuthorizationStatus.denied, .restricted])
    func activationShowsTheAccessScreenAfterAccessIsRevoked(status: PHAuthorizationStatus) async throws {
      let f = Fixture(status: .authorized)
      defer { f.close() }
      f.show()
      try #require(await observe { f.counter.renderedText["authorization-route"] == ["authorized"] })
      f.service.authorizationStatus = status
      f.activate()
      #expect(await observe { f.counter.renderedText["authorization-route"] == ["authorization"] })
      #expect(!f.library.isAuthorized && f.library.authorizationStatus == status)
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    @Test(arguments: [PHAuthorizationStatus.denied, .restricted])
    func repeatedDeniedActivationsDoNotRequestAccessOrInvalidate(status: PHAuthorizationStatus) async throws {
      let f = Fixture(status: status)
      defer { f.close() }
      f.show()
      try #require(await observe { f.counter.count(for: "authorization-initial-check-complete") > 0 })
      let revision = f.library.libraryRevision
      f.activate()
      f.activate()
      #expect(!f.library.isAuthorized && f.library.authorizationStatus == status)
      #expect(f.library.libraryRevision == revision)
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    @Test func initialNotDeterminedRequestsOnceAndActivationDoesNotRequestAgain() async throws {
      let f = Fixture(status: .notDetermined)
      defer { f.close() }
      f.show()
      try #require(await observe { f.service.requestAuthorizationCalls == 1 })
      f.activate()
      f.activate()
      #expect(f.service.requestAuthorizationCalls == 1)
    }

    @Test func grantBeforeFirstAppearanceLeavesAuthorizationWithoutPrompt() async {
      let f = Fixture()
      defer { f.close() }
      f.service.authorizationStatus = .authorized
      f.show()
      #expect(await observe { f.counter.renderedText["authorization-route"] == ["authorized"] })
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    @Test func settingsActionOpensTheExistingPhotosPrivacyURL() async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      try #require(await observe { f.counter.renderedActions["authorization-open-settings"] != nil })
      let action = try #require(f.counter.renderedActions["authorization-open-settings"])
      action()
      #expect(f.opened.urls.map(\.absoluteString) == [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
      ])
    }

    @Test(.timeLimit(.minutes(1)))
    func authorizationSubscriberSeesInstalledInvalidationBarrierAndFreshCounts() async throws {
      let service = FakePhotoLibraryService()
      service.authorizationStatus = .denied
      service.isAuthorized = false
      let scope = PhotoFetchScope.timeline(year: 2026, month: 9)
      service.assetsByYearMonth["2026-9"] = [TestAssetFactory.makeAsset(id: "old")]
      #expect(try await service.cachedCountAssets(in: scope) == 1)
      let gate = AsyncCheckpoint()
      var waits = 0
      let manager = PhotoLibraryManager(
        overrideService: service,
        countInvalidationOverride: {
          await gate.enter()
          await service.collectionCountCache.invalidateAll()
        }, countInvalidationWaitObserver: { waits += 1 })
      var revisionAtAuthorization: Int?
      var query: Task<Int, Error>?
      let observation = manager.$isAuthorized.dropFirst().sink { authorized in
        guard authorized else { return }
        revisionAtAuthorization = manager.libraryRevision
        query = Task { try await manager.cachedCountAssets(in: scope) }
      }
      service.assetsByYearMonth["2026-9"]?.append(TestAssetFactory.makeAsset(id: "new"))
      service.authorizationStatus = .authorized
      manager.refreshAuthorizationStatus()
      var failure: Error?
      do {
        #expect(revisionAtAuthorization == 1)
        try #require(await observe { waits > 0 })
        await gate.releaseAll()
        let read = try #require(query)
        #expect(try await read.value == 2)
        let revision = manager.libraryRevision
        service.assetsByYearMonth["2026-9"]?.append(TestAssetFactory.makeAsset(id: "later"))
        manager.refreshAuthorizationStatus()
        #expect(manager.libraryRevision == revision)
        #expect(try await manager.cachedCountAssets(in: scope) == 2)
      } catch { failure = error }
      await gate.releaseAll()
      _ = try? await query?.value
      withExtendedLifetime(observation) {}
      if let failure { throw failure }
    }
  }
#endif
