import AppKit
import Combine
import SwiftUI
import Testing

@testable import Photo_Export

#if DEBUG
  /// Missing banner actions fail before instrumentation. A sheet without its manager traps
  /// the process; each test requires the actual recovery header in the attached sheet.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct AutoExportSettingsSheetTests {
    private func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }

    private func expectHeader(_ title: String, in window: NSWindow) async throws {
      try #require(await observe(in: window) { window.attachedSheet != nil })
      let sheet = try #require(window.attachedSheet)
      let content = try #require(sheet.contentView)
      content.layoutSubtreeIfNeeded()
      Attachment.record(
        descendants(content).map { "\(type(of: $0)): \(($0 as? NSTextField)?.stringValue ?? "")" }
          .joined(separator: "\n"), named: "recovery-sheet-descendants.txt")
      #expect(
        await observe(in: sheet) {
          descendants(content).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == title
          }
        })
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
        action()
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
        core: core, counter: counter, lifecycle: lifecycle)
      try await withCleanup {
        try #require(
          lifecycle.migrationConflict == MigrationConflictState(newId: "new", legacyId: "legacy"))
        window.orderFront(nil)
        try #require(
          await observe(in: window) { counter.renderedText["auto-export-now-footer"] != nil })
        let action = try #require(counter.renderedActions["auto-export-migration-recovery"])
        action()
        try await expectHeader("Destination Has Unresolved Issues", in: window)
      } cleanup: {
        await close(window, core: core, counter: counter)
      }
    }
  }
#endif
