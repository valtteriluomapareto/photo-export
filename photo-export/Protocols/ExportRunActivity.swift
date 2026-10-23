/// Keeps a logical export run active while preparation and queued jobs are outstanding.
@MainActor
protocol ExportRunActivity {
  func begin()
  func end()
}
