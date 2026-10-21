/// Stable codes for the `Export` NSError domain. Raw values are persisted in retry
/// signatures such as `Export:9`; never renumber or reuse them.
enum ExportErrorCode: Int, Sendable {
  /// Security-scoped access to the export folder could not begin.
  case exportFolderAccessDenied = 1
  /// A final destination already exists or changed before adoption.
  case destinationAlreadyExists = 2
  /// The resource writer could not find the requested Photos asset.
  case assetNotFoundForResourceWrite = 3
  /// The requested PhotoKit resource could not be matched.
  case matchingResourceNotFound = 4
  /// A paired original-side filename already exists or belongs to another record.
  case pairedOriginalFilenameConflict = 5
  /// The video renderer could not find the requested Photos asset.
  case assetNotFoundForVideoRender = 6
  /// Photos returned no video export session.
  case videoExportSessionUnavailable = 7
  /// The video export session could not produce a successful result.
  case videoExportFailed = 8
  /// The edited resource could not be rendered or converted.
  case editedResourceUnavailable = 9
  /// The source image could not be decoded for conversion.
  case imageDecodeFailed = 10
  /// A timeline placement has no year and month.
  case invalidTimelinePlacement = 11
}
