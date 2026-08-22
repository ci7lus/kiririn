import CryptoKit
import Foundation

@MainActor
@Observable
final class RemoteControlService {
    private enum OperationMode {
        case idle
        case receiver
        case controller
    }

    private static let receiverEnabledKey = "kiririn.remote-control.receiver-enabled"
    private static let maximumMessageSize = 256 * 1024
    private static let maximumPairingAttempts = 5

    private(set) var discoveredPeers: [RemoteDiscoveredPeer] = []
    private(set) var trustedPeers: [RemoteTrustedPeer] = []
    private(set) var remotePlayers: [RemotePlayerSnapshot] = []
    private(set) var connectionStatus: RemoteConnectionStatus = .idle
    private(set) var pairingRequest: RemotePairingRequest?
    private(set) var pairingPIN = ""
    private(set) var pairingPINExpiresAt = Date()
    private(set) var isReceiverEnabled: Bool
    private(set) var lastErrorMessage: String?
    var selectedPlayerID: String?

    var isReconnecting: Bool {
        if case .reconnecting = connectionStatus {
            return true
        }
        return false
    }

    private let defaults: UserDefaults
    private let trustedPeerStore: RemoteTrustedPeerStore
    private let dispatcher = RemotePlayerCommandDispatcher()
    private var identityIsPersistent = true
    @ObservationIgnored private lazy var identity: RemoteLocalIdentity = {
        let displayName = Self.localDisplayName()
        do {
            return try RemoteIdentityStore().loadOrCreate(displayName: displayName)
        } catch {
            identityIsPersistent = false
            lastErrorMessage = "端末情報をKeychainに保存できませんでした"
            return RemoteLocalIdentity(
                id: UUID().uuidString,
                displayName: displayName,
                privateKey: .init()
            )
        }
    }()
    @ObservationIgnored private lazy var transport: MultipeerRemoteTransport = {
        let transport = MultipeerRemoteTransport(
            displayName: identity.displayName,
            identityID: identity.id
        )
        transport.onEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }
        return transport
    }()
    private var operationMode: OperationMode = .idle
    private var hasLoadedTrustedPeers = false
    private var currentConnectionID: String?
    private var remoteIdentity: RemotePeerIdentity?
    private var pairingChallenge: RemotePairingChallenge?
    private var submittedPIN: String?
    private var authenticationNonce: Data?
    private var isAuthenticated = false
    private var authenticatedConnectionID: String?
    private var awaitingAuthenticationAcceptanceConnectionID: String?
    private var reconnectingControllerPeerID: String?
    private var reconnectingControllerPeerName: String?
    private var reconnectingDisconnectPendingID: String?
    private var reconnectionTask: Task<Void, Never>?
    private var isApplicationInBackground = false
    private var pairingFailureCount = 0
    private var snapshotTask: Task<Void, Never>?
    private var lastSentSnapshots: [RemotePlayerSnapshot] = []
    private var processedCommandResponses: [UUID: RemoteCommandResponse] = [:]
    private var processedCommandOrder: [UUID] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let trustedPeerStore = RemoteTrustedPeerStore()
        self.trustedPeerStore = trustedPeerStore
        isReceiverEnabled = defaults.bool(forKey: Self.receiverEnabledKey)

        rotatePairingPIN()
    }

    func configure(appModel: AppModel) {
        dispatcher.configure(appModel: appModel)
    }

    func restoreReceiverIfEnabled() {
        guard isReceiverEnabled, operationMode != .receiver else { return }
        startReceiver()
    }

    func prepare() {
        _ = loadTrustedPeersIfNeeded()
    }

    func setReceiverEnabled(_ enabled: Bool) {
        guard enabled != isReceiverEnabled else { return }
        isReceiverEnabled = enabled
        defaults.set(enabled, forKey: Self.receiverEnabledKey)
        if enabled {
            startReceiver()
        } else {
            stopReceiver()
        }
    }

    func rotatePairingPIN() {
        pairingPIN = String(format: "%06d", Int.random(in: 0..<1_000_000))
        pairingPINExpiresAt = Date().addingTimeInterval(5 * 60)
        pairingFailureCount = 0
    }

    func handleAppDidEnterBackground() {
        isApplicationInBackground = true
        reconnectionTask?.cancel()
        reconnectionTask = nil

        guard operationMode == .controller,
            isAuthenticated,
            let connectionID = authenticatedConnectionID ?? currentConnectionID
        else {
            return
        }
        rememberControllerForReconnection(connectionID: connectionID)
    }

    func handleAppDidBecomeActive() {
        isApplicationInBackground = false

        guard operationMode == .controller,
            let connectionID = reconnectingControllerPeerID
        else {
            return
        }

        if isAuthenticated, authenticatedConnectionID == connectionID {
            beginControllerReconnection(connectionID: connectionID)
        } else if currentConnectionID == nil {
            scheduleControllerReconnection(after: .milliseconds(0))
        }
    }

    func startBrowsing() {
        guard
            operationMode != .controller
                || currentConnectionID == nil
        else {
            return
        }
        _ = identity
        guard identityIsPersistent else {
            connectionStatus = .failed("端末情報をKeychainに保存できませんでした")
            return
        }
        guard loadTrustedPeersIfNeeded() else {
            connectionStatus = .failed("登録済み端末をKeychainから読み込めませんでした")
            return
        }
        let preservesRemotePlayers = reconnectingControllerPeerID != nil
        operationMode = .controller
        resetConnectionState(preservingRemotePlayers: preservesRemotePlayers)
        discoveredPeers = []
        if preservesRemotePlayers {
            connectionStatus = .reconnecting(reconnectingControllerPeerName ?? "接続先")
        } else {
            connectionStatus = .browsing
        }
        transport.stopAdvertising()
        reconnectionTask?.cancel()
        reconnectionTask = nil
        transport.startBrowsing()
    }

    func stopBrowsing() {
        transport.stopBrowsing()
        guard !isAuthenticated, !isApplicationInBackground else { return }

        if currentConnectionID != nil {
            transport.disconnect()
        }
        clearControllerReconnection()
        resetConnectionState()
        operationMode = .idle
        connectionStatus = .idle
    }

    func connect(to peer: RemoteDiscoveredPeer) {
        clearControllerReconnection()
        operationMode = .controller
        currentConnectionID = peer.id
        connectionStatus = .connecting(peerID: peer.id, displayName: peer.displayName)
        lastErrorMessage = nil
        transport.connect(to: peer.id)
    }

    func disconnect() {
        clearControllerReconnection()
        transport.disconnect()
        resetConnectionState()
        if operationMode == .controller {
            connectionStatus = .browsing
            transport.startBrowsing()
        } else {
            connectionStatus = .idle
        }
    }

    func submitPairingPIN(_ pin: String) {
        guard operationMode == .controller,
            let pairingChallenge,
            let currentConnectionID
        else {
            return
        }
        let normalizedPIN = pin.filter(\.isNumber)
        guard normalizedPIN.count == 6 else {
            lastErrorMessage = "PINコードは6桁で入力してください"
            return
        }

        let data = RemoteControlCryptography.pairingData(
            nonce: pairingChallenge.nonce,
            receiverID: pairingChallenge.receiverIdentity.id,
            controllerID: identity.id
        )
        guard let signature = try? identity.signature(for: data) else {
            lastErrorMessage = "端末認証に失敗しました"
            return
        }
        submittedPIN = normalizedPIN
        awaitingAuthenticationAcceptanceConnectionID = currentConnectionID
        connectionStatus = .pairing(pairingChallenge.receiverIdentity.displayName)
        guard
            send(
                RemoteControlEnvelope(
                    payload: .pairingResponse(
                        RemotePairingResponse(
                            pinProof: RemoteControlCryptography.pairingProof(
                                pin: normalizedPIN,
                                data: data
                            ),
                            signature: signature
                        )
                    )
                ),
                to: currentConnectionID
            )
        else {
            rejectConnection(message: "ペアリング情報を送信できませんでした")
            return
        }
    }

    func cancelPairing() {
        pairingRequest = nil
        submittedPIN = nil
        disconnect()
    }

    func forgetTrustedPeer(id: String) {
        let updatedPeers = trustedPeers.filter { $0.id != id }
        do {
            try trustedPeerStore.save(updatedPeers)
            trustedPeers = updatedPeers
        } catch {
            lastErrorMessage = "登録済み端末をKeychainから削除できませんでした"
            return
        }
        if remoteIdentity?.id == id {
            disconnect()
        }
        rotatePairingPIN()
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func sendCommand(
        _ command: RemoteControlCommand,
        playerID: String? = nil
    ) {
        guard operationMode == .controller,
            isAuthenticated,
            let currentConnectionID,
            let targetPlayerID = playerID ?? selectedPlayerID
        else {
            lastErrorMessage = "リモコンが接続されていません"
            return
        }
        send(
            RemoteControlEnvelope(
                payload: .command(
                    RemotePlayerCommandRequest(
                        playerID: targetPlayerID,
                        command: command
                    )
                )
            ),
            to: currentConnectionID
        )
    }

    func registerWindowEndpoint(
        _ endpoint: any RemotePlayerWindowEndpoint,
        playerID: String
    ) {
        dispatcher.register(endpoint, forPlayerID: playerID)
    }

    func unregisterWindowEndpoint(playerID: String) {
        dispatcher.unregisterWindowEndpoint(forPlayerID: playerID)
    }

    private func startReceiver() {
        guard operationMode != .receiver else { return }
        _ = identity
        guard identityIsPersistent else {
            connectionStatus = .failed("端末情報をKeychainに保存できませんでした")
            return
        }
        guard loadTrustedPeersIfNeeded() else {
            connectionStatus = .failed("登録済み端末をKeychainから読み込めませんでした")
            return
        }
        operationMode = .receiver
        clearControllerReconnection()
        resetConnectionState()
        rotatePairingPIN()
        transport.stopBrowsing()
        transport.startAdvertising()
    }

    private func stopReceiver() {
        transport.stopAdvertising()
        transport.disconnect()
        operationMode = .idle
        clearControllerReconnection()
        resetConnectionState()
        connectionStatus = .idle
    }

    private func handleTransportEvent(_ event: RemoteTransportEvent) {
        switch event {
        case .discovered(let peer):
            if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
                discoveredPeers[index] = peer
            } else {
                discoveredPeers.append(peer)
                discoveredPeers.sort {
                    $0.displayName.localizedCompare($1.displayName) == .orderedAscending
                }
            }
            reconnect(to: peer)
        case .lost(let connectionID):
            discoveredPeers.removeAll { $0.id == connectionID }
        case .connecting(let connectionID):
            guard currentConnectionID == nil || currentConnectionID == connectionID else {
                return
            }
            currentConnectionID = connectionID
            let name =
                discoveredPeers.first(where: { $0.id == connectionID })?.displayName
                ?? remoteIdentity?.displayName
                ?? "接続先"
            if reconnectingControllerPeerID == connectionID {
                connectionStatus = .reconnecting(reconnectingControllerPeerName ?? name)
            } else {
                connectionStatus = .connecting(peerID: connectionID, displayName: name)
            }
        case .connected(let connectionID):
            guard currentConnectionID == nil || currentConnectionID == connectionID else {
                return
            }
            currentConnectionID = connectionID
            if operationMode == .controller {
                transport.stopBrowsing()
            }
            send(
                RemoteControlEnvelope(payload: .hello(identity.peerIdentity)),
                to: connectionID
            )
        case .disconnected(let connectionID):
            guard currentConnectionID == nil || currentConnectionID == connectionID else {
                return
            }

            if reconnectingDisconnectPendingID == connectionID {
                reconnectingDisconnectPendingID = nil
                scheduleControllerReconnection(after: .milliseconds(0))
                return
            }

            let shouldReconnect =
                operationMode == .controller
                && (reconnectingControllerPeerID == connectionID
                    || (isAuthenticated && authenticatedConnectionID == connectionID))
            if shouldReconnect {
                rememberControllerForReconnection(connectionID: connectionID)
                let name = reconnectingControllerPeerName ?? "接続先"
                resetConnectionState(preservingRemotePlayers: true)
                connectionStatus = .reconnecting(name)
                scheduleControllerReconnection(after: .milliseconds(0))
            } else {
                resetConnectionState()
                if operationMode == .controller {
                    connectionStatus = .browsing
                    transport.startBrowsing()
                } else {
                    connectionStatus = .idle
                }
            }
        case .received(let data, let connectionID):
            guard currentConnectionID == connectionID else { return }
            handleReceivedData(data, connectionID: connectionID)
        case .failed(let message):
            if operationMode == .controller,
                reconnectingControllerPeerID != nil
            {
                let name = reconnectingControllerPeerName ?? "接続先"
                resetConnectionState(preservingRemotePlayers: true)
                connectionStatus = .reconnecting(name)
                scheduleControllerReconnection(after: .seconds(1))
                return
            }
            lastErrorMessage = message
            connectionStatus = .failed(message)
        }
    }

    private func handleReceivedData(_ data: Data, connectionID: String) {
        guard data.count <= Self.maximumMessageSize,
            let envelope = try? JSONDecoder().decode(RemoteControlEnvelope.self, from: data),
            envelope.protocolVersion == RemoteControlEnvelope.currentProtocolVersion
        else {
            rejectConnection(message: "接続先と互換性がありません")
            return
        }

        switch envelope.payload {
        case .hello(let peerIdentity):
            remoteIdentity = peerIdentity
            if operationMode == .receiver {
                beginReceiverAuthentication(for: peerIdentity, connectionID: connectionID)
            }
        case .pairingRequired(let challenge):
            handlePairingRequired(challenge)
        case .pairingResponse(let response):
            handlePairingResponse(response, connectionID: connectionID)
        case .pairingAccepted(let accepted):
            handlePairingAccepted(accepted, connectionID: connectionID)
        case .authenticationChallenge(let challenge):
            handleAuthenticationChallenge(challenge, connectionID: connectionID)
        case .authenticationResponse(let response):
            handleAuthenticationResponse(response, connectionID: connectionID)
        case .authenticationAccepted:
            guard operationMode == .controller,
                awaitingAuthenticationAcceptanceConnectionID == connectionID
            else {
                rejectConnection(message: "端末認証の手順が正しくありません")
                return
            }
            authorizeControllerConnection(connectionID: connectionID)
        case .authenticationRejected:
            rejectConnection(message: "端末を認証できませんでした")
        case .playerSnapshots(let snapshots):
            guard operationMode == .controller,
                authenticatedConnectionID == connectionID
            else {
                return
            }
            remotePlayers = snapshots
            if let selectedPlayerID,
                snapshots.contains(where: { $0.id == selectedPlayerID })
            {
                return
            }
            selectedPlayerID = snapshots.first?.id
        case .command(let request):
            handleCommand(
                request,
                messageID: envelope.messageID,
                connectionID: connectionID
            )
        case .commandResponse(let response):
            if let error = response.error {
                lastErrorMessage = commandErrorMessage(error)
            }
        }
    }

    private func beginReceiverAuthentication(
        for peerIdentity: RemotePeerIdentity,
        connectionID: String
    ) {
        if let trusted = trustedPeer(id: peerIdentity.id),
            trusted.publicKey == peerIdentity.publicKey
        {
            let nonce = RemoteControlCryptography.randomNonce()
            let data = RemoteControlCryptography.authenticationData(
                nonce: nonce,
                receiverID: identity.id,
                controllerID: peerIdentity.id
            )
            guard let signature = try? identity.signature(for: data) else {
                rejectConnection(message: "端末認証に失敗しました")
                return
            }
            authenticationNonce = nonce
            send(
                RemoteControlEnvelope(
                    payload: .authenticationChallenge(
                        RemoteAuthenticationChallenge(
                            nonce: nonce,
                            receiverSignature: signature
                        )
                    )
                ),
                to: connectionID
            )
            return
        }

        if Date() >= pairingPINExpiresAt {
            rotatePairingPIN()
        }
        let challenge = RemotePairingChallenge(
            receiverIdentity: identity.peerIdentity,
            nonce: RemoteControlCryptography.randomNonce()
        )
        pairingChallenge = challenge
        connectionStatus = .pairing(peerIdentity.displayName)
        send(
            RemoteControlEnvelope(payload: .pairingRequired(challenge)),
            to: connectionID
        )
    }

    private func handlePairingRequired(_ challenge: RemotePairingChallenge) {
        guard operationMode == .controller else { return }
        if let remoteIdentity,
            remoteIdentity.id != challenge.receiverIdentity.id
                || remoteIdentity.publicKey != challenge.receiverIdentity.publicKey
        {
            rejectConnection(message: "接続先の端末情報が一致しません")
            return
        }
        remoteIdentity = challenge.receiverIdentity
        pairingChallenge = challenge
        pairingRequest = RemotePairingRequest(
            id: challenge.receiverIdentity.id,
            displayName: challenge.receiverIdentity.displayName
        )
        connectionStatus = .pairing(challenge.receiverIdentity.displayName)
    }

    private func handlePairingResponse(
        _ response: RemotePairingResponse,
        connectionID: String
    ) {
        guard operationMode == .receiver,
            let pairingChallenge,
            let remoteIdentity
        else {
            return
        }

        let pairingData = RemoteControlCryptography.pairingData(
            nonce: pairingChallenge.nonce,
            receiverID: identity.id,
            controllerID: remoteIdentity.id
        )
        let isValid =
            Date() < pairingPINExpiresAt
            && RemoteControlCryptography.verifyPairingProof(
                response.pinProof,
                pin: pairingPIN,
                data: pairingData
            )
            && RemoteControlCryptography.verify(
                signature: response.signature,
                data: pairingData,
                publicKey: remoteIdentity.publicKey
            )
        guard isValid else {
            pairingFailureCount += 1
            if pairingFailureCount >= Self.maximumPairingAttempts {
                rotatePairingPIN()
            }
            send(
                RemoteControlEnvelope(payload: .authenticationRejected),
                to: connectionID
            )
            return
        }

        guard let receiverSignature = try? identity.signature(for: pairingData) else {
            rejectConnection(message: "端末認証に失敗しました")
            return
        }
        guard
            send(
                RemoteControlEnvelope(
                    payload: .pairingAccepted(
                        RemotePairingAccepted(
                            receiverIdentity: identity.peerIdentity,
                            signature: receiverSignature
                        )
                    )
                ),
                to: connectionID
            )
        else {
            return
        }
        guard saveTrustedPeer(remoteIdentity) else {
            rejectConnection(message: "登録済み端末をKeychainに保存できませんでした")
            return
        }
        authorizeReceiverConnection(remoteIdentity, connectionID: connectionID)
        rotatePairingPIN()
    }

    private func handlePairingAccepted(
        _ accepted: RemotePairingAccepted,
        connectionID: String
    ) {
        guard operationMode == .controller,
            let pairingChallenge,
            submittedPIN != nil,
            awaitingAuthenticationAcceptanceConnectionID == connectionID,
            accepted.receiverIdentity.id == pairingChallenge.receiverIdentity.id,
            accepted.receiverIdentity.publicKey == pairingChallenge.receiverIdentity.publicKey
        else {
            rejectConnection(message: "接続先の端末情報が一致しません")
            return
        }
        let data = RemoteControlCryptography.pairingData(
            nonce: pairingChallenge.nonce,
            receiverID: accepted.receiverIdentity.id,
            controllerID: identity.id
        )
        guard
            RemoteControlCryptography.verify(
                signature: accepted.signature,
                data: data,
                publicKey: accepted.receiverIdentity.publicKey
            )
        else {
            rejectConnection(message: "接続先を認証できませんでした")
            return
        }

        guard saveTrustedPeer(accepted.receiverIdentity) else {
            rejectConnection(message: "登録済み端末をKeychainに保存できませんでした")
            return
        }
        remoteIdentity = accepted.receiverIdentity
        pairingRequest = nil
        self.submittedPIN = nil
        authorizeControllerConnection(connectionID: connectionID)
    }

    private func handleAuthenticationChallenge(
        _ challenge: RemoteAuthenticationChallenge,
        connectionID: String
    ) {
        guard operationMode == .controller,
            let remoteIdentity,
            let trusted = trustedPeer(id: remoteIdentity.id),
            trusted.publicKey == remoteIdentity.publicKey
        else {
            rejectConnection(message: "接続先は登録済み端末ではありません")
            return
        }

        let data = RemoteControlCryptography.authenticationData(
            nonce: challenge.nonce,
            receiverID: remoteIdentity.id,
            controllerID: identity.id
        )
        guard
            RemoteControlCryptography.verify(
                signature: challenge.receiverSignature,
                data: data,
                publicKey: trusted.publicKey
            ), let responseSignature = try? identity.signature(for: data)
        else {
            rejectConnection(message: "接続先を認証できませんでした")
            return
        }

        guard
            send(
                RemoteControlEnvelope(
                    payload: .authenticationResponse(
                        RemoteAuthenticationResponse(signature: responseSignature)
                    )
                ),
                to: connectionID
            )
        else {
            rejectConnection(message: "端末認証情報を送信できませんでした")
            return
        }
        awaitingAuthenticationAcceptanceConnectionID = connectionID
    }

    private func handleAuthenticationResponse(
        _ response: RemoteAuthenticationResponse,
        connectionID: String
    ) {
        guard operationMode == .receiver,
            let remoteIdentity,
            let nonce = authenticationNonce,
            let trusted = trustedPeer(id: remoteIdentity.id),
            trusted.publicKey == remoteIdentity.publicKey
        else {
            rejectConnection(message: "端末を認証できませんでした")
            return
        }

        let data = RemoteControlCryptography.authenticationData(
            nonce: nonce,
            receiverID: identity.id,
            controllerID: remoteIdentity.id
        )
        guard
            RemoteControlCryptography.verify(
                signature: response.signature,
                data: data,
                publicKey: trusted.publicKey
            )
        else {
            rejectConnection(message: "端末を認証できませんでした")
            return
        }

        authenticationNonce = nil
        guard saveTrustedPeer(remoteIdentity) else {
            rejectConnection(message: "登録済み端末をKeychainに保存できませんでした")
            return
        }
        guard
            send(
                RemoteControlEnvelope(payload: .authenticationAccepted),
                to: connectionID
            )
        else {
            rejectConnection(message: "端末認証情報を送信できませんでした")
            return
        }
        authorizeReceiverConnection(remoteIdentity, connectionID: connectionID)
    }

    private func authorizeReceiverConnection(
        _ peerIdentity: RemotePeerIdentity,
        connectionID: String
    ) {
        isAuthenticated = true
        authenticatedConnectionID = connectionID
        connectionStatus = .connected(peerIdentity.displayName)
        startSnapshotUpdates()
    }

    private func authorizeControllerConnection(connectionID: String) {
        isAuthenticated = true
        authenticatedConnectionID = connectionID
        awaitingAuthenticationAcceptanceConnectionID = nil
        transport.stopBrowsing()
        clearControllerReconnection()
        pairingRequest = nil
        pairingChallenge = nil
        let name = remoteIdentity?.displayName ?? "Mac"
        connectionStatus = .connected(name)
    }

    private func handleCommand(
        _ request: RemotePlayerCommandRequest,
        messageID: UUID,
        connectionID: String
    ) {
        guard operationMode == .receiver,
            authenticatedConnectionID == connectionID
        else {
            let response = RemoteCommandResponse(
                requestID: messageID,
                error: .unauthorized
            )
            send(
                RemoteControlEnvelope(payload: .commandResponse(response)),
                to: connectionID
            )
            return
        }

        if let cached = processedCommandResponses[messageID] {
            send(
                RemoteControlEnvelope(payload: .commandResponse(cached)),
                to: connectionID
            )
            return
        }

        let response = RemoteCommandResponse(
            requestID: messageID,
            error: dispatcher.execute(request)
        )
        rememberCommandResponse(response, messageID: messageID)
        send(
            RemoteControlEnvelope(payload: .commandResponse(response)),
            to: connectionID
        )
        sendSnapshotsIfChanged()
    }

    private func rememberCommandResponse(
        _ response: RemoteCommandResponse,
        messageID: UUID
    ) {
        processedCommandResponses[messageID] = response
        processedCommandOrder.append(messageID)
        if processedCommandOrder.count > 100 {
            let removed = processedCommandOrder.removeFirst()
            processedCommandResponses.removeValue(forKey: removed)
        }
    }

    private func startSnapshotUpdates() {
        snapshotTask?.cancel()
        sendSnapshotsIfChanged(force: true)
        snapshotTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.sendSnapshotsIfChanged()
            }
        }
    }

    private func sendSnapshotsIfChanged(force: Bool = false) {
        guard operationMode == .receiver,
            isAuthenticated,
            let currentConnectionID
        else {
            return
        }
        let snapshots = dispatcher.snapshots()
        guard force || snapshots != lastSentSnapshots else { return }
        lastSentSnapshots = snapshots
        send(
            RemoteControlEnvelope(payload: .playerSnapshots(snapshots)),
            to: currentConnectionID
        )
    }

    @discardableResult
    private func send(_ envelope: RemoteControlEnvelope, to connectionID: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= Self.maximumMessageSize else {
                lastErrorMessage = "リモコン通信のデータが大きすぎます"
                return false
            }
            try transport.send(data, to: connectionID)
            return true
        } catch {
            lastErrorMessage = "リモコン通信の送信に失敗しました"
            return false
        }
    }

    private func saveTrustedPeer(_ peerIdentity: RemotePeerIdentity) -> Bool {
        let pairedAt = trustedPeer(id: peerIdentity.id)?.pairedAt ?? Date()
        let peer = RemoteTrustedPeer(
            id: peerIdentity.id,
            displayName: peerIdentity.displayName,
            publicKey: peerIdentity.publicKey,
            pairedAt: pairedAt
        )
        var updatedPeers = trustedPeers.filter { $0.id != peer.id }
        updatedPeers.append(peer)
        updatedPeers.sort { $0.pairedAt < $1.pairedAt }
        do {
            try trustedPeerStore.save(updatedPeers)
            trustedPeers = updatedPeers
            return true
        } catch {
            lastErrorMessage = "登録済み端末をKeychainに保存できませんでした"
            return false
        }
    }

    private func trustedPeer(id: String) -> RemoteTrustedPeer? {
        trustedPeers.first { $0.id == id }
    }

    private func loadTrustedPeersIfNeeded() -> Bool {
        guard !hasLoadedTrustedPeers else { return true }
        do {
            trustedPeers = try trustedPeerStore.load()
            hasLoadedTrustedPeers = true
            return true
        } catch {
            lastErrorMessage = "登録済み端末をKeychainから読み込めませんでした"
            return false
        }
    }

    private func rejectConnection(message: String) {
        lastErrorMessage = message
        connectionStatus = .failed(message)
        clearControllerReconnection()
        transport.disconnect()
        resetConnectionState()
    }

    private func resetConnectionState(preservingRemotePlayers: Bool = false) {
        snapshotTask?.cancel()
        snapshotTask = nil
        currentConnectionID = nil
        remoteIdentity = nil
        pairingChallenge = nil
        pairingRequest = nil
        submittedPIN = nil
        authenticationNonce = nil
        isAuthenticated = false
        authenticatedConnectionID = nil
        awaitingAuthenticationAcceptanceConnectionID = nil
        if !preservingRemotePlayers {
            remotePlayers = []
            selectedPlayerID = nil
        }
        lastSentSnapshots = []
        processedCommandResponses.removeAll()
        processedCommandOrder.removeAll()
    }

    private func reconnect(to peer: RemoteDiscoveredPeer) {
        guard operationMode == .controller,
            currentConnectionID == nil,
            reconnectingControllerPeerID == peer.id
        else {
            return
        }

        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnectingControllerPeerName = peer.displayName
        currentConnectionID = peer.id
        connectionStatus = .reconnecting(peer.displayName)
        transport.connect(to: peer.id)
    }

    private func beginControllerReconnection(connectionID: String) {
        rememberControllerForReconnection(connectionID: connectionID)
        let name = reconnectingControllerPeerName ?? "接続先"
        resetConnectionState(preservingRemotePlayers: true)
        connectionStatus = .reconnecting(name)
        reconnectingDisconnectPendingID = connectionID
        transport.disconnect()
        scheduleControllerReconnection(after: .milliseconds(250))
    }

    private func rememberControllerForReconnection(connectionID: String) {
        let existingName =
            reconnectingControllerPeerID == connectionID
            ? reconnectingControllerPeerName
            : nil
        reconnectingControllerPeerID = connectionID
        reconnectingControllerPeerName =
            remoteIdentity?.displayName
            ?? existingName
            ?? discoveredPeers.first(where: { $0.id == connectionID })?.displayName
            ?? "接続先"
    }

    private func scheduleControllerReconnection(after delay: Duration) {
        guard !isApplicationInBackground,
            operationMode == .controller,
            reconnectingControllerPeerID != nil
        else {
            return
        }

        reconnectionTask?.cancel()
        reconnectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled,
                let self
            else {
                return
            }
            self.reconnectionTask = nil
            guard !self.isApplicationInBackground,
                self.operationMode == .controller,
                self.reconnectingControllerPeerID != nil,
                self.currentConnectionID == nil
            else {
                return
            }
            self.transport.startBrowsing()
        }
    }

    private func clearControllerReconnection() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        reconnectingControllerPeerID = nil
        reconnectingControllerPeerName = nil
        reconnectingDisconnectPendingID = nil
    }

    private func commandErrorMessage(_ error: RemoteCommandError) -> String {
        switch error {
        case .playerNotFound:
            "選択したプレイヤーは終了しています"
        case .unsupported:
            "この操作には対応していません"
        case .invalidValue:
            "操作内容が正しくありません"
        case .unavailable:
            "現在この操作は利用できません"
        case .unauthorized:
            "リモコンが認証されていません"
        }
    }

    private static func localDisplayName() -> String {
        let name = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "kiririn" : name
    }
}
