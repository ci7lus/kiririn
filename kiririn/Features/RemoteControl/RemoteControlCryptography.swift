import CryptoKit
import Foundation
import Security

nonisolated enum RemoteControlCryptography {
    private static let authenticationContext = Data("kiririn-remote-auth-v1".utf8)
    private static let pairingContext = Data("kiririn-remote-pair-v1".utf8)

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return Data(UUID().uuidString.utf8)
        }
        return Data(bytes)
    }

    static func authenticationData(
        nonce: Data,
        receiverID: String,
        controllerID: String
    ) -> Data {
        joined(
            authenticationContext,
            nonce,
            Data(receiverID.utf8),
            Data(controllerID.utf8)
        )
    }

    static func pairingData(
        nonce: Data,
        receiverID: String,
        controllerID: String
    ) -> Data {
        joined(
            pairingContext,
            nonce,
            Data(receiverID.utf8),
            Data(controllerID.utf8)
        )
    }

    static func pairingProof(pin: String, data: Data) -> Data {
        let key = SymmetricKey(data: Data(pin.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func verifyPairingProof(_ proof: Data, pin: String, data: Data) -> Bool {
        let key = SymmetricKey(data: Data(pin.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: data, using: key)
    }

    static func verify(
        signature: Data,
        data: Data,
        publicKey: Data
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    private static func joined(_ components: Data...) -> Data {
        var result = Data()
        for component in components {
            var length = UInt32(component.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(component)
        }
        return result
    }
}
