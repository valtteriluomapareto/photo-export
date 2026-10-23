import Foundation

/// Immutable admission ownership retained across physical destination work.
struct ExportDestinationContext: Sendable {
  let root: URL
  let destinationId: String?
  let generation: Int
  let io: any DestinationIOExecuting
  let directories: any ExportDirectoryResolving
}
