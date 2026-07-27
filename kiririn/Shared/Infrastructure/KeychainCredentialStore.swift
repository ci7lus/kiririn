import Foundation

struct KeychainCredentialStore {
    private let store = KeychainDataStore(
        service: "jp.pronama.kiririn.server.auth",
        label: "kiririn Server Credential",
        accessibility: .afterFirstUnlock
    )

    func save(_ auth: ServerAuth, forServerId serverId: String) {
        guard case .none = auth else {
            guard let data = try? JSONEncoder().encode(auth) else { return }

            try? store.save(data, account: serverId)
            return
        }
        delete(forServerId: serverId)
    }

    func load(forServerId serverId: String) -> ServerAuth? {
        guard let data = try? store.load(account: serverId) else { return nil }
        return try? JSONDecoder().decode(ServerAuth.self, from: data)
    }

    func delete(forServerId serverId: String) {
        try? store.delete(account: serverId)
    }
}
