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
