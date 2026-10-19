import Foundation
import Testing

/// Test preferences and folders must stay inside the per-run scratch root, so a run leaves
/// nothing in the user's (or, when signed and sandboxed, the app container's) preferences.
@Suite struct TestScratchTests {
  @Test func preferencesSuitesAreStoredInsideTheRunRoot() {
    let name = TestScratch.suiteName("Probe")
    let defaults = UserDefaults(suiteName: name)!
    defaults.set("value", forKey: "key")
    defaults.synchronize()

    #expect(name.hasPrefix(TestScratch.root.path))
    #expect(FileManager.default.fileExists(atPath: name + ".plist"))
    #expect(UserDefaults(suiteName: name)!.string(forKey: "key") == "value")
    // Nothing in the preferences folder (the user's, or the container's when sandboxed).
    let preferences = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences")
    let leaked = (try? FileManager.default.contentsOfDirectory(atPath: preferences))?
      .filter { $0.contains((name as NSString).lastPathComponent) } ?? []
    #expect(leaked.isEmpty)
  }

  @Test func removingAPathNamedSuiteEmptiesIt() {
    let name = TestScratch.suiteName("Probe")
    let defaults = UserDefaults(suiteName: name)!
    defaults.set("value", forKey: "key")
    defaults.synchronize()

    UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)

    #expect(UserDefaults(suiteName: name)!.string(forKey: "key") == nil)
  }

  @Test func directoriesAreUniqueAndNotCreated() {
    let first = TestScratch.directory("Probe")
    let second = TestScratch.directory("Probe")
    #expect(first != second)
    #expect(first.path.hasPrefix(TestScratch.root.path))
    #expect(!FileManager.default.fileExists(atPath: first.path))
  }
}
