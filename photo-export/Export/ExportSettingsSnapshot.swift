/// Settings frozen when the user starts an export. Pass this value intact through
/// preparation and planning so later setting changes cannot alter queued work.
/// HEIC conversion intentionally remains live at planning/write time.
struct ExportSettingsSnapshot: Equatable, Sendable {
  let selection: ExportVersionSelection
  let livePhotosPaired: Bool
  let videoLayout: ExportVideoLayout

  init(
    selection: ExportVersionSelection,
    livePhotosPaired: Bool = false,
    videoLayout: ExportVideoLayout = .flat
  ) {
    self.selection = selection
    self.livePhotosPaired = livePhotosPaired
    self.videoLayout = videoLayout
  }

  @MainActor
  init(manager: ExportManager, selectionOverride: ExportVersionSelection? = nil) {
    selection = selectionOverride ?? manager.versionSelection
    livePhotosPaired = manager.livePhotosPairedExport
    videoLayout = manager.videoLayout
  }
}
