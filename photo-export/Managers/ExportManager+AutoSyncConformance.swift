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

/// Phase 3a: ExportManager hosts `VariantExporter` so the exporter can call back for
/// generation checks, UI-state mutations, bookkeeping-aware failure recording, and the
/// rendered-media bridge. The required methods live on `ExportManager` itself; this is
/// just the conformance wire-up.
extension ExportManager: VariantExporter.Host {}
