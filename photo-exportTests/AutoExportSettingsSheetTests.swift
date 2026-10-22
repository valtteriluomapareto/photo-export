import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// Missing banner actions fail before instrumentation. A sheet without its manager traps
  /// the process; each test witnesses the header's title from its mounted background.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct AutoExportSettingsSheetTests {
    private func expectHeader(
      _ title: String, in window: NSWindow, counter: BodyInvalidationCounter
    ) async throws {
      try #require(await observe(in: window) { window.attachedSheet != nil })
      let sheet = try #require(window.attachedSheet)
      try #require(
        await observe(in: sheet) {
          counter.renderedText["destination-recovery-header"] == [title]
        }, "The attached recovery header must record its actual title")
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
      core.exportRecordStore.configure(for: "A")
      core.collectionExportRecordStore.configure(for: "A")
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
        try #require(
          await observe(in: window) { counter.renderedText["auto-export-now-footer"] != nil })
        let action = try #require(counter.renderedActions["auto-export-safety-confirmation"])
        #expect(window.attachedSheet == nil)
        #expect(counter.renderedText["destination-recovery-header"] == nil)
        action()
        try await expectHeader("Confirm This Destination", in: window, counter: counter)
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
        core: core, counter: counter, lifecycle: lifecycle)
      try await withCleanup {
        try #require(
          lifecycle.migrationConflict == MigrationConflictState(newId: "new", legacyId: "legacy"))
        window.orderFront(nil)
        try #require(
          await observe(in: window) { counter.renderedText["auto-export-now-footer"] != nil })
        let action = try #require(counter.renderedActions["auto-export-migration-recovery"])
        #expect(window.attachedSheet == nil)
        #expect(counter.renderedText["destination-recovery-header"] == nil)
        action()
        try await expectHeader("Destination Has Unresolved Issues", in: window, counter: counter)
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }
  }
#endif
