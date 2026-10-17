import Testing

@testable import Photo_Export

struct DestinationStatusTests {
  @Test func reasonsAndRecoveryActionsAreSpecific() {
    let cases: [(ExportDestinationStatus, String, Bool, Bool)] = [
      (.noSelection, "Choose an export folder to export.", false, false),
      (.ready, "Export folder is ready.", false, false),
      (
        .unreachable,
        "Export folder is unavailable. Reconnect the drive or network share to export.", false, true
      ),
      (
        .permissionRequired,
        "Export folder access needs restoring. Reconnect the drive, then choose the same folder if needed.",
        true, true
      ),
      (
        .readOnly, "Export folder is read-only. Allow write access or choose a writable folder.",
        true, true
      ),
      (
        .notDirectory, "Selected export path is not a folder. Choose the export folder again.",
        true, true
      ),
      (
        .bookmarkSaveFailed, "Could not save folder access. Choose the export folder again.", true,
        true
      ),
    ]
    for (status, text, offersChooser, showsWarning) in cases {
      #expect(status.exportHelp == text)
      #expect(status.offersFolderSelection == offersChooser)
      #expect((status.warningMessage != nil) == showsWarning)
    }
  }
}
