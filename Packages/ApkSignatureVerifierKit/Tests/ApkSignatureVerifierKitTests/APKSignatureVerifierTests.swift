import Foundation
import Testing

@testable import ApkSignatureVerifierKit

struct ApkSignatureVerifierKitTests {

    @Test func treatsUnsignedArchiveAsUnsigned() throws {
        let verifier = ApkSignatureVerifierKit(trustedChainPEMData: nil)
        let tempURL = try tempFileForTest(data: emptyZIPData())
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let authentication = try verifier.verify(packageURL: tempURL)

        #expect(authentication.state == .unsigned)
        #expect(!authentication.isSigned)
        #expect(authentication.scheme == nil)
    }

    @Test func unsignedAuthenticationHasEmptySignersAndWarnings() {
        let authentication = APKAuthentication.unsigned

        #expect(authentication.state == .unsigned)
        #expect(authentication.signers.isEmpty)
        #expect(authentication.warnings.isEmpty)
        #expect(!authentication.isSigned)
        #expect(authentication.scheme == nil)
        #expect(authentication.signerKeyHashes.isEmpty)
    }

    @Test func authenticationReportsSignedWhenSchemeAndSignersExist() {
        let authentication = APKAuthentication(
            scheme: .v2,
            state: .verified,
            signers: [
                APKSignerSummary(
                    distinguishedName: "CN=Test",
                    publicKeySHA256: "abc123"
                )
            ],
            warnings: []
        )

        #expect(authentication.isSigned)
        #expect(authentication.signerKeyHashes == ["abc123"])
    }

    @Test func schemeDisplayNames() {
        #expect(APKSignatureScheme.v2.displayName == "APK Signature Scheme v2")
        #expect(APKSignatureScheme.v3.displayName == "APK Signature Scheme v3")
        #expect(APKSignatureScheme.v31.displayName == "APK Signature Scheme v3.1")
    }

    @Test func authenticationStateLocalizedTitles() {
        #expect(APKAuthenticationState.unsigned.localizedTitle == "未署名")
        #expect(APKAuthenticationState.verified.localizedTitle == "認証済み署名")
        #expect(APKAuthenticationState.selfSigned.localizedTitle == "自己署名")
        #expect(APKAuthenticationState.revoked.localizedTitle == "失効済み署名")
    }

    @Test func signatureErrorDescriptions() {
        #expect(APKSignatureError.unsupportedSignatureScheme.errorDescription != nil)
        #expect(
            APKSignatureError.invalidArchive("test").errorDescription?.contains("test") == true)
        #expect(
            APKSignatureError.verificationFailed("test").errorDescription?.contains("test")
                == true)
    }
}

private func emptyZIPData() -> Data {
    var data = Data()
    data.append(littleEndian(UInt32(0x0605_4b50)))
    data.append(littleEndian(UInt16(0)))
    data.append(littleEndian(UInt16(0)))
    data.append(littleEndian(UInt16(0)))
    data.append(littleEndian(UInt16(0)))
    data.append(littleEndian(UInt32(0)))
    data.append(littleEndian(UInt32(0)))
    data.append(littleEndian(UInt16(0)))
    return data
}

private func littleEndian(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func littleEndian(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func tempFileForTest(data: Data, suffix: String = "kppx") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "test_\(UUID().uuidString).\(suffix)")
    try data.write(to: url)
    return url
}
