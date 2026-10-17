import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.serialized)
  struct ManualExportFeedbackViewTests {
    @MainActor
    private final class Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let suite = "ManualFeedbackView-\(UUID().uuidString)"
      let defaults: UserDefaults
      let timeline: ExportRecordStore
      let collections: CollectionExportRecordStore
      let manager: ExportManager
      let destination = FakeExportDestination()
      let destinationManager: ExportDestinationManager
      let autoSync = AutoSyncManager()
      let counter = BodyInvalidationCounter()
      var window: NSWindow?
      var settingsWindow: NSWindow?
      var selectedAtOpen: String?

      init() {
        defaults = UserDefaults(suiteName: suite)!
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
            .environmentObject(manager).environmentObject(autoSync).environmentObject(
              destinationManager
            )
            .environmentObject(timeline).environmentObject(collections)
            .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults))
        let owned = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 620),
          styleMask: [.borderless], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        settingsWindow = owned
        owned.orderFront(nil)
      }

      func close() {
        window?.contentView = nil
        window?.close()
        settingsWindow?.contentView = nil
        settingsWindow?.close()
        counter.reset()
        manager.cancelAndClear()
        timeline.flushForTesting()
        collections.flushForTesting()
        destination.cleanup()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func observe(_ condition: () -> Bool) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(15))
      while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
      return condition()
    }

    private func reached(_ gate: AsyncCheckpoint) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(15))
      while await gate.enteredSoFar == 0, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await gate.enteredSoFar > 0
    }

    @Test func failureShowsOutcomeAndSelectsIssuesBeforeOpeningSettings() async throws {
      let f = Fixture()
      defer { f.close() }
      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: nil)
      f.show()
      let rendered = await observe { f.counter.renderedText["progress-message"] != nil }
      try #require(rendered)
      #expect(f.counter.renderedText["progress-message"] == ["2 exported · 1 failed"])
      let issues = try #require(f.counter.renderedActions["progress-view-issues"])
      issues()
      #expect(f.selectedAtOpen == SettingsTab.exportIssues.rawValue)
      f.showSettings()
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
      defer {
        Task {
          await expiry.releaseAll()
          f.close()
        }
      }
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
    }

    @Test func oldSuccessExpiryCannotDismissNewFailure() async throws {
      let f = Fixture()
      let expiry = AsyncCheckpoint()
      defer {
        Task {
          await expiry.releaseAll()
          f.close()
        }
      }
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
    }

  }
#endif
