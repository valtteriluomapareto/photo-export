import Foundation

enum ExportStatus: String, Codable, Equatable {
  case pending
  case inProgress
  case done
  case failed
}

/// Per-variant export state. One of these lives in an `ExportRecord`'s
/// `variants` dictionary for each variant the pipeline has touched for the
/// asset.
struct ExportVariantRecord: Codable, Equatable {
  var filename: String?
  var status: ExportStatus
  var exportDate: Date?
  var lastError: String?
}

/// Named, well-known recoverable failure cases. Persisted as the `lastError`
/// string on a `.failed` variant, then matched in the UI to render with
/// non-promising but softer copy and `.secondary` color rather than red.
///
/// Add new cases here only when the failure has a clearly recoverable shape;
/// generic `.failed` variants with arbitrary error messages should keep the
/// hard-failure rendering. The promise the UI makes is "future exports will
/// try again," which is true for these named cases because the pipeline
/// retries any non-`.done` variant on the next enqueue.
enum ExportVariantRecovery {
  /// Variant was left as `.inProgress` before the app crashed or was force-
  /// quit. Recovered to `.failed` with this message at load time. Also used
  /// to migrate legacy flat records whose status was `.inProgress`.
  static let interruptedMessage = "Interrupted before completion"

  /// Photos did not provide an edited-side resource for an asset whose
  /// `hasAdjustments == true`. Sometimes transient (an iCloud full-size
  /// render that hasn't materialised) and sometimes persistent (PhotoKit
  /// just doesn't expose one). The export pipeline will attempt a
  /// `_orig` fallback after the main variant loop; on success the
  /// variant's `lastError` is rewritten to
  /// `editedUnavailableOriginalBackedUpMessage` so future runs know the
  /// asset is covered.
  static let editedResourceUnavailableMessage = "Edited resource unavailable"

  /// Terminal state for issue #22: the edited resource was unavailable
  /// AND the `_orig` fallback successfully wrote the original. The asset
  /// is considered covered under `.edited` selection — `isExported`
  /// returns true and the queue stops re-attempting the edit.
  ///
  /// Disambiguating sentinel rather than a filename-shape check (e.g.
  /// "filename ends in `_orig`") because that shape collides with real
  /// user filenames like `vacation_orig.JPG`. Per-PR review feedback.
  static let editedUnavailableOriginalBackedUpMessage =
    "Edited resource unavailable; original backed up as _orig"

  /// Returns true when `lastError` matches a known recoverable case the UI
  /// can render with softer copy.
  static func isRecoverable(_ message: String?) -> Bool {
    guard let message else { return false }
    return message == interruptedMessage
      || message == editedResourceUnavailableMessage
      || message == editedUnavailableOriginalBackedUpMessage
  }

  /// User-facing copy for a recoverable failure. Returns nil when the
  /// message is not a known case — callers fall back to the raw error.
  static func friendlyCopy(for message: String?, label: String) -> String? {
    switch message {
    case interruptedMessage:
      return "\(label): Will retry on next export"
    case editedResourceUnavailableMessage:
      return "\(label) version could not be exported this time. Future exports will try again."
    case editedUnavailableOriginalBackedUpMessage:
      return "\(label) version was unavailable. The original was saved as a `_orig` companion."
    default:
      return nil
    }
  }
}

/// Canonical export state for a single Photos asset.
///
/// The current on-disk schema stores per-variant state inside `variants`. The
/// `Codable` implementation decodes both the current schema and the legacy
/// flat shape (single `filename` + `status` + `exportDate` + `lastError`) so
/// existing snapshots and JSONL logs keep working across upgrade. Legacy flat
/// records are synthesized into a single `.original` variant.
///
/// Encoding always emits the new schema. Legacy fields are dropped on the
/// next write/compaction.
struct ExportRecord: Codable, Equatable {
  let id: String  // PHAsset.localIdentifier
  var year: Int
  var month: Int  // 1…12
  var relPath: String  // e.g., "2025/02/"
  var variants: [ExportVariant: ExportVariantRecord]

  init(
    id: String,
    year: Int,
    month: Int,
    relPath: String,
    variants: [ExportVariant: ExportVariantRecord] = [:]
  ) {
    self.id = id
    self.year = year
    self.month = month
    self.relPath = relPath
    self.variants = variants
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case id, year, month, relPath, variants
    // Legacy flat fields
    case filename, status, exportDate, lastError
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.year = try container.decode(Int.self, forKey: .year)
    self.month = try container.decode(Int.self, forKey: .month)
    self.relPath = try container.decode(String.self, forKey: .relPath)

    let decodedVariants = try container.decodeIfPresent(
      [String: ExportVariantRecord].self, forKey: .variants)

    if let decodedVariants, !decodedVariants.isEmpty {
      var map: [ExportVariant: ExportVariantRecord] = [:]
      for (key, value) in decodedVariants {
        guard let variant = ExportVariant(rawValue: key) else { continue }
        map[variant] = value
      }
      self.variants = map
      return
    }

    // Legacy flat record: synthesize a single `.original` variant.
    let legacyFilename = try container.decodeIfPresent(String.self, forKey: .filename)
    let legacyStatus = try container.decodeIfPresent(ExportStatus.self, forKey: .status) ?? .pending
    let legacyExportDate = try container.decodeIfPresent(Date.self, forKey: .exportDate)
    let legacyError = try container.decodeIfPresent(String.self, forKey: .lastError)

    let migratedStatus: ExportStatus
    let migratedError: String?
    if legacyStatus == .inProgress {
      migratedStatus = .failed
      migratedError = ExportVariantRecovery.interruptedMessage
    } else {
      migratedStatus = legacyStatus
      migratedError = legacyError
    }

    self.variants = [
      .original: ExportVariantRecord(
        filename: legacyFilename,
        status: migratedStatus,
        exportDate: legacyExportDate,
        lastError: migratedError
      )
    ]
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(year, forKey: .year)
    try container.encode(month, forKey: .month)
    try container.encode(relPath, forKey: .relPath)
    // Encode variants with stable string keys.
    var stringKeyed: [String: ExportVariantRecord] = [:]
    for (variant, record) in variants {
      stringKeyed[variant.rawValue] = record
    }
    try container.encode(stringKeyed, forKey: .variants)
  }
}

struct ExportRecordMutation: Codable, Equatable {
  enum Operation: String, Codable {
    case upsert
    case delete
  }

  let op: Operation
  let id: String
  var record: ExportRecord?

  static func upsert(_ record: ExportRecord) -> ExportRecordMutation {
    ExportRecordMutation(op: .upsert, id: record.id, record: record)
  }

  static func delete(id: String) -> ExportRecordMutation {
    ExportRecordMutation(op: .delete, id: id, record: nil)
  }
}

enum MonthExportStatus: String {
  case notExported
  case partial
  case complete
}

struct MonthStatusSummary: Equatable {
  let year: Int
  let month: Int
  let exportedCount: Int
  let totalCount: Int
  let status: MonthExportStatus
}
