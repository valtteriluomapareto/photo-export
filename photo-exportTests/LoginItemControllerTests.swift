import Foundation
import ServiceManagement
import Testing

@testable import Photo_Export

@MainActor
struct LoginItemControllerTests {
  private final class FakeService: LoginItemService {
    var status: LoginItemController.Status = .notRegistered
    var nextStatus: LoginItemController.Status = .requiresApproval
    var error: Error?
    var registered = 0
    var unregistered = 0
    var opened = 0
    func register() throws {
      registered += 1
      status = nextStatus
      if let error { throw error }
    }
    func unregister() throws {
      unregistered += 1
      status = nextStatus
      if let error { throw error }
    }
    func openSystemLoginItems() { opened += 1 }
  }

  @Test func refreshReflectsExternalChangesAndSettingsOpenIsDelegated() {
    let service = FakeService()
    let controller = LoginItemController(service: service)
    #expect(controller.status == .notRegistered)
    service.status = .enabled
    #expect(controller.status == .notRegistered)
    controller.refresh()
    #expect(controller.status == .enabled)
    controller.openSystemLoginItems()
    #expect(service.opened == 1)
    #expect(service.registered == 0 && service.unregistered == 0)
  }

  @Test(arguments: [false, true], [false, true])
  func actionsAlwaysRefreshActualStatus(register: Bool, fails: Bool) {
    let service = FakeService()
    service.status = register ? .notRegistered : .enabled
    service.nextStatus = register ? .requiresApproval : (fails ? .requiresApproval : .notRegistered)
    if fails { service.error = CocoaError(.fileWriteNoPermission) }
    let controller = LoginItemController(service: service)
    if register { controller.register() } else { controller.unregister() }
    #expect(controller.status == service.nextStatus)
    #expect(service.registered == (register ? 1 : 0))
    #expect(service.unregistered == (register ? 0 : 1))
  }

  @Test func failedUnregisterCanRemainEnabledWithoutOptimisticStateChange() {
    let service = FakeService()
    service.status = .enabled
    service.nextStatus = .enabled
    service.error = CocoaError(.fileWriteNoPermission)
    let controller = LoginItemController(service: service)
    controller.unregister()
    #expect(controller.status == .enabled)
    #expect(service.unregistered == 1)
  }

  /// The Settings toggle and footer read `status`; a refresh that finds the same status stores
  /// an equal value and must not re-render them.
  @Test func statusChangesNotifyReadersAndUnchangedRefreshesDoNot() {
    let service = FakeService()
    let controller = LoginItemController(service: service)
    let probe = ObservationProbe { _ = controller.status }
    controller.refresh()
    #expect(probe.changeCount == 0)
    service.status = .enabled
    controller.refresh()
    #expect(probe.changeCount == 1)
    controller.openSystemLoginItems()
    #expect(probe.changeCount == 1)
  }

  @Test func statusMappingAndExactFooterCopy() {
    let statuses: [(SMAppService.Status, LoginItemController.Status)] = [
      (.enabled, .enabled), (.requiresApproval, .requiresApproval),
      (.notRegistered, .notRegistered), (.notFound, .notFound),
    ]
    for (system, expected) in statuses {
      #expect(SystemLoginItemService.map(system) == expected)
    }
    let copy: [(LoginItemController.Status, String)] = [
      (.enabled, "Photo Export will start automatically when you log in."),
      (.requiresApproval, "macOS is waiting for you to confirm in System Settings → Login Items."),
      (.notRegistered, "Photo Export won't auto-start at login."),
      (.notFound, "Move Photo Export into your Applications folder to enable launch at login."),
      (.unknown, "Status unknown — check System Settings → Login Items."),
    ]
    let service = FakeService()
    let controller = LoginItemController(service: service)
    for (status, text) in copy {
      service.status = status
      controller.refresh()
      #expect(controller.status == status)
      #expect(controller.status.footerText == text)
    }
  }
}

struct AutoSyncRunNowEligibilityTests {
  @Test func allStatesKeepExistingExportNowEligibility() {
    let cases: [(AutoSyncState, Bool)] = [
      (.disabled, false), (.blocked(.destinationUnavailable), false),
      (.running(reason: .userExportNow), false), (.idle, true),
      (.scheduled(reason: .userExportNow, fireAt: .distantFuture), true),
      (.waiting(.destinationUnavailable), true),
    ]
    for (state, expected) in cases { #expect(state.canRunNow == expected) }
  }
}
