import AppKit
import Combine
import Observation
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  @MainActor
  @Suite(.timeLimit(.minutes(2)), .serialized)
  struct ManualExportFeedbackViewTests {
    @Observable
    final class RenderTick { var value = 0 }

    private struct RenderBarrier: View {
      let tick: RenderTick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("progress-barrier:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }

    @MainActor
    private final class LoginService: LoginItemService {
      var status: LoginItemController.Status = .notRegistered
      func register() throws {}
      func unregister() throws {}
      func openSystemLoginItems() {}
    }

    @MainActor
    private final class Fixture {
      let root = TestScratch.directory("ManualExportFeedbackView")
      let suite = TestScratch.suiteName("ManualFeedbackView")
      let defaults: UserDefaults
      let core: AppCore
      var timeline: ExportRecordStore { core.exportRecordStore }
      var collections: CollectionExportRecordStore { core.collectionExportRecordStore }
      var manager: ExportManager { core.exportManager }
      let loginService = LoginService()
      var loginItem: LoginItemController { core.loginItemController }
      let counter = BodyInvalidationCounter()
      let tick = RenderTick()
      var window: NSWindow?
      var hosted: NSView?
      var settingsWindow: NSWindow?
      var selectedAtOpen: String?

      init() async {
        defaults = TestScratch.defaults(suiteName: suite)
        defaults.set(SettingsTab.advanced.rawValue, forKey: SettingsTab.storageKey)
        var composition = AppCoreTestHarness.makeTestComposition(label: "ManualFeedbackCore")
        composition.defaults = defaults
        composition.appStateRoot = root
        composition.loginItemService = loginService
        core = AppCoreTestHarness.makeCore(composition)
        core.exportDestinationManager.configureForScreenshotMode()
        await timeline.configureAndWait(for: "A")
        await collections.configureAndWait(for: "A")
        manager.progressState.totalJobsEnqueued = 3
        manager.progressState.totalJobsCompleted = 3
      }

      func show(
        initialSize: CGSize = CGSize(width: 800, height: 120),
        progress: ExportProgressState? = nil,
        successDelay: @escaping @Sendable () async throws -> Void = {}
      ) {
        let hosted = NSHostingView(
          rootView: ExportProgressBar(
            successDelay: successDelay,
            settingsOpener: { [weak self] in
              guard let self else { return }
              selectedAtOpen = defaults.string(forKey: SettingsTab.storageKey)
            }
          )
          .environment(manager).environment(progress ?? manager.progressState)
          .overlay { RenderBarrier(tick: tick, counter: counter) }
          .environment(\.bodyInvalidationCounter, counter).defaultAppStorage(defaults))
        let owned = NSWindow(
          contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: initialSize),
          styleMask: [.borderless], backing: .buffered, defer: false)
        owned.isReleasedWhenClosed = false
        owned.contentView = hosted
        self.hosted = hosted
        window = owned
        owned.orderFront(nil)
      }

      func renderBarrier() async throws {
        tick.value += 1
        let key = "progress-barrier:\(tick.value)"
        try #require(await observe(in: window) { counter.count(for: key) > 0 })
        window?.contentView?.layoutSubtreeIfNeeded()
      }

      func showSettings() {
        let hosted = NSHostingView(
          rootView: SettingsRootView()
            .photoExportEnvironment(core)
            .environment(\.bodyInvalidationCounter, counter)
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
        core.autoSyncPhotoChangeAdapter.stop()
        window?.contentView = nil
        window?.close()
        hosted = nil
        settingsWindow?.contentView = nil
        settingsWindow?.close()
        counter.reset()
        manager.cancelAndClear()
        timeline.drainSynchronously()
        collections.drainSynchronously()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
      }
    }

    private func reached(_ gate: AsyncCheckpoint) async -> Bool {
      await gate.waitForEnter(count: 1)
    }

    private func settledContentSize(in f: Fixture) async throws -> CGSize {
      let window = try #require(f.window)
      let hosted = try #require(f.hosted)
      var previous = CGSize.zero
      var stablePasses = 0
      let settled = await observe {
        hosted.layoutSubtreeIfNeeded()
        let size = window.contentLayoutRect.size
        guard size.width > 0, size.height > 0 else { return false }
        stablePasses = size == previous ? stablePasses + 1 : 0
        previous = size
        return stablePasses >= 3
      }
      try #require(settled, "The fitted summary window did not settle")
      #expect(window.contentLayoutRect.height >= hosted.fittingSize.height)
      return window.contentLayoutRect.size
    }

    @Test
    func progressContentWaitsForClockTicksAndShowsLatestValues() async throws {
      let f = await Fixture()
      defer { f.close() }
      let clock = TestClock()
      let progress = ExportProgressState(clock: clock)
      progress.totalJobsEnqueued = 4
      progress.currentAssetFilename = "first.JPG"
      clock.advance(by: 0.2)
      f.show(progress: progress)
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["progress-message"] == ["0/4 assets"]
            && f.counter.renderedText["progress-asset"]?.first == "first.JPG"
        })
      try await f.renderBarrier()
      let bodies = f.counter.count(for: "export-progress-body")
      progress.totalJobsCompleted = 1
      progress.currentAssetFilename = "intermediate.JPG"
      progress.totalJobsCompleted = 2
      progress.totalJobsEnqueued = 5
      progress.currentAssetFilename = "latest.JPG"
      progress.renderActivity = .rendering
      try await f.renderBarrier()
      #expect(progress.totalJobsCompleted == 2)
      #expect(progress.totalJobsEnqueued == 5)
      #expect(f.counter.count(for: "export-progress-body") - bodies == 0)
      #expect(f.counter.renderedText["progress-message"] == ["0/4 assets"])
      clock.advance(by: 0.2)
      try #require(
        await observe(in: f.window) {
          f.counter.renderedText["progress-message"] == ["2/5 assets"]
            && f.counter.renderedText["progress-asset"] == ["latest.JPG", "rendering"]
        })
      #expect(f.counter.count(for: "export-progress-body") > bodies)
    }

    @Test(arguments: [120.0, 600.0])
    func multilineFailureFitsFirstLayoutAndMountedReplacements(initialHeight: Double) async throws {
      let f = await Fixture()
      defer { f.close() }
      let path =
        "/Volumes/Family Photo Backup/Collections/Albums/"
        + "Summer trips with family and friends/Coastal walks and mountain holidays/"
        + "Original photos and edited copies/2026/09/IMG_20260914_123456_original.HEIC"
      let detail =
        "The export could not finish writing its history for \(path). "
        + "The backup drive disconnected before the history could be saved. "
        + "Reconnect the drive, keep Photo Export open to preserve unsaved progress, "
        + "and retry saving export history before starting another export."
      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: detail)
      f.show(initialSize: CGSize(width: 480, height: initialHeight))
      let rendered = await observe {
        f.counter.renderedText["progress-message"] == ["2 exported · 1 failed"]
      }
      try #require(rendered)
      let narrow = try await settledContentSize(in: f)
      #expect(narrow.width == 480)
      let oldDismiss = try #require(f.counter.renderedActions["progress-dismiss"])
      let oldIssues = try #require(f.counter.renderedActions["progress-view-issues"])

      let window = try #require(f.window)
      window.setContentSize(CGSize(width: 800, height: narrow.height))
      let wide = try await settledContentSize(in: f)
      #expect(wide.width == 800)
      #expect(narrow.height > wide.height, "Narrow columns must wrap the full failure detail")

      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: nil)
      let shortened = await observe { window.contentLayoutRect.height < wide.height }
      try #require(shortened)
      let short = try await settledContentSize(in: f)
      oldIssues()
      oldDismiss()
      #expect(f.selectedAtOpen == nil)
      #expect(f.manager.progressState.manualSummary?.isDismissed == false)

      f.manager.progressState.manualSummary = ManualExportSummary(
        completedCount: 3, failedCount: 1, failureMessage: detail)
      let expanded = await observe { window.contentLayoutRect.height > short.height }
      try #require(expanded)
      let replaced = try await settledContentSize(in: f)
      #expect(replaced.width == 800)
      #expect(replaced.height == wide.height)
      let issues = try #require(f.counter.renderedActions["progress-view-issues"])
      issues()
      #expect(f.selectedAtOpen == SettingsTab.exportIssues.rawValue)
      let dismiss = try #require(f.counter.renderedActions["progress-dismiss"])
      dismiss()
      let hidden = await observe { f.counter.renderedText["progress-visible"] == ["false"] }
      #expect(hidden)
    }

    @Test(arguments: [false, true])
    func failureShowsOutcomeAndSelectsIssuesBeforeOpeningSettings(settingsAlreadyOpen: Bool)
      async throws
    {
      let f = await Fixture()
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
    @Test func settingsSharedEnvironmentSupportsAllTabs() async throws {
      let f = await Fixture()
      defer { f.close() }
      f.defaults.set(SettingsTab.autoExport.rawValue, forKey: SettingsTab.storageKey)
      f.showSettings()
      for title in ["Auto Export", "Export Issues", "Advanced"] {
        let tab: SettingsTab =
          title == "Auto Export"
          ? .autoExport : title == "Export Issues" ? .exportIssues : .advanced
        f.defaults.set(tab.rawValue, forKey: SettingsTab.storageKey)
        try #require(
          await observe(in: f.settingsWindow) {
            f.counter.renderedText["settings-visible-tab"] == [title]
          })
      }
    }

    /// The Auto Export tab's login toggle and footer read the controller's status, so a
    /// refresh that finds a new status must re-render them.
    @Test func autoExportTabFollowsLoginItemStatus() async throws {
      let f = await Fixture()
      defer { f.close() }
      f.defaults.set(SettingsTab.autoExport.rawValue, forKey: SettingsTab.storageKey)
      f.showSettings()
      let initial = LoginItemController.Status.notRegistered.footerText
      try #require(await observe { f.counter.renderedText["login-item-footer"] == [initial] })
      f.loginService.status = .requiresApproval
      f.loginItem.refresh()
      let updated = LoginItemController.Status.requiresApproval.footerText
      #expect(await observe { f.counter.renderedText["login-item-footer"] == [updated] })
    }

    @Test func dismissRetiresOldCountersAndCannotDismissReplacement() async throws {
      let f = await Fixture()
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
      let f = await Fixture()
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
      let f = await Fixture()
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
