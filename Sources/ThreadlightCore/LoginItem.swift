import ServiceManagement

public enum LoginItemStatus: Sendable {
    case disabled, enabled, requiresApproval, unavailable
}

protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

private struct SystemLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .disabled
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// System state is authoritative, including changes made in System Settings.
/// Never persist a separate preference that could falsely claim registration.
public final class LoginItemController {
    private let service: any LoginItemService
    public convenience init() { self.init(service: SystemLoginItem()) }
    init(service: any LoginItemService) { self.service = service }
    public var status: LoginItemStatus { service.status }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try service.register() } else { try service.unregister() }
    }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
