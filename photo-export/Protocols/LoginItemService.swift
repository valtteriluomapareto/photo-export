/// System login-item operations, isolated with the Settings controller.
@MainActor
protocol LoginItemService {
  var status: LoginItemController.Status { get }
  func register() throws
  func unregister() throws
  func openSystemLoginItems()
}
