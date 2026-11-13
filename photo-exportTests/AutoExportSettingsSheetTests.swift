import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// Real settings controls must present a recovery sheet with the current app manager.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct AutoExportSettingsSheetTests {
    private final class RenderTick: ObservableObject {
      @Published var value = 0
    }

    private struct RenderWitness: View {
      @ObservedObject var tick: RenderTick
      let counter: BodyInvalidationCounter
      var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = counter.record("settings-render:\(tick.value)")
        Color.clear.frame(width: 1, height: 1)
      }
    }
    private func expectHeader(_ title: String, in window: NSWindow) async throws {
      try #require(await observe(in: window) { window.attachedSheet != nil })
      let sheet = try #require(window.attachedSheet)
      try #require(
        await observe(in: sheet) {
          NativeViewAccess.containsText(title, in: sheet)
        }, "The attached recovery sheet must render its actual header")
    }

    /// Sheet buttons are listed accessibility children; a banner button inside the Settings
    /// Form is reached by hit-testing.
    private func control(_ title: String, in window: NSWindow) -> AnyObject? {
      NativeViewAccess.button(title, in: window)
        ?? NativeViewAccess.hitTestButton(title, in: window)
    }

    private func press(_ title: String, in window: NSWindow) async throws {
      try #require(await observe(in: window) { control(title, in: window) != nil })
      let button = try #require(control(title, in: window))
      #expect(button.isAccessibilityEnabled?() == true)
      let press: (() -> Bool)? = button.accessibilityPerformPress
      let action = try #require(press)
      _ = action()
    }

    private func close(_ window: NSWindow, core: AppCore, counter: BodyInvalidationCounter) async {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        sheet.close()
      }
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      core.autoSyncManager.setEnabled(false)
      core.autoSyncPhotoChangeAdapter.stop()
      core.exportManager.cancelAndClear()
      counter.reset()
      try? await core.exportRecordStore.flush()
      try? await core.collectionExportRecordStore.flush()
      try? FileManager.default.removeItem(at: core.composition.appStateRoot)
    }

    /// A completed rebuild clears its prompt before the sheet shows the result and its Done
    /// button, so Settings must keep presenting the sheet once the banner is gone.
    private func expectSheetOutlivesPrompt(
      _ banner: String, sheet: NSWindow, in window: NSWindow, clearPrompt: () -> Void
    ) async throws {
      try #require(
        await observe(in: window) { control(banner, in: window) != nil },
        "The banner must still be shown while its sheet is open")
      clearPrompt()
      try #require(
        await observe(in: window) { control(banner, in: window) == nil },
        "The banner must leave Settings once its prompt clears")
      try #require(
        window.attachedSheet === sheet && sheet.isVisible,
        "The recovery sheet must outlive its prompt to show the rebuild result")
    }

    @Test func safetyConfirmationSheetRendersWithTheManager() async throws {
      let core = AppCoreTestHarness.makeCore(
        AppCoreTestHarness.makeTestComposition(label: "settings-safety-sheet"))
      await core.exportRecordStore.configureAndWait(for: "A")
      await core.collectionExportRecordStore.configureAndWait(for: "A")
      let identity = CurrentValueSubject<DestinationIdentity, Never>(
        DestinationIdentity(stableId: "A", fingerprint: nil))
      let safety = DestinationSafetyMonitor(
        identityPublisher: identity.eraseToAnyPublisher(),
        exportRecordStore: core.exportRecordStore,
        collectionExportRecordStore: core.collectionExportRecordStore,
        confirmationStore: InMemoryDestinationSafetyConfirmationStore(), scanDirectory: { true })
      let counter = BodyInvalidationCounter()
      let window = AppCoreTestHarness.settingsWindow(core: core, counter: counter, safety: safety)
      try await withCleanup {
        safety.attach()
        try #require(await eventually("safety scan completed") { safety.needsSafetyConfirmation })
        window.orderFront(nil)
        #expect(window.attachedSheet == nil)
        try await press("Review…", in: window)
        try await expectHeader("Confirm This Destination", in: window)
        let sheet = try #require(window.attachedSheet)
        try await expectSheetOutlivesPrompt("Review…", sheet: sheet, in: window) {
          safety.confirmCurrentDestination()
        }
        try await press("Use This Destination", in: sheet)
        try #require(
          await observe(in: window) {
            !safety.needsSafetyConfirmation && window.attachedSheet == nil
          })
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }

    @Test func migrationRecoverySheetRendersWithTheManager() async throws {
      let core = AppCoreTestHarness.makeCore(
        AppCoreTestHarness.makeTestComposition(label: "settings-migration-sheet"))
      await core.exportRecordStore.configureAndWait(for: "A")
      await core.collectionExportRecordStore.configureAndWait(for: "A")
      core.exportDestinationManager.configureForScreenshotMode()
      var result = ConfigureRecordStoresResult.success
      let lifecycle = AppLifecycleCoordinator(
        cancelActiveWork: {}, interruptForDestinationUnavailable: {},
        configureRecordStores: { _ in result })
      lifecycle.apply(
        destination: DestinationIdentitySnapshot(
          identity: DestinationIdentity(stableId: "A", fingerprint: nil)))
      result = .migrationConflict(newId: "new", legacyId: "legacy")
      lifecycle.apply(
        destination: DestinationIdentitySnapshot(
          identity: DestinationIdentity(stableId: "C", fingerprint: nil)))
      let counter = BodyInvalidationCounter()
      let window = AppCoreTestHarness.settingsWindow(
        core: core, counter: counter, lifecycle: lifecycle)
      try await withCleanup {
        try #require(!core.destinationSafetyMonitor.needsSafetyConfirmation)
        try #require(
          lifecycle.migrationConflict == MigrationConflictState(newId: "new", legacyId: "legacy"))
        window.orderFront(nil)
        #expect(window.attachedSheet == nil)
        try await press("Resolve…", in: window)
        try await expectHeader("Destination Has Unresolved Issues", in: window)
        let sheet = try #require(window.attachedSheet)
        try #require(
          await observe(in: sheet) {
            NativeViewAccess.containsText("Show diagnostic details", in: sheet)
          })
        let rebuildTitle = "Rebuild Records from Destination"
        try #require(
          await observe(in: sheet) {
            NativeViewAccess.button(rebuildTitle, in: sheet)?.isAccessibilityEnabled?() == true
          })
        core.exportManager.queueCoordinator.enqueue([
          .init(
            assetLocalIdentifier: "held", placement: .timeline(year: 2026, month: 1),
            selection: .edited)
        ])
        try #require(core.exportManager.hasActiveExportWork)
        try #require(
          await observe(in: sheet) {
            NativeViewAccess.button(rebuildTitle, in: sheet)?.isAccessibilityEnabled?() == false
          })
        core.exportManager.cancelAndClear()
        try #require(
          await observe(in: sheet) {
            NativeViewAccess.button(rebuildTitle, in: sheet)?.isAccessibilityEnabled?() == true
          })
        try await expectSheetOutlivesPrompt("Resolve…", sheet: sheet, in: window) {
          lifecycle.clearMigrationConflictAfterReconcile()
        }
        try #require(
          await observe(in: sheet) {
            !NativeViewAccess.containsText("Show diagnostic details", in: sheet)
          })
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }

    @Test func actualSettingsRendersAndRemovesTheRecoveryPrompt() async throws {
      let core = AppCoreTestHarness.makeCore(
        AppCoreTestHarness.makeTestComposition(label: "settings-prompt-mounted"))
      var result = ConfigureRecordStoresResult.success
      let lifecycle = AppLifecycleCoordinator(
        cancelActiveWork: {}, interruptForDestinationUnavailable: {},
        configureRecordStores: { _ in result })
      lifecycle.apply(destination: .init(identity: .init(stableId: "A", fingerprint: nil)))
      result = .migrationConflict(newId: "new", legacyId: "legacy")
      lifecycle.apply(destination: .init(identity: .init(stableId: "B", fingerprint: nil)))
      let counter = BodyInvalidationCounter()
      let tick = RenderTick()
      let window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 900),
        styleMask: [.titled, .closable])
      window.contentView = NSHostingView(
        rootView: AutoExportSettingsView()
          .environmentObject(lifecycle).photoExportEnvironment(core)
          .overlay { RenderWitness(tick: tick, counter: counter) })
      try await withCleanup {
        window.orderFront(nil)
        try #require(
          await observe(in: window) {
            counter.count(for: "settings-render:0") > 0
              && (promptPixels(in: window)?.count ?? 0) > 3000
          })
        let shown = try #require(promptPixels(in: window))
        lifecycle.clearMigrationConflictAfterReconcile()
        tick.value += 1
        try #require(await observe(in: window) { counter.count(for: "settings-render:1") > 0 })
        let cleared = try #require(promptPixels(in: window))
        #expect(cleared != shown)
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }

    /// Compare the actual first Form row after an acknowledged render, without OS-specific
    /// HDR color thresholds or snapshots recorded for one macOS version.
    private func promptPixels(in window: NSWindow) -> Data? {
      guard let view = window.contentView,
        view.bounds.height >= 180
      else { return nil }
      let rect = NSRect(
        x: view.bounds.minX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY - 180,
        width: view.bounds.width, height: 180)
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
      view.cacheDisplay(in: rect, to: bitmap)
      return bitmap.representation(using: .png, properties: [:])
    }
  }
#endif
