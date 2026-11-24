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
      let library: PhotoLibraryManager
      var body: some View {
        Group {
          if library.isAuthorized {
            Text("Authorized content")
          } else {
            AuthorizationView(photoLibraryManager: library)
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
      let library: PhotoLibraryManager
      let initialAuthorizationReads: Int
      let opened = URLCapture()
      let window: NSWindow

      init(status: PHAuthorizationStatus = .denied) {
        service.authorizationStatus = status
        service.isAuthorized = PhotoLibraryManager.isAuthorizationSufficient(status)
        library = PhotoLibraryManager(overrideService: service)
        initialAuthorizationReads = service.authorizationStatusReads
        library.observeAppActivation(notificationCenter: notifications)
        let capture = opened
        let content = Host(library: library)
          .environment(\.accessibilityEnabled, true)
          .environment(
            \.openURL,
            OpenURLAction { url in
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
      }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PHAuthorizationStatus.authorized, .limited])
    func activationLeavesDeniedPaneAfterAccessIsGranted(status: PHAuthorizationStatus) async throws
    {
      let f = Fixture()
      defer { f.close() }
      f.show()
      try #require(
        await observe { f.service.authorizationStatusReads > f.initialAuthorizationReads })
      let revision = f.library.libraryRevision
      // Status is authoritative even if a service's separate convenience flag is stale.
      f.service.authorizationStatus = status
      f.activate()
      #expect(await observe { NativeViewAccess.containsText("Authorized content", in: f.window) })
      #expect(f.library.authorizationStatus == status && f.library.isAuthorized)
      #expect(f.library.libraryRevision == revision + 1)
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    /// The refresh runs app-wide, not only while the access screen shows, so a revoke made
    /// while the app was in the background shows the access screen on return.
    @Test(.timeLimit(.minutes(1)), arguments: [PHAuthorizationStatus.denied, .restricted])
    func activationShowsTheAccessScreenAfterAccessIsRevoked(status: PHAuthorizationStatus)
      async throws
    {
      let f = Fixture(status: .authorized)
      defer { f.close() }
      f.show()
      try #require(
        await observe { NativeViewAccess.containsText("Authorized content", in: f.window) })
      f.service.authorizationStatus = status
      f.activate()
      #expect(
        await observe {
          NativeViewAccess.containsText("Photo Library Access Required", in: f.window)
        })
      #expect(!f.library.isAuthorized && f.library.authorizationStatus == status)
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    @Test(arguments: [PHAuthorizationStatus.denied, .restricted])
    func repeatedDeniedActivationsDoNotRequestAccessOrInvalidate(status: PHAuthorizationStatus)
      async throws
    {
      let f = Fixture(status: status)
      defer { f.close() }
      f.show()
      try #require(
        await observe { f.service.authorizationStatusReads > f.initialAuthorizationReads })
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
      #expect(await observe { NativeViewAccess.containsText("Authorized content", in: f.window) })
      #expect(f.service.requestAuthorizationCalls == 0)
    }

    @Test func settingsActionOpensTheExistingPhotosPrivacyURL() async throws {
      let f = Fixture()
      defer { f.close() }
      f.show()
      try #require(
        await observe(in: f.window) {
          NativeViewAccess.containsText("Photo Library Access Required", in: f.window)
        })
      #expect(
        NativeViewAccess.containsText(
          "Turn on Photos access for Photo Export in System Settings → Privacy & Security → Photos.",
          in: f.window))
      let button = try #require(NativeViewAccess.button("Open System Settings", in: f.window))
      #expect(button.isAccessibilityEnabled?() == true)
      #expect(button.accessibilityPerformPress?() == true)
      try #require(await observe(in: f.window) { f.opened.urls.count == 1 })
      #expect(
        f.opened.urls.map(\.absoluteString) == [
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func authorizationSubscriberSeesInstalledInvalidationBarrierAndFreshCounts() async throws {
      let service = FakePhotoLibraryService()
      service.authorizationStatus = .denied
      service.isAuthorized = false
      let scope = PhotoFetchScope.timeline(year: 2026, month: 9)
      service.assetsByYearMonth["2026-9"] = [
        TestAssetFactory.makeAsset(
          id: "old",
          creationDate: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!)
      ]
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
      let observation = manager.isAuthorizedPublisher.dropFirst().sink { authorized in
        guard authorized else { return }
        revisionAtAuthorization = manager.libraryRevision
        query = Task { try await manager.cachedCountAssets(in: scope) }
      }
      service.assetsByYearMonth["2026-9"]?.append(
        TestAssetFactory.makeAsset(
          id: "new",
          creationDate: Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 15))!)
      )
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
        service.assetsByYearMonth["2026-9"]?.append(
          TestAssetFactory.makeAsset(
            id: "later",
            creationDate: Calendar.current.date(
              from: DateComponents(year: 2026, month: 9, day: 15))!))
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
