import AppKit
import Testing

/// Waits for a condition, optionally laying out its hosted window before each check.
@MainActor
func observe(
  in window: NSWindow? = nil,
  _ condition: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
  await eventually(
    window == nil ? "observed condition" : "observed hosted condition",
    sourceLocation: sourceLocation
  ) {
    window?.contentView?.layoutSubtreeIfNeeded()
    return condition()
  }
}
