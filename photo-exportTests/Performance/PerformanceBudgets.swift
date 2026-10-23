/// Structurally justified count limits shared by the performance regression tests.
/// Add each limit with the test that establishes its bound; budget increases need a PR note.
enum PerformanceBudgets {
  // Record status is not a grid-layout input; unrelated asset records have distinct dependencies.
  static let gridBodiesPerRecordPublication = 0
  static let unrelatedTileBodiesPerRecordPublication = 0
  // Selection belongs to tiles and details, independently of summaries and the library layout.
  static let summaryScansPerSelection = 0
  static let libraryBodiesPerAssetSelection = 0
  // Partial batches do not scan; completion supplies one final asset snapshot.
  static let summaryScansPerProgressiveLoad = 1
}
