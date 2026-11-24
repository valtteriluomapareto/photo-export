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

    /// "Use This Destination" confirms the pending destination and closes the sheet. A completed
    /// rebuild clears the prompt first instead, and the sheet must stay up for its result.
    @Test(arguments: [false, true])
    func safetyConfirmationSheetRendersWithTheManager(promptClearsFirst: Bool) async throws {
      let core = AppCoreTestHarness.makeCore(
        AppCoreTestHarness.makeTestComposition(label: "settings-safety-sheet"))
      await core.exportRecordStore.configureAndWait(for: "A")
      await core.collectionExportRecordStore.configureAndWait(for: "A")
      let identity = CurrentValueSubject<DestinationIdentity, Never>(
        DestinationIdentity(stableId: "A", fingerprint: nil))
      let store = InMemoryDestinationSafetyConfirmationStore()
      let safety = DestinationSafetyMonitor(
        identityPublisher: identity.eraseToAnyPublisher(),
        exportRecordStore: core.exportRecordStore,
        collectionExportRecordStore: core.collectionExportRecordStore,
        confirmationStore: store, scanDirectory: { true })
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
        if promptClearsFirst {
          try await expectSheetOutlivesPrompt("Review…", sheet: sheet, in: window) {
            safety.confirmCurrentDestination()
          }
        } else {
          try #require(safety.needsSafetyConfirmation && !store.isConfirmed(destinationId: "A"))
        }
        try await press("Use This Destination", in: sheet)
        try #require(
          await observe(in: window) {
            store.isConfirmed(destinationId: "A") && !safety.needsSafetyConfirmation
              && window.attachedSheet == nil
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
  }
#endif
