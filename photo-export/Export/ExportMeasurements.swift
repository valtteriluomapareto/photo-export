import Foundation
import OSLog

/// Opt-in numeric evidence. Each logical activity owns its jobs until it seals.
@MainActor
final class ExportMeasurements {
  private final class Run {
    let id = UUID().uuidString
    let start: UInt64
    var sequence = 0
    var enqueued = 0
    var finished = 0
    var completions = 0
    var reason: String?
    var assets: [String: Int] = [:]
    init(start: UInt64) { self.start = start }
  }

  @MainActor
  final class Job {
    fileprivate weak var owner: ExportMeasurements?
    fileprivate let runId: String
    fileprivate let number: Int
    fileprivate let asset: Int
    fileprivate let start: UInt64
    fileprivate var staging: UInt64 = 0
    fileprivate var finished = false
    fileprivate var stageOpen = false

    fileprivate init(
      owner: ExportMeasurements, runId: String, number: Int, asset: Int, start: UInt64
    ) {
      self.owner = owner
      self.runId = runId
      self.number = number
      self.asset = asset
      self.start = start
    }

    func beginStage() -> Stage? {
      guard let owner, owner.owns(self) else { return nil }
      guard !stageOpen else {
        owner.invalidate("overlapping-stages")
        return nil
      }
      stageOpen = true
      return Stage(job: self, start: owner.now())
    }

    func committed() {
      guard let owner, owner.owns(self) else { return }
      owner.run?.completions += 1
      owner.emit("completion", ["job": number, "asset": asset, "atNs": owner.now()])
    }
  }

  @MainActor
  final class Stage {
    private let job: Job
    private let start: UInt64
    private var finished = false
    fileprivate init(job: Job, start: UInt64) {
      self.job = job
      self.start = start
    }
    func finish() {
      guard !finished else { return }
      finished = true
      guard let owner = job.owner, owner.owns(job) else { return }
      let end = owner.now()
      guard end >= start else {
        owner.invalidate("clock-regressed")
        return
      }
      job.staging += end - start
      job.stageOpen = false
    }
  }

  private static let logger = Logger(subsystem: Logger.appSubsystem, category: "Export.Measurement")
  private let sessionId: String
  private let now: @MainActor () -> UInt64
  private let sink: @MainActor (String) -> Void
  private var run: Run?
  private(set) var currentJob: Job?

  static func session(arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--export-measurements"),
      arguments.indices.contains(index + 1), UUID(uuidString: arguments[index + 1]) != nil
    else { return nil }
    return arguments[index + 1]
  }

  static func fromArguments(_ arguments: [String]) -> ExportMeasurements? {
    guard let session = session(arguments: arguments) else { return nil }
    return ExportMeasurements(session: session)
  }

  init(
    session: String,
    now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    emit: @escaping @MainActor (String) -> Void = { message in
      logger.info("\(message, privacy: .public)")
    }
  ) {
    sessionId = session
    self.now = now
    sink = emit
    write(["type": "ready"])
  }

  func beginRun(automatic: Bool = false) {
    guard run == nil else { return }
    run = Run(start: now())
    emit("runBegin", ["automatic": automatic])
  }

  func enqueued(_ count: Int) {
    guard let run, count > 0 else { return }
    run.enqueued += count
    emit("enqueued", ["count": count])
  }

  func beginJob(assetId: String) -> Job? {
    guard let run else { return nil }
    guard currentJob == nil else {
      invalidate("overlapping-jobs")
      return nil
    }
    let asset = run.assets[assetId] ?? run.assets.count + 1
    run.assets[assetId] = asset
    let job = Job(owner: self, runId: run.id, number: run.finished + 1, asset: asset, start: now())
    currentJob = job
    emit("jobBegin", ["job": job.number, "asset": asset])
    return job
  }

  private func owns(_ job: Job) -> Bool {
    run?.id == job.runId && currentJob === job && !job.finished
  }

  func endJob(_ job: Job?) {
    guard let job, owns(job), let run else { return }
    let end = now()
    let wall = end >= job.start ? end - job.start : 0
    let stageValid = end >= job.start && job.staging <= wall && !job.stageOpen
    emit(
      "jobEnd",
      [
        "job": job.number, "asset": job.asset, "wallNs": wall, "stageNs": job.staging,
        "stageValid": stageValid,
      ])
    job.finished = true
    currentJob = nil
    run.finished += 1
  }

  func invalidate(_ reason: String) {
    guard let run, run.reason == nil else { return }
    run.reason = reason
    emit("invalidated", ["reason": reason])
  }

  func recordTurn(nanoseconds: UInt64) {
    guard run != nil, nanoseconds > 16_000_000 else { return }
    emit("turn", ["durationNs": nanoseconds])
  }

  func endRun() {
    guard let run else { return }
    if currentJob != nil { invalidate("job-still-active") }
    if run.finished != run.enqueued { invalidate("job-count-mismatch") }
    if run.enqueued == 0 { invalidate("no-jobs") }
    let end = now()
    if end < run.start { invalidate("clock-regressed") }
    emit(
      "runEnd",
      [
        "valid": run.reason == nil, "reason": run.reason ?? "complete",
        "jobs": run.finished, "enqueued": run.enqueued, "completions": run.completions,
        "wallNs": end >= run.start ? end - run.start : 0,
      ])
    currentJob = nil
    self.run = nil
  }

  private func emit(_ type: String, _ fields: [String: Any] = [:]) {
    guard let run else { return }
    run.sequence += 1
    var event = fields
    event["type"] = type
    event["run"] = run.id
    event["seq"] = run.sequence
    write(event)
  }

  private func write(_ fields: [String: Any]) {
    var event = fields
    event["schema"] = 1
    event["session"] = sessionId
    guard let data = try? JSONSerialization.data(withJSONObject: event, options: .sortedKeys),
      let text = String(data: data, encoding: .utf8)
    else { return }
    sink("MEASURE \(text)")
  }
}

/// Only the awaited producer contributes staging time, including a throwing attempt.
@MainActor
func measureExportStage<T>(
  _ job: ExportMeasurements.Job?, operation: @MainActor () async throws -> T
) async rethrows -> T {
  let stage = job?.beginStage()
  defer { stage?.finish() }
  return try await operation()
}
