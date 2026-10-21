import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct ManualExportFeedbackViewTests {
    @MainActor
    private final class LoginService: LoginItemService {
      var status: LoginItemController.Status { .notRegistered }
      func register() throws {}
      func unregister() throws {}
      func openSystemLoginItems() {}
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("ManualExportFeedbackView")
      let suite = TestScratch.suiteName("ManualFeedbackView")
      let defaults: UserDefaults
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let destinationManager: ExportDestinationManager
      let autoSync = AutoSyncManager()
      let library = PhotoLibraryManager(overrideService: FakePhotoLibraryService())
      let lifecycle = AppLifecycleCoordinator(
        cancelActiveWork: {}, interruptForDestinationUnavailable: {},
        configureRecordStores: { _ in .success })
      let scopeStore: UserDefaultsAutoExportScopeStore
      let loginItem = LoginItemController(service: LoginService())
      let safetyMonitor: DestinationSafetyMonitor
      let photoChangeAdapter: PhotoLibraryPersistentChangeAdapter
      let counter = BodyInvalidationCounter()
      var window: NSWindow?
      var settingsWindow: NSWindow?
      var selectedAtOpen: String?

      init() {
        defaults = TestScratch.defaults(suiteName: suite)
        defaults.set(SettingsTab.advanced.rawValue, forKey: SettingsTab.storageKey)
        timeline = ExportRecordStore(baseDirectoryURL: root)
        collections = CollectionExportRecordStore(baseDirectoryURL: root)
        timeline.configure(for: "A")
        collections.configure(for: "A")
        manager = ExportManager(
          photoLibraryService: FakePhotoLibraryService(), exportDestination: destination,
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          assetResourceWriter: FakeAssetResourceWriter(), fileSystem: FakeFileSystem(),
          userDefaults: defaults)
        destinationManager = ExportDestinationManager(skipRestore: true, userDefaults: defaults)
        destinationManager.configureForScreenshotMode()
        scopeStore = UserDefaultsAutoExportScopeStore(userDefaults: defaults)
        safetyMonitor = DestinationSafetyMonitor(
          identityPublisher: destinationManager.$identity.eraseToAnyPublisher(),
          exportRecordStore: timeline, collectionExportRecordStore: collections,
          confirmationStore: InMemoryDestinationSafetyConfirmationStore(), scanDirectory: { false })
        photoChangeAdapter = PhotoLibraryPersistentChangeAdapter(
          tokenStore: GlobalPhotoChangeTokenStore(
            fileURL: root.appendingPathComponent("token.data")),
          clock: TestClock())
        manager.progressState.totalJobsEnqueued = 3
        manager.progressState.totalJobsCompleted = 3
      }

      func show(successDelay: @escaping @Sendable () async throws -> Void = {}) {
        let hosted = NSHostingView(
          rootView: ExportProgressBar(
            successDelay: successDelay,
            settingsOpener: { [weak self] in
              guard let self else { return }
              selectedAtOpen = defaults.string(forKey: SettingsTab.storageKey)
            }
          )
          .environmentObject(manager).environmentObject(manager.progressState)
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 120),
          styleMask: [.borderless], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        window = owned
        owned.orderFront(nil)
      }

      func showSettings() {
        let hosted = NSHostingView(
          rootView: SettingsRootView()
            .environmentObject(library)
            .environmentObject(manager).environmentObject(autoSync).environmentObject(
              destinationManager
            )
            .environmentObject(timeline).environmentObject(collections)
            .environmentObject(lifecycle).environmentObject(scopeStore).environmentObject(loginItem)
            .environmentObject(safetyMonitor).environmentObject(photoChangeAdapter)
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults)
            .onAppear { [counter] in counter.record("settings-root-visible") })
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 620),
          styleMask: [.borderless], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        settingsWindow = owned
        owned.orderFront(nil)
      }

      func close() {
        photoChangeAdapter.stop()
        window?.contentView = nil
        window?.close()
        settingsWindow?.contentView = nil
        settingsWindow?.close()
        counter.reset()
        manager.cancelAndClear()
        timeline.drainSynchronously()
        collections.drainSynchronously()
        destination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func reached(_ gate: AsyncCheckpoint) async -> Bool {
      await gate.waitForEnter(count: 1)
    }

    @Test(arguments: [false, true])
    func failureShowsOutcomeAndSelectsIssuesBeforeOpeningSettings(settingsAlreadyOpen: Bool)
      async throws
    {
      let f = Fixture()
      defer { f.close() }
      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: nil)
      f.show()
      let rendered = await observe { f.counter.renderedText["progress-message"] != nil }
      try #require(rendered)
      #expect(f.counter.renderedText["progress-message"] == ["2 exported · 1 failed"])
      let issues = try #require(f.counter.renderedActions["progress-view-issues"])
      if settingsAlreadyOpen {
        f.defaults.set(SettingsTab.autoExport.rawValue, forKey: SettingsTab.storageKey)
        f.showSettings()
        let mounted = await observe { f.counter.count(for: "settings-root-visible") > 0 }
        try #require(mounted)
      }
      issues()
      #expect(f.selectedAtOpen == SettingsTab.exportIssues.rawValue)
      if !settingsAlreadyOpen { f.showSettings() }
      let issuesShown = await observe {
        f.counter.renderedText["settings-visible-tab"] == ["Export Issues"]
      }
      #expect(issuesShown, "The shared Settings binding must show the actual issues tab")
      let dismiss = try #require(f.counter.renderedActions["progress-dismiss"])
      dismiss()
      f.selectedAtOpen = nil
      issues()
      #expect(f.selectedAtOpen == nil, "A retained action must not reopen a dismissed summary")
    }
    @Test func dismissRetiresOldCountersAndCannotDismissReplacement() async throws {
      let f = Fixture()
      defer { f.close() }
      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: nil)
      f.show()
      let ready = await observe { f.counter.renderedActions["progress-dismiss"] != nil }
      try #require(ready)
      let oldDismiss = try #require(f.counter.renderedActions["progress-dismiss"])
      let replacement = ManualExportSummary(completedCount: 4, failedCount: 2, failureMessage: nil)
      f.manager.progressState.manualSummary = replacement
      oldDismiss()
      #expect(f.manager.progressState.manualSummary?.isDismissed == false)
      let changed = await observe {
        f.counter.renderedText["progress-message"] == ["2 exported · 2 failed"]
      }
      try #require(changed)
      let dismiss = try #require(f.counter.renderedActions["progress-dismiss"])
      dismiss()
      let hidden = await observe { f.counter.renderedText["progress-visible"] == ["false"] }
      #expect(hidden)
      #expect(f.counter.renderedText["progress-message"] == [])
      #expect(f.manager.progressState.totalJobsEnqueued == 3)
      #expect(f.manager.progressState.totalJobsCompleted == 3)
    }

    @Test func successExpiryRetiresCounters() async throws {
      let f = Fixture()
      let expiry = AsyncCheckpoint()
      try await withCleanup {
        f.manager.progressState.manualSummary = ManualExportSummary(
          completedCount: 3, failedCount: 0, failureMessage: nil)
        f.show(successDelay: { await expiry.enter() })
        let shown = await observe {
          f.counter.renderedText["progress-message"] == ["Export complete"]
        }
        try #require(shown)
        try #require(await reached(expiry))
        await expiry.releaseAll()
        let hidden = await observe { f.counter.renderedText["progress-visible"] == ["false"] }
        #expect(hidden)
        #expect(f.counter.renderedText["progress-message"] == [])
        #expect(f.manager.progressState.totalJobsCompleted == 3)
      } cleanup: {
        await expiry.releaseAll()
        f.close()
      }
    }

    @Test func oldSuccessExpiryCannotDismissNewFailure() async throws {
      let f = Fixture()
      let expiry = AsyncCheckpoint()
      try await withCleanup {
        let success = ManualExportSummary(completedCount: 3, failedCount: 0, failureMessage: nil)
        f.manager.progressState.manualSummary = success
        f.show(successDelay: { await expiry.enter() })
        try #require(await reached(expiry))
        let failure = ManualExportSummary(completedCount: 3, failedCount: 1, failureMessage: nil)
        f.manager.progressState.manualSummary = failure
        await expiry.releaseAll()
        let oldFinished = await observe {
          f.counter.count(for: "progress-expiry-finished:\(success.id)") == 1
        }
        try #require(oldFinished)
        #expect(f.manager.progressState.manualSummary?.id == failure.id)
        #expect(f.manager.progressState.manualSummary?.isDismissed == false)
        let shown = await observe {
          f.counter.renderedText["progress-message"] == ["2 exported · 1 failed"]
        }
        #expect(shown)
      } cleanup: {
        await expiry.releaseAll()
        f.close()
      }
    }

  }
#endif
