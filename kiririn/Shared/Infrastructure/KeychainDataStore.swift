import Foundation
import Security

nonisolated struct KeychainDataStore: Sendable {
    enum Accessibility: Sendable {
        case afterFirstUnlock
        case afterFirstUnlockThisDeviceOnly

        fileprivate var value: CFString {
            switch self {
            case .afterFirstUnlock:
                kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    let service: String
    let label: String
    let accessibility: Accessibility

    func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainDataStoreError.operationFailed(status)
        }
        return data
    }

    func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: label,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainDataStoreError.operationFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrLabel] = label
        addQuery[kSecAttrAccessible] = accessibility.value
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainDataStoreError.operationFailed(addStatus)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainDataStoreError.operationFailed(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

nonisolated enum KeychainDataStoreError: Error {
    case operationFailed(OSStatus)
}
