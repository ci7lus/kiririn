import Foundation

nonisolated enum ConnectionStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

@Observable
class BackendConnectionState {
    let backendId: String
    var isEnabled: Bool
    var status: ConnectionStatus
    var lastError: String?
    var lastConnectedAt: Date?
    var version: String?

    init(backendId: String, isEnabled: Bool = true) {
        self.backendId = backendId
        self.isEnabled = isEnabled
        self.status = .disconnected
    }
}
