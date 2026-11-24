#if DEBUG
  import Foundation
  import Testing

  @testable import Photo_Export

  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct ControlPlaneTests {
    @Test func strictLaunchAndWireFraming() throws {
      #expect(try ControlLaunch.parse(["app", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
      for flags in [
        ["-PEUnknown"], ["-PEDark"], ["-PEFixture", "v1", "-PEDark", "-PEDark"],
        ["-PEFixture", "v1", "-PERunDirectory", "relative"],
        ["-PESnapshot", "../outside.png"], ["-PEFixture", "v1", "-PESize", "800x600"],
      ] {
        #expect(throws: ControlLaunch.Invalid.self) { try ControlLaunch.parse(["app"] + flags) }
      }
      let request =
        #"{"seq":1,"version":1,"run":"here","action":"export.month","year":2025,"month":6}"#
      #expect(
        try ControlRequest.decode(Data(request.utf8), run: "here", sequence: 1)
          == .export(.timelineMonth(year: 2025, month: 6), confirm: false))
      #expect(throws: ControlRefusal.staleRun) {
        try ControlRequest.decode(Data(request.utf8), run: "old", sequence: 1)
      }
      for invalid in [
        request.replacingOccurrences(of: #""seq":1"#, with: #""seq":1,"s\u0065q":1"#),
        request.replacingOccurrences(of: #""month":6"#, with: #""month":true"#),
        request.replacingOccurrences(of: #""month":6"#, with: #""month":13"#),
        request.replacingOccurrences(of: "export.month", with: "export.unknown"),
        String(repeating: " ", count: 16_385) + request,
      ] {
        #expect(throws: ControlRefusal.invalidRequest) {
          try ControlRequest.decode(Data(invalid.utf8), run: "here", sequence: 1)
        }
      }
    }

    @Test func mailboxConsumesInOrderAndRefusesUnsafeFiles() async throws {
      let parent = TestScratch.directory("control-mailbox")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let fixture = try ControlFixture.prepare(runDirectory: nil, temporaryDirectory: parent)
      let core = AppCore(composition: try .fixture(fixture, surface: .library))
      var settled: [Int] = []
      let mailbox = try ControlMailbox(
        directory: fixture.root, run: fixture.run, actions: ControlActions(core: core),
        publish: { seq, finished in if seq == finished { settled.append(seq) } },
        fail: { Issue.record("Mailbox failed: \($0)") })
      let next = fixture.root.appending(path: "req-2.json")
      let stale = #"{"version":1,"run":"stale","seq":2,"action":"export.pause"}"#
      try Data(stale.utf8).write(to: next, options: .atomic)
      mailbox.check()
      #expect(settled.isEmpty)

      let first = fixture.root.appending(path: "req-1.json")
      try FileManager.default.createSymbolicLink(at: first, withDestinationURL: next)
      #expect(await eventually("mailbox drains both adjacent requests") { settled == [1, 2] })
      let responses = try [1, 2].map {
        let data = try Data(contentsOf: fixture.root.appending(path: "res-\($0).json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      }
      #expect(responses[0]["reason"] as? String == "invalidRequest")
      #expect(responses[1]["reason"] as? String == "staleRun")
      withExtendedLifetime(mailbox) {}
    }

    @Test func compositionRefusesStateDirectoryOutsideRun() throws {
      let parent = TestScratch.directory("control-escaped-state")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let fixture = try ControlFixture.prepare(runDirectory: nil, temporaryDirectory: parent)
      let outside = parent.appending(path: "outside", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
      try FileManager.default.removeItem(at: fixture.stateRoot)
      try FileManager.default.createSymbolicLink(at: fixture.stateRoot, withDestinationURL: outside)
      #expect(throws: ControlLaunch.Invalid.self) {
        try AppComposition.fixture(fixture, surface: .library)
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func fixtureRejectsReusedOrLinkedRunDirectories() throws {
      let parent = TestScratch.directory("control-root")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let result = try ControlFixture.prepare(runDirectory: nil, temporaryDirectory: parent)
      #expect(throws: ControlLaunch.Invalid.self) {
        try ControlFixture.prepare(runDirectory: result.root, temporaryDirectory: parent)
      }
      let linked = parent.appending(path: "photo-export-control-link")
      try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: result.root)
      #expect(throws: ControlLaunch.Invalid.self) {
        try ControlFixture.prepare(runDirectory: linked, temporaryDirectory: parent)
      }
    }
  }
#endif
