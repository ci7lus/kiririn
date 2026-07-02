import Foundation

nonisolated enum ConnectionStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

@Observable
class ServerConnectionState {
    let serverId: String
    var isEnabled: Bool
    var status: ConnectionStatus
    var lastError: String?
    var lastConnectedAt: Date?
    var version: String?

    init(serverId: String, isEnabled: Bool = true) {
        self.serverId = serverId
        self.isEnabled = isEnabled
        self.status = .disconnected
    }
}
