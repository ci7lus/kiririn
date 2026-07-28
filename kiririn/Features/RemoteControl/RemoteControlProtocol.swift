import Foundation

nonisolated struct RemotePeerIdentity: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let publicKey: Data
}

nonisolated struct RemoteAuthenticationChallenge: Codable, Equatable, Sendable {
    let nonce: Data
    let receiverSignature: Data
}

nonisolated struct RemoteAuthenticationResponse: Codable, Equatable, Sendable {
    let signature: Data
}

nonisolated struct RemotePairingChallenge: Codable, Equatable, Sendable {
    let receiverIdentity: RemotePeerIdentity
    let nonce: Data
}

nonisolated struct RemotePairingResponse: Codable, Equatable, Sendable {
    let pinProof: Data
    let signature: Data
}

nonisolated struct RemotePairingAccepted: Codable, Equatable, Sendable {
    let receiverIdentity: RemotePeerIdentity
    let signature: Data
}

nonisolated enum RemoteControlPayload: Codable, Equatable, Sendable {
    case hello(RemotePeerIdentity)
    case pairingRequired(RemotePairingChallenge)
    case pairingResponse(RemotePairingResponse)
    case pairingAccepted(RemotePairingAccepted)
    case authenticationChallenge(RemoteAuthenticationChallenge)
    case authenticationResponse(RemoteAuthenticationResponse)
    case authenticationAccepted
    case authenticationRejected
    case playerSnapshots([RemotePlayerSnapshot])
    case command(RemotePlayerCommandRequest)
    case commandResponse(RemoteCommandResponse)
}

nonisolated struct RemoteControlEnvelope: Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let protocolVersion: Int
    let messageID: UUID
    let payload: RemoteControlPayload

    init(
        messageID: UUID = UUID(),
        payload: RemoteControlPayload
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.messageID = messageID
        self.payload = payload
    }
}
