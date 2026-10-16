import Testing

@testable import Photo_Export

struct ExportVariantRecoveryTests {
  @Test func typedReasonsSelectExistingFriendlyCopy() {
    #expect(
      ExportVariantRecovery.friendlyCopy(for: .interrupted, label: "Original")
        == "Original: Will retry on next export")
    #expect(
      ExportVariantRecovery.friendlyCopy(for: .editedResourceUnavailable, label: "Edited")
        == "Edited version could not be exported this time. Future exports will try again.")
    #expect(
      ExportVariantRecovery.friendlyCopy(for: .editedUnavailableOriginalBackedUp, label: "Edited")
        == "Edited version was unavailable. The original was saved as a `_orig` companion.")
    #expect(
      ExportVariantRecovery.friendlyCopy(for: .pairedVideoUnavailable, label: "Original")
        == "Original: Photos doesn't currently expose a paired video for this Live Photo. The still was exported."
    )
    #expect(ExportVariantRecovery.isRecoverable(.interrupted))
    #expect(ExportVariantRecovery.isRecoverable(.editedResourceUnavailable))
    let unknown = ExportVariantReason(rawValue: "future")
    let recoverable = ExportVariantRecovery.isRecoverable(unknown)
    #expect(recoverable == false)
    #expect(
      ExportVariantRecovery.friendlyCopy(for: .init(rawValue: "future"), label: "Edited") == nil)
    #expect(ExportVariantRecovery.friendlyCopy(for: nil, label: "Edited") == nil)
  }
}
