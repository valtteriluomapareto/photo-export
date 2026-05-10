import AppKit
import Combine

/// Tracks the user's currently-pressed modifier keys (Command, Shift, Option) via an
/// `NSEvent` local monitor. Used by views that need to dispatch click handling based on
/// modifier state — e.g. the folder content pane's tile grid, where Cmd/Shift-click
/// extend a multi-selection while a plain click navigates.
///
/// Why a monitor and not a SwiftUI gesture: SwiftUI's
/// `TapGesture().modifiers(.command)` either composes ambiguously with a plain
/// `onTapGesture` (both fire on Cmd-click, depending on the gesture mask) or requires
/// `simultaneousGesture` plumbing that's brittle across SwiftUI releases. An NSEvent
/// monitor reads modifier state directly from AppKit and is deterministic.
///
/// Not annotated `@MainActor`. AppKit invokes the local-monitor closure on the main
/// thread, so the synchronous `flags` write inside it is main-bound by construction;
/// SwiftUI views (`@StateObject`) read the property from the main actor anyway. Adding
/// `@MainActor` here would force the monitor closure into a `Task { @MainActor in }`
/// hop, which introduces an async gap between key release and the next click — long
/// enough for a Cmd-click to register as a plain click in practice.
final class ModifierFlagsTracker: ObservableObject {
  @Published private(set) var flags: NSEvent.ModifierFlags = []

  private var monitor: Any?

  init() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
      [weak self] event in
      self?.flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      return event
    }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }

  var command: Bool { flags.contains(.command) }
  var shift: Bool { flags.contains(.shift) }
}
