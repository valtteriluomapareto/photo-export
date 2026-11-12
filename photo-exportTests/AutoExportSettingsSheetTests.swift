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

    private func press(_ title: String, in window: NSWindow) async throws {
      try #require(await observe(in: window) { NativeViewAccess.button(title, in: window) != nil })
      let button = try #require(NativeViewAccess.button(title, in: window))
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
      let window = AppCoreTestHarness.settingsWindow(
        core: core, counter: counter, safety: safety, recoveryPromptOnly: true)
      try await withCleanup {
        safety.attach()
        try #require(await eventually("safety scan completed") { safety.needsSafetyConfirmation })
        window.orderFront(nil)
        #expect(window.attachedSheet == nil)
        try await press("Review…", in: window)
        try await expectHeader("Confirm This Destination", in: window)
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }

    @Test func migrationRecoverySheetRendersWithTheManager() async throws {
      let core = AppCoreTestHarness.makeCore(
        AppCoreTestHarness.makeTestComposition(label: "settings-migration-sheet"))
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
        core: core, counter: counter, lifecycle: lifecycle, recoveryPromptOnly: true)
      try await withCleanup {
        try #require(
          lifecycle.migrationConflict == MigrationConflictState(newId: "new", legacyId: "legacy"))
        window.orderFront(nil)
        #expect(window.attachedSheet == nil)
        try await press("Resolve…", in: window)
        try await expectHeader("Destination Has Unresolved Issues", in: window)
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }
  }
#endif
