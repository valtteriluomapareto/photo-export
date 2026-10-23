import Testing

@testable import Photo_Export

@Suite(.timeLimit(.minutes(1)))
struct ExportRunWatchdogTests {
  @Test func classifiesStrictThresholdsAndCumulativeCounts() {
    var turns = ExportRunWatchdog.TurnCounts()
    for milliseconds in [0.0, 16, 17, 33, 34, 100, 101] {
      turns.record(milliseconds: milliseconds)
    }
    #expect(turns.over16 == 5)
    #expect(turns.over33 == 3)
    #expect(turns.over100 == 1)
  }

  @Test func returnsOnlyIndividualLongTurns() {
    var turns = ExportRunWatchdog.TurnCounts()
    let boundary = turns.record(milliseconds: 100)
    let justOver = turns.record(milliseconds: 100.001)
    let long = turns.record(milliseconds: 250)
    #expect(!boundary)
    #expect(justOver)
    #expect(long)
    #expect(turns.over100 == 2)
  }

  @Test func freshRunHasNoPreviousCounts() {
    var turns = ExportRunWatchdog.TurnCounts()
    turns.record(milliseconds: 200)
    turns = ExportRunWatchdog.TurnCounts()
    #expect(turns.over16 == 0)
    #expect(turns.over33 == 0)
    #expect(turns.over100 == 0)
  }

  @Test func disabledUnlessExplicitlyEnabled() {
    #expect(!ExportRunWatchdog.isEnabled(arguments: [], preferenceEnabled: false))
    #expect(!ExportRunWatchdog.isEnabled(arguments: ["--unrelated"], preferenceEnabled: false))
    #expect(ExportRunWatchdog.isEnabled(arguments: ["--export-watchdog"], preferenceEnabled: false))
    #expect(ExportRunWatchdog.isEnabled(arguments: [], preferenceEnabled: true))
  }
}
