import Foundation
import Testing

/// Test preferences and folders must stay inside the per-run scratch root, so a run leaves
/// nothing in the user's (or, when signed and sandboxed, the app container's) preferences.
@Suite struct TestScratchTests {
  /// Opens a suite directly rather than through `TestScratch.defaults(suiteName:)`, so these
  /// tests check where the suite itself is stored.
  private func open(_ name: String) -> UserDefaults {
    // test-scratch: allow - checks the raw path-named suite, not the helper
    UserDefaults(suiteName: name)!
  }

  @Test func preferencesSuitesAreStoredInsideTheRunRoot() {
    let name = TestScratch.suiteName("Probe")
    let defaults = open(name)
    defaults.set("value", forKey: "key")
    defaults.synchronize()

    #expect(name.hasPrefix(TestScratch.root.path))
    #expect(FileManager.default.fileExists(atPath: name + ".plist"))
    #expect(open(name).string(forKey: "key") == "value")
    // Nothing in the preferences folder (the user's, or the container's when sandboxed).
    let preferences = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences")
    let leaked = (try? FileManager.default.contentsOfDirectory(atPath: preferences))?
      .filter { $0.contains((name as NSString).lastPathComponent) } ?? []
    #expect(leaked.isEmpty)
  }

  @Test func removingAPathNamedSuiteEmptiesIt() {
    let name = TestScratch.suiteName("Probe")
    let defaults = open(name)
    defaults.set("value", forKey: "key")
    defaults.synchronize()

    open(name).removePersistentDomain(forName: name)

    #expect(open(name).string(forKey: "key") == nil)
  }

  @Test func reopeningASuiteNameSharesItsValues() {
    let name = TestScratch.suiteName("Probe")
    TestScratch.defaults(suiteName: name).set("value", forKey: "key")

    #expect(TestScratch.defaults(suiteName: name).string(forKey: "key") == "value")
    #expect(TestScratch.defaults("Probe").string(forKey: "key") == nil)
  }

  @Test func directoriesAreUniqueAndNotCreated() {
    let first = TestScratch.directory("Probe")
    let second = TestScratch.directory("Probe")
    #expect(first != second)
    #expect(first.path.hasPrefix(TestScratch.root.path))
    #expect(!FileManager.default.fileExists(atPath: first.path))
  }
}
