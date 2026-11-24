#if DEBUG
  import AppKit
  import SwiftUI

  @MainActor
  enum ControlSnapshot {
    static func capture(core: AppCore, options: ControlLaunch.Options, to output: URL) async throws
    {
      let counter = BodyInvalidationCounter()
      let size = options.size
      let content = Group {
        if options.surface.settingsTab != nil {
          SettingsRootView().onAppear { counter.record("settings-ready") }
        } else {
          MainWindowRoot(
            destinationManager: core.exportDestinationManager, recordStore: core.exportRecordStore
          )
          .recordStoreAlertHost()
        }
      }
      .photoExportEnvironment(core)
      .environment(\.bodyInvalidationCounter, counter)
      .environment(\.locale, Locale(identifier: "en_US_POSIX"))
      .environment(\.timeZone, .gmt)
      .environment(\.appearsActive, true)
      .preferredColorScheme(options.dark ? .dark : .light)
      .frame(width: size.width, height: size.height)
      .background(Color(nsColor: .windowBackgroundColor))

      let hosting = NSHostingView(rootView: content)
      let window = NSWindow(
        contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      let appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
      window.appearance = appearance
      hosting.appearance = appearance
      window.contentView = hosting
      hosting.frame = NSRect(origin: .zero, size: size)
      window.orderFront(nil)
      defer { window.close() }

      try await waitForContent(counter, surface: options.surface)
      hosting.layoutSubtreeIfNeeded()
      window.display()
      guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw ControlLaunch.Invalid("Could not allocate offscreen bitmap.")
      }
      if let appearance {
        appearance.performAsCurrentDrawingAppearance {
          hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
      } else {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      }
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ControlLaunch.Invalid("Could not encode offscreen bitmap.")
      }
      try png.write(to: output, options: .withoutOverwriting)
    }

    private static func waitForContent(
      _ counter: BodyInvalidationCounter, surface: ControlLaunch.Surface
    ) async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        // The deadline backs up view-owned readiness signals if rendering stalls.
        let timeout = DispatchWorkItem { [weak counter] in
          guard let counter, counter.onRecord != nil else { return }
          counter.onRecord = nil
          continuation.resume(throwing: ControlLaunch.Invalid("Offscreen content did not load."))
        }
        counter.onRecord = { [weak counter] in
          guard let counter else { return }
          let ready: Bool
          if surface.settingsTab != nil {
            ready = counter.count(for: "settings-ready") > 0
          } else {
            ready =
              counter.count(for: "grid-load-finished") > 0
              && counter.count(for: "asset-tile-body:harbor") > 0
              && (surface == .favorites || counter.count(for: "timeline-counts-loaded") > 0)
          }
          if ready {
            counter.onRecord = nil
            timeout.cancel()
            DispatchQueue.main.async { continuation.resume() }
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        counter.onRecord?()
      }
    }
  }
#endif
