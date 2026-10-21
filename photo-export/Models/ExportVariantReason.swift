import Foundation

/// Stable domain codes, independent of display text. Unknown future codes round-trip
/// as strings and confer no accepted-completion or friendly-recovery semantics.
struct ExportVariantReason: RawRepresentable, Codable, Equatable, Sendable {
  let rawValue: String

  init(rawValue: String) { self.rawValue = rawValue }

  static let interrupted = Self(rawValue: "interrupted")
  static let editedResourceUnavailable = Self(rawValue: "editedResourceUnavailable")
  static let editedUnavailableOriginalBackedUp = Self(rawValue: "editedUnavailableOriginalBackedUp")
  static let pairedVideoUnavailable = Self(rawValue: "pairedVideoUnavailable")

  init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  /// Frozen identities used by historical files and existing AutoSync retry state.
  /// These literals must not follow future edits/localization of display copy.
  var legacySignature: String? {
    switch self {
    case .interrupted: return "Interrupted before completion"
    case .editedResourceUnavailable: return "Edited resource unavailable"
    case .editedUnavailableOriginalBackedUp:
      return "Edited resource unavailable; original backed up as _orig"
    case .pairedVideoUnavailable:
      return "Photos has no exportable paired video resource for this Live Photo"
    default: return nil
    }
  }

  /// Called only by legacy decoding, never by new-record initializers or writers.
  static func decodeLegacy(message: String?) -> Self? {
    guard let message else { return nil }
    return [
      interrupted, editedResourceUnavailable, editedUnavailableOriginalBackedUp,
      pairedVideoUnavailable,
    ]
    .first { $0.legacySignature == message }
  }
}

/// Typed transport for renderer/converter failure; preserves the existing retry
/// category/signature (Export:9) while conveying the domain reason without parsing text.
struct EditedResourceUnavailableError: CustomNSError {
  static let errorDomain = "Export"
  var errorCode: Int { ExportErrorCode.editedResourceUnavailable.rawValue }
  var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: ExportVariantRecovery.editedResourceUnavailableMessage]
  }
}
