import Foundation

nonisolated protocol RemoteTrustedPeerDataStoring: Sendable {
    func load(account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

extension KeychainDataStore: RemoteTrustedPeerDataStoring {}

nonisolated struct RemoteTrustedPeerStore {
    private let account = "trusted-peers"
    private let store: any RemoteTrustedPeerDataStoring

    init(service: String = "jp.pronama.kiririn.remote.trust") {
        store = KeychainDataStore(
            service: service,
            label: "kiririn Remote Control Trusted Peers",
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    init(store: any RemoteTrustedPeerDataStoring) {
        self.store = store
    }

    func load() throws -> [RemoteTrustedPeer] {
        guard let data = try store.load(account: account) else { return [] }
        let peers = try JSONDecoder().decode([RemoteTrustedPeer].self, from: data)
        return peers.sorted { $0.pairedAt < $1.pairedAt }
    }

    func save(_ peers: [RemoteTrustedPeer]) throws {
        let data = try JSONEncoder().encode(peers)
        try store.save(data, account: account)
    }

    func removeAll() throws {
        try store.delete(account: account)
    }
}
