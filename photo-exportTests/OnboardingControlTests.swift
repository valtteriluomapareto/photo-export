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
  }

  private struct Host: View {
    @Bindable var choices: Choices
    var body: some View {
      VStack(spacing: 24) {
        OnboardingExportOptions(
          exportAll: $choices.all, includeOriginals: $choices.originals,
          convertHEICToJPEG: $choices.convert)
        OnboardingExportActions(
          historyState: choices.history, exportAll: choices.all,
          includeOriginals: choices.originals, convertHEICToJPEG: choices.convert,
          onSkip: { choices.skipped += 1 })
      }
      .padding()
    }
  }

  @MainActor private final class Fixture {
    let h: ExportManagerHarness
    let choices = Choices()
    let window: NSWindow
    init() async {
      h = await ExportManagerHarness(label: "OnboardingControls")
      let destination = ExportDestinationManager(skipRestore: true, userDefaults: h.defaults)
      destination.configureForScreenshotMode()
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
    let f = await Fixture()
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
    let f = await Fixture()
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
}
