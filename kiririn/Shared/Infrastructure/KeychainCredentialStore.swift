import Foundation
import Security

struct KeychainCredentialStore {
    private let service = "jp.pronama.kiririn.server.auth"
    private let label = "kiririn Server Credential"

    func save(_ auth: ServerAuth, forServerId serverId: String) {
        guard case .none = auth else {
            guard let data = try? JSONEncoder().encode(auth) else { return }

            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: serverId,
            ]
            let attributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrLabel: label,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

            if updateStatus == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData] = data
                addQuery[kSecAttrLabel] = label
                addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(addQuery as CFDictionary, nil)
            }
            return
        }
        delete(forServerId: serverId)
    }

    func load(forServerId serverId: String) -> ServerAuth? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverId,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ServerAuth.self, from: data)
    }

    func delete(forServerId serverId: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: serverId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
