import CryptoKit
import Foundation

nonisolated struct RemoteLocalIdentity: Sendable {
    let id: String
    let displayName: String
    let privateKey: Curve25519.Signing.PrivateKey

    var peerIdentity: RemotePeerIdentity {
        RemotePeerIdentity(
            id: id,
            displayName: displayName,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    }

    func signature(for data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

private nonisolated struct StoredRemoteIdentity: Codable {
    let id: String
    let privateKey: Data
}

nonisolated protocol RemoteIdentityDataStoring: Sendable {
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
}

extension KeychainDataStore: RemoteIdentityDataStoring {}

nonisolated struct RemoteIdentityStore: Sendable {
    private let account = "local-device"
    private let store: any RemoteIdentityDataStoring

    init() {
        store = KeychainDataStore(
            service: "jp.pronama.kiririn.remote.identity",
            label: "kiririn Remote Control Identity",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    init(store: any RemoteIdentityDataStoring) {
        self.store = store
    }

    @concurrent
    func loadOrCreate(displayName: String) async throws -> RemoteLocalIdentity {
        try Task.checkCancellation()
        if let stored = try load() {
            try Task.checkCancellation()
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: stored.privateKey
            )
            return RemoteLocalIdentity(
                id: stored.id,
                displayName: displayName,
                privateKey: privateKey
            )
        }

        try Task.checkCancellation()
        let privateKey = Curve25519.Signing.PrivateKey()
        let stored = StoredRemoteIdentity(
            id: UUID().uuidString,
            privateKey: privateKey.rawRepresentation
        )
        try save(stored)
        try Task.checkCancellation()
        return RemoteLocalIdentity(
            id: stored.id,
            displayName: displayName,
            privateKey: privateKey
        )
    }

    private func load() throws -> StoredRemoteIdentity? {
        guard let data = try store.load(account: account) else { return nil }
        return try JSONDecoder().decode(StoredRemoteIdentity.self, from: data)
    }

    private func save(_ identity: StoredRemoteIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        try store.save(data, account: account)
    }
}
