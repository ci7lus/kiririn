import Foundation

nonisolated enum ConnectionStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

nonisolated struct ServerOperationFeedbackContent: Sendable, Equatable {
    struct Field: Sendable, Equatable {
        let label: String
        let value: String
    }

    let title: String
    let message: String?
    let fields: [Field]
    let response: String?

    init(
        title: String,
        message: String? = nil,
        fields: [Field] = [],
        response: String? = nil
    ) {
        self.title = title
        self.message = message
        self.fields = fields
        self.response = response
    }
}

@Observable
class ServerConnectionState {
    let serverId: String
    var isEnabled: Bool
    var status: ConnectionStatus
    var lastError: String?
    var lastErrorDetail: ServerOperationFeedbackContent?
    var lastConnectedAt: Date?
    var version: String?

    init(serverId: String, isEnabled: Bool = true) {
        self.serverId = serverId
        self.isEnabled = isEnabled
        self.status = .disconnected
    }
}
