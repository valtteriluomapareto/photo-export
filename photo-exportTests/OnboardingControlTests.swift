import AppKit
import SwiftUI
import Testing

@testable import Photo_Export

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct OnboardingControlTests {
  @Observable final class Choices {
    var all = true
    var originals = false
    var convert = false
    var history: RecordStoreState = .ready
    var skipped = 0
    var keepReadyDestinationInputs = false
  }

  private struct Host: View {
    @EnvironmentObject private var destination: ExportDestinationManager
    @Bindable var choices: Choices
    var body: some View {
      VStack(spacing: 24) {
        OnboardingExportOptions(
          exportAll: $choices.all, includeOriginals: $choices.originals,
          convertHEICToJPEG: $choices.convert)
        OnboardingExportActions(
          exportDestinationManager: destination,
          destinationCanExport: choices.keepReadyDestinationInputs || destination.canExportNow,
          hasDestination: choices.keepReadyDestinationInputs
            || destination.selectedFolderURL != nil,
          historyState: choices.history, exportAll: choices.all,
          includeOriginals: choices.originals, convertHEICToJPEG: choices.convert,
          onSkip: { choices.skipped += 1 })
      }
      .padding()
    }
  }

  @MainActor private final class Scope { var allowed = true }

  @MainActor private final class Fixture {
    let h: ExportManagerHarness
    let destination: ExportDestinationManager
    let scope: Scope
    let choices = Choices()
    let window: NSWindow
    init() async throws {
      let scope = Scope()
      self.scope = scope
      h = await ExportManagerHarness(label: "OnboardingControls")
      destination = ExportDestinationManager(
        skipRestore: true, userDefaults: h.defaults,
        fingerprintProvider: {
          .makeLow(
            volumeRootPath: "/", relativePathFromVolumeRoot: $0.path, standardizedPath: $0.path)
        },
        bookmarkSaver: { _ in true }, volumeNotificationCenter: NotificationCenter(),
        validationScopeAcquirer: { [scope] _ in scope.allowed }, validationScopeReleaser: { _ in })
      try FileManager.default.createDirectory(at: h.dest.rootURL, withIntermediateDirectories: true)
      await destination.persistSelectionAndWait(h.dest.rootURL)
      h.manager.queueCoordinator.pause()
      let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2))!
      h.photoLib.assetsByYearMonth["2026-1"] = [
        TestAssetFactory.makeAsset(id: "chosen", creationDate: date)
      ]
      h.photoLib.yearCounts = [(2026, 1)]
      window = HostedViewHarness.makeWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 400), styleMask: [.borderless]
      )
      window.contentView = NSHostingView(
        rootView: Host(choices: choices)
          .environment(h.manager).environmentObject(destination)
          .environment(\.accessibilityEnabled, true))
      window.orderFront(nil)
    }
    func close() {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
      h.manager.cancelAndClear()
      h.store.drainSynchronously()
      h.collectionStore.drainSynchronously()
      h.dest.cleanup()
      try? FileManager.default.removeItem(at: h.storeRoot)
    }
  }

  private func press(_ label: String, role: NSAccessibility.Role = .button, in window: NSWindow)
    async throws
  {
    try #require(
      await observe(in: window) {
        NativeViewAccess.elements(in: window).contains {
          $0.accessibilityRole?() == role
            && ($0.accessibilityLabel?() == label || $0.accessibilityTitle?() == label)
        }
      })
    let element = try #require(
      NativeViewAccess.elements(in: window).first {
        $0.accessibilityRole?() == role
          && ($0.accessibilityLabel?() == label || $0.accessibilityTitle?() == label)
      })
    #expect(element.isAccessibilityEnabled?() == true)
    let press = try #require(element.accessibilityPerformPress as (() -> Bool)?)
    _ = press()
  }

  @Test func actualOptionsAreAppliedBeforeStartAndSkip() async throws {
    let f = try await Fixture()
    defer { f.close() }
    try await press("Include originals for edited photos", role: .checkBox, in: f.window)
    try await press("Convert HEIC to JPEG", role: .checkBox, in: f.window)
    try #require(NativeViewAccess.button("Start Export", in: f.window))
    #expect(f.choices.originals && f.choices.convert)
    #expect(f.h.manager.pendingJobs.isEmpty && f.choices.skipped == 0)
    try await press("Start Export", in: f.window)
    for task in f.h.manager.currentPreparationTasks { await task.value }
    #expect(f.h.manager.versionSelection == .editedWithOriginals)
    #expect(f.h.manager.convertHEICToJPEG)
    #expect(f.h.manager.pendingJobs.map(\.assetLocalIdentifier) == ["chosen"])
    #expect(f.choices.skipped == 1)
  }

  @Test func historyBlocksExportAndKeepsOptionsWhileContinueDoesNotStartWork() async throws {
    let f = try await Fixture()
    defer { f.close() }
    try await press("Include originals for edited photos", role: .checkBox, in: f.window)
    f.choices.history = .loading
    try #require(
      await observe(in: f.window) {
        NativeViewAccess.button("Start Export", in: f.window)?.isAccessibilityEnabled?() == false
      })
    #expect(f.choices.originals && f.h.manager.pendingJobs.isEmpty && f.choices.skipped == 0)
    f.choices.history = .ready
    try #require(
      await observe(in: f.window) {
        NativeViewAccess.button("Start Export", in: f.window)?.isAccessibilityEnabled?() == true
      })
    f.choices.history = .loading
    try await press("Let me pick months", role: .radioButton, in: f.window)
    #expect(!f.choices.all && f.choices.originals)
    try await press("Continue", in: f.window)
    #expect(f.h.manager.pendingJobs.isEmpty && !f.h.manager.isPreparingExport)
    #expect(f.h.manager.versionSelection == .editedWithOriginals)
    #expect(f.choices.skipped == 1)
  }
  @Test func destinationInputsRenderAndTheActionRechecksItsLiveDestination() async throws {
    let f = try await Fixture()
    defer { f.close() }
    func enabled() -> Bool? {
      NativeViewAccess.button("Start Export", in: f.window)?.isAccessibilityEnabled?()
    }
    func loadingHelp() -> Bool {
      NativeViewAccess.identifiedElements("onboarding-export-primary", in: f.window).contains {
        ($0.accessibilityHelp?() ?? ($0 as? NSView)?.toolTip)?.contains("Loading export history")
          == true
      }
    }
    try #require(f.destination.canExportNow)
    try #require(await observe(in: f.window) { enabled() == true })
    f.choices.history = .loading
    try #require(await observe(in: f.window) { enabled() == false && loadingHelp() })
    f.scope.allowed = false
    await f.destination.revalidateAndWait()
    try #require(!f.destination.canExportNow && f.destination.selectedFolderURL != nil)
    try #require(await observe(in: f.window) { enabled() == true && !loadingHelp() })
    f.scope.allowed = true
    await f.destination.revalidateAndWait()
    try #require(await observe(in: f.window) { enabled() == false && loadingHelp() })
    f.destination.clearSelection()
    try #require(await observe(in: f.window) { enabled() == false && !loadingHelp() })
    await f.destination.persistSelectionAndWait(f.h.dest.rootURL)
    f.choices.history = .ready
    try #require(await observe(in: f.window) { enabled() == true && !loadingHelp() })

    // The real child receives ready render values while its action sees newer unavailable state.
    f.choices.keepReadyDestinationInputs = true
    f.scope.allowed = false
    await f.destination.revalidateAndWait()
    try #require(!f.destination.canExportNow)
    try await press("Start Export", in: f.window)
    try #require(await observe(in: f.window) { f.choices.skipped == 1 })
    for task in f.h.manager.currentPreparationTasks { await task.value }
    #expect(f.h.manager.pendingJobs.isEmpty && f.h.manager.totalJobsEnqueued == 0)
    f.scope.allowed = true
    await f.destination.revalidateAndWait()
    try #require(f.destination.canExportNow)
    try await press("Start Export", in: f.window)
    for task in f.h.manager.currentPreparationTasks { await task.value }
    #expect(f.h.manager.pendingJobs.map(\.assetLocalIdentifier) == ["chosen"])
    #expect(f.choices.skipped == 2)
  }

}
