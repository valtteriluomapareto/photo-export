import Combine
import Foundation
import Photos

@testable import Photo_Export

/// `AutoSyncExportRunning` test double. `runExport` is awaitable and resolves with
/// whatever `nextRunSummary` is set to at call time; if nil, it constructs a default
/// `.completed` summary so simple tests don't need to wire one. Tests that need to
/// observe an in-flight run can flip `exportRunStatePublisher` via `subject` to
/// simulate the run lifecycle.
@MainActor
final class FakeAutoSyncExportRunner: AutoSyncExportRunning {
  let subject = CurrentValueSubject<ExportRunState, Never>(.idle)
  var exportRunStatePublisher: AnyPublisher<ExportRunState, Never> {
    subject.eraseToAnyPublisher()
  }

  let versionSelectionSubject = CurrentValueSubject<ExportVersionSelection, Never>(.edited)
  var versionSelectionPublisher: AnyPublisher<ExportVersionSelection, Never> {
    versionSelectionSubject.eraseToAnyPublisher()
  }

  let completedRunsSubject = PassthroughSubject<ExportRunSummary, Never>()
  var completedRunsPublisher: AnyPublisher<ExportRunSummary, Never> {
    completedRunsSubject.eraseToAnyPublisher()
  }

  /// If set, the next `runExport` returns this summary. Otherwise a default
  /// `.completed` summary is constructed from the requested context.
  var nextRunSummary: ExportRunSummary?
  /// Contexts the manager passed in. Tests assert on this.
  var receivedContexts: [ExportRunContext] = []

  func runExport(context: ExportRunContext) async -> ExportRunSummary {
    receivedContexts.append(context)
    if let summary = nextRunSummary {
      nextRunSummary = nil
      return summary
    }
    return ExportRunSummary(
      context: context,
      endedAt: Date(),
      enqueuedCount: 0, completedCount: 0, failedCount: 0, skippedCount: 0,
      cancelReason: nil, result: .completed
    )
  }
}

@MainActor
final class FakeAutoSyncDestinationProvider: AutoSyncDestinationProviding {
  let subject = CurrentValueSubject<DestinationSnapshot, Never>(.none)
  var destinationSnapshotPublisher: AnyPublisher<DestinationSnapshot, Never> {
    subject.eraseToAnyPublisher()
  }
}

@MainActor
final class FakeAutoExportScopeProvider: AutoExportScopeProviding {
  let subject = CurrentValueSubject<AutoExportScopeSelection, Never>(
    AutoExportScopeSelection())
  var scopeSelectionPublisher: AnyPublisher<AutoExportScopeSelection, Never> {
    subject.eraseToAnyPublisher()
  }
}

@MainActor
final class FakeAutoSyncImportProvider: AutoSyncImportProviding {
  let subject = CurrentValueSubject<Bool, Never>(false)
  var isImportingPublisher: AnyPublisher<Bool, Never> {
    subject.eraseToAnyPublisher()
  }
}

/// Convenience builder for an AutoSyncEnvironment wired to fakes. The default
/// configuration: idle exporter, no destination, no scopes, not importing,
/// in-memory dirty/retry stores, deterministic test clock.
@MainActor
struct FakeAutoSyncEnvironmentBuilder {
  let exportRunner = FakeAutoSyncExportRunner()
  let destination = FakeAutoSyncDestinationProvider()
  let scopes = FakeAutoExportScopeProvider()
  let photos = FakePersistentChangeSource()
  let importing = FakeAutoSyncImportProvider()
  let dirtyStore = InMemoryAutoSyncDirtyStateStore()
  let retryStore = InMemoryAutoSyncRetryStateStore()
  let runSummaryStore = InMemoryAutoSyncRunSummaryStore()
  let perDestinationTokenStore = InMemoryAutoSyncPerDestinationTokenStore()
  let clock = TestClock()
  let userDefaults: UserDefaults

  init() {
    let suiteName = "test-AutoSyncManager-\(UUID().uuidString)"
    self.userDefaults = UserDefaults(suiteName: suiteName)!
  }

  var environment: AutoSyncEnvironment {
    AutoSyncEnvironment(
      exportRunner: exportRunner,
      destination: destination,
      scopes: scopes,
      photos: photos,
      importing: importing,
      dirtyStateStore: dirtyStore,
      retryStateStore: retryStore,
      runSummaryStore: runSummaryStore,
      perDestinationTokenStore: perDestinationTokenStore,
      clock: clock,
      userDefaults: userDefaults
    )
  }

  func cleanup() {
    UserDefaults().removePersistentDomain(
      forName: userDefaults.dictionaryRepresentation().keys.first ?? "")
  }
}
