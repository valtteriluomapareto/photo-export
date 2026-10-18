import Combine
import Foundation

/// Declares ExportManager's conformance to the AutoSync seam protocols. The
/// implementation methods (`runExport(context:)`, `exportRunStatePublisher`,
/// `versionSelectionPublisher`, `isImportingPublisher`) live on `ExportManager`
/// itself; this file only wires the protocol-conformance declarations so the
/// production wiring in `PhotoExportApp` can pass `ExportManager` directly into
/// `AutoSyncEnvironment` without an adapter.
extension ExportManager: AutoSyncExportRunning {}
extension ExportManager: AutoSyncImportProviding {}

/// ExportManager hosts VariantExporter's UI-state and bookkeeping-aware failure callbacks.
/// The exporter checks generation through ExportQueueCoordinator and holds its renderer
/// directly. Host implementations live on ExportManager; only conformance is declared here.
extension ExportManager: VariantExporter.Host {}

/// ExportManager hosts ExportQueueCoordinator's per-job work and run finalization.
/// The coordinator owns cancellation generation and updates the manager's current-job
/// UI identifiers through its Host callbacks.
extension ExportManager: ExportQueueCoordinator.Host {}

/// ExportManager hosts ImportCoordinator's destination/library/store access and result
/// updates. The coordinator checks generation directly through ExportQueueCoordinator.
extension ExportManager: ImportCoordinator.Host {}
