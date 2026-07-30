import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import kiririn

private nonisolated final class InMemoryRemoteTrustedPeerDataStore:
    RemoteTrustedPeerDataStoring, Sendable
{
    private let values = Mutex<[String: Data]>([:])

    func load(account: String) -> Data? {
        values.withLock { $0[account] }
    }

    func save(_ data: Data, account: String) {
        values.withLock { $0[account] = data }
    }

    func delete(account: String) {
        values.withLock { $0[account] = nil }
    }
}

struct RemoteControlTests {
    @Test func protocolEnvelopeRoundTripsCommands() throws {
        let requestID = UUID()
        let envelope = RemoteControlEnvelope(
            messageID: requestID,
            payload: .command(
                RemotePlayerCommandRequest(
                    playerID: "player",
                    command: .setVolume(125)
                )
            )
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RemoteControlEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(decoded.messageID == requestID)
    }

    @Test func protocolEnvelopeRoundTripsDualMonoSelection() throws {
        let selection = RemoteAudioTrackSelection(
            trackID: "audio-track",
            role: .sub
        )
        let envelope = RemoteControlEnvelope(
            payload: .command(
                RemotePlayerCommandRequest(
                    playerID: "player",
                    command: .selectAudioTrack(selection)
                )
            )
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(RemoteControlEnvelope.self, from: data)

        #expect(decoded == envelope)
    }

    @Test func playerTrackLabelsIncludeDualMonoRoles() {
        let track = PlayerAudioTrack(
            id: "audio-track",
            name: "VLC track",
            channels: 2,
            isDualMono: true
        )
        let labels = PlayerAudioTrackSelection.options(for: track).map {
            PlayerPlaybackOptionCatalog.audioTrackLabel(
                index: 0,
                selection: $0
            )
        }

        #expect(labels == ["トラック1（2ch）主音声", "トラック1（2ch）副音声"])
        #expect(
            PlayerPlaybackOptionCatalog.videoTrackLabel(
                index: 1,
                track: PlayerVideoTrack(id: "video-track", name: "VLC track")
            ) == "トラック2"
        )
    }

    @Test func authenticationSignaturesBindBothPeerIdentities() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nonce = Data("nonce".utf8)
        let data = RemoteControlCryptography.authenticationData(
            nonce: nonce,
            receiverID: "receiver",
            controllerID: "controller"
        )
        let signature = try privateKey.signature(for: data)

        #expect(
            RemoteControlCryptography.verify(
                signature: signature,
                data: data,
                publicKey: privateKey.publicKey.rawRepresentation
            )
        )

        let altered = RemoteControlCryptography.authenticationData(
            nonce: nonce,
            receiverID: "other-receiver",
            controllerID: "controller"
        )
        #expect(
            !RemoteControlCryptography.verify(
                signature: signature,
                data: altered,
                publicKey: privateKey.publicKey.rawRepresentation
            )
        )
    }

    @Test func pairingProofDoesNotExposeOrAcceptAnotherPIN() {
        let data = RemoteControlCryptography.pairingData(
            nonce: Data("nonce".utf8),
            receiverID: "receiver",
            controllerID: "controller"
        )
        let proof = RemoteControlCryptography.pairingProof(pin: "123456", data: data)

        #expect(
            RemoteControlCryptography.verifyPairingProof(
                proof,
                pin: "123456",
                data: data
            )
        )
        #expect(
            !RemoteControlCryptography.verifyPairingProof(
                proof,
                pin: "654321",
                data: data
            )
        )
    }

    @Test func bmlRemoteControlAvailabilityUsesDeclaredKeyGroups() {
        let availability = BMLRemoteControlAvailability(
            isDataButtonEnabled: true,
            enabledGroups: [.basic, .dataButton]
        )

        #expect(availability.isEnabled(.data))
        #expect(availability.isEnabled(.up))
        #expect(availability.isEnabled(.red))
        #expect(!availability.isEnabled(.digit1))
    }

    @Test func unavailableBMLRemoteControlDisablesEveryKey() {
        let availability = BMLRemoteControlAvailability(
            isDataButtonEnabled: false,
            enabledGroups: [.basic]
        )

        #expect(!availability.isEnabled(.data))
        #expect(!availability.isEnabled(.enter))
    }

    @Test func trustedPeerStorePersistsAndRemovesPeers() throws {
        let store = RemoteTrustedPeerStore(store: InMemoryRemoteTrustedPeerDataStore())
        let peer = RemoteTrustedPeer(
            id: "peer",
            displayName: "Mac",
            publicKey: Data([1, 2, 3]),
            pairedAt: Date(timeIntervalSince1970: 1_000)
        )

        try store.save([peer])
        #expect(try store.load() == [peer])

        try store.removeAll()
        #expect(try store.load().isEmpty)
    }
}
