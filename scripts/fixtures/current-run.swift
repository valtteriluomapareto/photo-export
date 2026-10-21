import Foundation

#if !RELEASE_MODERN
@main
struct CurrentRunFixtures {
  @MainActor static func main() throws {
    try writeCurrentRunFixtures(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  }
}
#endif

@MainActor
func writeCurrentRunFixtures(to root: URL) throws {
  let store = FileBackedAutoSyncCurrentRunStore(
    baseDirectoryURL: root.appendingPathComponent("AutoSync/destinations"))
  try store.save(
    AutoSyncRunJournal(
      startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), trigger: "photosChanged",
      scopes: ["timeline", "favorites", "albums"], currentScope: "favorites",
      currentScopeStartedAt: Date(timeIntervalSinceReferenceDate: 700_000_030)),
    destinationId: "A")
  try store.save(
    AutoSyncRunJournal(
      startedAt: Date(timeIntervalSinceReferenceDate: 700_000_100), trigger: "appLaunch",
      scopes: ["albums"], currentScope: nil, currentScopeStartedAt: nil),
    destinationId: "B")
}
