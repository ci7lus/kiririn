import Foundation
import Security

struct KeychainCredentialStore {
    private let service = "jp.pronama.kiririn.backend.auth"
    private let label = "kiririn Backend Credential"

    func save(_ auth: BackendAuth, forBackendId backendId: String) {
        guard case .none = auth else {
            guard let data = try? JSONEncoder().encode(auth) else { return }

            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: backendId,
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
        delete(forBackendId: backendId)
    }

    func load(forBackendId backendId: String) -> BackendAuth? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: backendId,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BackendAuth.self, from: data)
    }

    func delete(forBackendId backendId: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: backendId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
