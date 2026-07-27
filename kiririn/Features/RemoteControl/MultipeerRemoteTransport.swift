import Foundation
@preconcurrency import MultipeerConnectivity

nonisolated enum RemoteTransportEvent: Sendable {
    case discovered(RemoteDiscoveredPeer)
    case lost(String)
    case connecting(String)
    case connected(String)
    case disconnected(String)
    case received(Data, connectionID: String)
    case failed(String)
}

@MainActor
final class MultipeerRemoteTransport: NSObject {
    static let serviceType = "kiririn-rc"
    nonisolated private static let maximumMessageSize = 256 * 1024

    var onEvent: ((RemoteTransportEvent) -> Void)?

    private let localPeerID: MCPeerID
    private let session: MCSession
    private let advertisedDisplayName: String
    private let localIdentityID: String
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discoveredPeerIDs: [String: MCPeerID] = [:]
    private var connectedPeerIDs: [String: MCPeerID] = [:]
    private var reservedConnectionID: String?

    init(displayName: String, identityID: String) {
        advertisedDisplayName = displayName
        localIdentityID = identityID
        let peerID = MCPeerID(displayName: identityID)
        localPeerID = peerID
        session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        super.init()
        session.delegate = self
    }

    func startAdvertising() {
        stopAdvertising()
        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: [
                "id": localIdentityID,
                "name": advertisedDisplayName,
                "v": String(RemoteControlEnvelope.currentProtocolVersion),
            ],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
    }

    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
    }

    func startBrowsing() {
        stopBrowsing()
        discoveredPeerIDs.removeAll()
        let browser = MCNearbyServiceBrowser(
            peer: localPeerID,
            serviceType: Self.serviceType
        )
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
        discoveredPeerIDs.removeAll()
    }

    func connect(to connectionID: String) {
        guard let peerID = discoveredPeerIDs[connectionID], let browser else {
            onEvent?(.failed("接続先が見つかりません"))
            return
        }
        guard reservedConnectionID == nil || reservedConnectionID == connectionID else {
            onEvent?(.failed("別の接続を処理しています"))
            return
        }
        reservedConnectionID = connectionID
        onEvent?(.connecting(connectionID))
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func send(_ data: Data, to connectionID: String) throws {
        guard let peerID = connectedPeerIDs[connectionID] else {
            throw RemoteTransportError.notConnected
        }
        try session.send(data, toPeers: [peerID], with: .reliable)
    }

    func disconnect() {
        session.disconnect()
        connectedPeerIDs.removeAll()
        reservedConnectionID = nil
    }

    private func handleFoundPeer(
        _ peerID: MCPeerID,
        discoveryInfo: [String: String]?
    ) {
        let connectionID = peerID.displayName
        discoveredPeerIDs[connectionID] = peerID
        let name = discoveryInfo?["name"] ?? peerID.displayName
        onEvent?(
            .discovered(
                RemoteDiscoveredPeer(
                    id: connectionID,
                    displayName: name
                )
            )
        )
    }

    private func handleLostPeer(_ peerID: MCPeerID) {
        let connectionID = peerID.displayName
        discoveredPeerIDs.removeValue(forKey: connectionID)
        onEvent?(.lost(connectionID))
    }

    private func handleInvitation(
        from peerID: MCPeerID,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let connectionID = peerID.displayName
        guard connectedPeerIDs.isEmpty,
            reservedConnectionID == nil || reservedConnectionID == connectionID
        else {
            invitationHandler(false, nil)
            return
        }
        reservedConnectionID = connectionID
        invitationHandler(true, session)
    }

    private func handleState(_ state: MCSessionState, peerID: MCPeerID) {
        let connectionID = peerID.displayName
        switch state {
        case .notConnected:
            connectedPeerIDs.removeValue(forKey: connectionID)
            if reservedConnectionID == connectionID {
                reservedConnectionID = nil
            }
            onEvent?(.disconnected(connectionID))
        case .connecting:
            guard reservedConnectionID == nil || reservedConnectionID == connectionID else {
                session.cancelConnectPeer(peerID)
                return
            }
            reservedConnectionID = connectionID
            onEvent?(.connecting(connectionID))
        case .connected:
            guard reservedConnectionID == nil || reservedConnectionID == connectionID else {
                session.cancelConnectPeer(peerID)
                return
            }
            reservedConnectionID = connectionID
            connectedPeerIDs[connectionID] = peerID
            onEvent?(.connected(connectionID))
        @unknown default:
            onEvent?(.failed("未対応の接続状態です"))
        }
    }
}

extension MultipeerRemoteTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.handleInvitation(from: peerID, invitationHandler: invitationHandler)
        }
    }

    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: any Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onEvent?(.failed(message))
        }
    }
}

extension MultipeerRemoteTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        Task { @MainActor [weak self] in
            self?.handleFoundPeer(peerID, discoveryInfo: info)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor [weak self] in
            self?.handleLostPeer(peerID)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: any Error
    ) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onEvent?(.failed(message))
        }
    }
}

extension MultipeerRemoteTransport: MCSessionDelegate {
    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        Task { @MainActor [weak self] in
            self?.handleState(state, peerID: peerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        guard data.count <= Self.maximumMessageSize else { return }
        let connectionID = peerID.displayName
        Task { @MainActor [weak self] in
            self?.onEvent?(.received(data, connectionID: connectionID))
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}

nonisolated enum RemoteTransportError: Error {
    case notConnected
}
