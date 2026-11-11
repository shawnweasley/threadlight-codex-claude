import Testing
@testable import ThreadlightCore

private final class LoginServiceStub: LoginItemService {
    enum Failure: Error { case rejected }
    var status: LoginItemStatus = .disabled
    var registrationStatus: LoginItemStatus = .enabled
    var fails = false
    var registrations = 0
    var removals = 0
    func register() throws {
        registrations += 1
        if fails { throw Failure.rejected }
        status = registrationStatus
    }
    func unregister() throws {
        removals += 1
        if fails { throw Failure.rejected }
        status = .disabled
    }
}

@Suite struct LoginItemTests {
    @Test func constructionDoesNotRegisterAndExternalChangesRemainAuthoritative() throws {
        let service = LoginServiceStub()
        let item = LoginItemController(service: service)
        #expect(item.status == .disabled)
        #expect(service.registrations == 0 && service.removals == 0)
        try item.setEnabled(true)
        #expect(item.status == .enabled && service.registrations == 1)
        service.status = .requiresApproval
        #expect(item.status == .requiresApproval)
        try item.setEnabled(false)
        #expect(item.status == .disabled && service.removals == 1)
    }

    @Test func approvalAndFailuresNeverBecomeFalseCheckmarks() throws {
        let service = LoginServiceStub()
        let controller = LoginItemController(service: service)
        service.registrationStatus = .requiresApproval
        try controller.setEnabled(true)
        #expect(controller.status == .requiresApproval)
        service.fails = true
        #expect(throws: LoginServiceStub.Failure.self) { try controller.setEnabled(false) }
        #expect(controller.status == .requiresApproval)
        service.status = .disabled
        #expect(throws: LoginServiceStub.Failure.self) { try controller.setEnabled(true) }
        #expect(controller.status == .disabled)
        service.status = .enabled
        #expect(throws: LoginServiceStub.Failure.self) { try controller.setEnabled(false) }
        #expect(controller.status == .enabled)
    }
}
