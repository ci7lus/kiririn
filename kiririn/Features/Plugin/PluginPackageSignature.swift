import CryptoKit
import Foundation
import Security
import SwiftASN1

enum PluginPackageSignatureRequirement {
    case optional
    case required
}

enum PluginPackageSignatureScheme: String, Codable, Sendable {
    case v2
    case v3
    case v31

    var displayName: String {
        switch self {
        case .v2:
            return "APK Signature Scheme v2"
        case .v3:
            return "APK Signature Scheme v3"
        case .v31:
            return "APK Signature Scheme v3.1"
        }
    }
}

enum PluginPackageAuthenticationState: String, Codable, Sendable {
    case unsigned
    case verified
    case selfSigned
    case revoked

    var localizedTitle: String {
        switch self {
        case .unsigned:
            return "未署名"
        case .verified:
            return "認証済み署名"
        case .selfSigned:
            return "自己署名"
        case .revoked:
            return "失効済み署名"
        }
    }
}

struct PluginPackageSignerSummary: Codable, Equatable, Sendable {
    let distinguishedName: String
    let publicKeySHA256: String
}

struct PluginPackageAuthentication: Codable, Equatable, Sendable {
    let scheme: PluginPackageSignatureScheme?
    let state: PluginPackageAuthenticationState
    let signers: [PluginPackageSignerSummary]
    let warnings: [String]

    static let unsigned = PluginPackageAuthentication(
        scheme: nil,
        state: .unsigned,
        signers: [],
        warnings: []
    )

    var isSigned: Bool {
        scheme != nil && !signers.isEmpty
    }

    var signerKeyHashes: [String] {
        signers.map(\.publicKeySHA256)
    }
}

enum PluginPackageSignatureError: LocalizedError {
    case unsupportedSignatureScheme
    case invalidArchive(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSignatureScheme:
            return "APK Signature Scheme v2/v3/v3.1 の署名が見つかりません。"
        case .invalidArchive(let message):
            return "署名付きプラグインパッケージの形式が不正です: \(message)"
        case .verificationFailed(let message):
            return "プラグインパッケージの署名検証に失敗しました: \(message)"
        }
    }
}

final class PluginPackageSignatureVerifier {
    static let shared = PluginPackageSignatureVerifier()

    private let trustedStore: TrustedCertificateStore
    private let networkLoader: CRLNetworkLoader
    private let now: () -> Date
    private let crlCacheLock = NSLock()
    private var crlCache: [URL: CachedCRL] = [:]

    init(
        trustedChainPEMData: Data? = PluginPackageSignatureVerifier.loadBundledTrustChain(),
        session: URLSession = .kiririnShared,
        now: @escaping () -> Date = Date.init
    ) {
        self.trustedStore = TrustedCertificateStore(pemData: trustedChainPEMData)
        self.networkLoader = CRLNetworkLoader(session: session)
        self.now = now
    }

    func verify(packageData: Data) throws -> PluginPackageAuthentication {
        guard let container = try APKSignatureContainer.parse(from: packageData) else {
            return .unsigned
        }

        let signers = try parseSigners(from: container)
        guard !signers.isEmpty else {
            throw PluginPackageSignatureError.verificationFailed("署名者が含まれていません")
        }

        var digestCache: [ContentDigestAlgorithm: Data] = [:]
        var signerSummaries: [PluginPackageSignerSummary] = []
        var warnings: [String] = []
        var allTrusted = true
        var revoked = false

        for signer in signers {
            let signerResult = try verify(
                signer: signer,
                in: container,
                digestCache: &digestCache
            )
            signerSummaries.append(signerResult.summary)
            warnings.append(contentsOf: signerResult.warnings)
            allTrusted = allTrusted && signerResult.isTrusted
            revoked = revoked || signerResult.isRevoked
        }

        let state: PluginPackageAuthenticationState
        if revoked {
            state = .revoked
        } else if allTrusted {
            state = .verified
        } else {
            state = .selfSigned
        }

        return PluginPackageAuthentication(
            scheme: container.scheme,
            state: state,
            signers: signerSummaries,
            warnings: uniqued(warnings)
        )
    }

    private func verify(
        signer: ParsedAPKSigner,
        in container: APKSignatureContainer,
        digestCache: inout [ContentDigestAlgorithm: Data]
    ) throws -> SignerVerificationResult {
        guard let leafCertificate = signer.certificates.first else {
            throw PluginPackageSignatureError.verificationFailed("署名者証明書がありません")
        }

        if leafCertificate.subjectPublicKeyInfoDER != signer.publicKeyDER {
            throw PluginPackageSignatureError.verificationFailed(
                "署名者の公開鍵と証明書の SubjectPublicKeyInfo が一致しません"
            )
        }

        guard let signatureRecord = strongestSupportedSignature(in: signer.signatures) else {
            throw PluginPackageSignatureError.verificationFailed(
                "サポートされている署名アルゴリズムがありません"
            )
        }
        guard
            let digestRecord = signer.digests.first(where: {
                $0.algorithmID == signatureRecord.algorithmID
            })
        else {
            throw PluginPackageSignatureError.verificationFailed(
                "署名に対応するダイジェストが見つかりません"
            )
        }

        guard let publicKey = SecCertificateCopyKey(leafCertificate.secCertificate) else {
            throw PluginPackageSignatureError.verificationFailed("署名者証明書の公開鍵を取得できません")
        }
        guard
            SecKeyIsAlgorithmSupported(
                publicKey, .verify, signatureRecord.algorithm.secKeyAlgorithm)
        else {
            throw PluginPackageSignatureError.verificationFailed(
                "署名アルゴリズム \(signatureRecord.algorithm.displayName) を検証できません"
            )
        }

        var error: Unmanaged<CFError>?
        let signedDataValid = SecKeyVerifySignature(
            publicKey,
            signatureRecord.algorithm.secKeyAlgorithm,
            signer.signedData as CFData,
            signatureRecord.signature as CFData,
            &error
        )
        guard signedDataValid else {
            let message = error?.takeRetainedValue().localizedDescription ?? "signed data の署名が不正です"
            throw PluginPackageSignatureError.verificationFailed(message)
        }

        let contentDigest: Data
        if let cached = digestCache[signatureRecord.algorithm.contentDigestAlgorithm] {
            contentDigest = cached
        } else {
            let computed = try computeContentDigest(
                algorithm: signatureRecord.algorithm.contentDigestAlgorithm,
                packageData: container.packageData,
                signingBlockOffset: container.signingBlockOffset,
                centralDirectoryOffset: container.centralDirectoryOffset,
                eocdOffset: container.eocdOffset
            )
            digestCache[signatureRecord.algorithm.contentDigestAlgorithm] = computed
            contentDigest = computed
        }

        guard contentDigest == digestRecord.digest else {
            throw PluginPackageSignatureError.verificationFailed(
                "パッケージ本体のダイジェストが一致しません"
            )
        }

        let trustResult = evaluateTrust(for: signer.certificates)
        return SignerVerificationResult(
            summary: PluginPackageSignerSummary(
                distinguishedName: leafCertificate.subjectDistinguishedName,
                publicKeySHA256: sha256Hex(of: signer.publicKeyDER)
            ),
            isTrusted: trustResult.isTrusted,
            isRevoked: trustResult.isRevoked,
            warnings: trustResult.warnings
        )
    }

    private func evaluateTrust(for certificates: [ParsedCertificate]) -> TrustEvaluationResult {
        let isTrusted = evaluateCertificateTrust(certificates: certificates)
        guard isTrusted else {
            return TrustEvaluationResult(
                isTrusted: false,
                isRevoked: false,
                warnings: ["証明書チェーンを信頼できないため失効確認を実施しませんでした"]
            )
        }

        let revocationResult = evaluateRevocation(for: certificates)
        return TrustEvaluationResult(
            isTrusted: isTrusted && !revocationResult.isRevoked,
            isRevoked: revocationResult.isRevoked,
            warnings: revocationResult.warnings
        )
    }

    private func evaluateCertificateTrust(certificates: [ParsedCertificate]) -> Bool {
        guard !trustedStore.certificates.isEmpty else {
            return false
        }

        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        let allCertificates = certificates.map(\.secCertificate) as CFArray
        guard SecTrustCreateWithCertificates(allCertificates, policy, &trust) == errSecSuccess,
            let trust
        else {
            return false
        }

        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetAnchorCertificates(
            trust, trustedStore.certificates.map(\.secCertificate) as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        return SecTrustEvaluateWithError(trust, nil)
    }

    private func evaluateRevocation(for certificates: [ParsedCertificate]) -> RevocationCheckResult
    {
        var warnings: [String] = []
        let certificatePool = mergeCertificatePools(certificates, trustedStore.certificates)
        for certificate in certificates {
            if certificate.subjectNameDER == certificate.issuerNameDER {
                continue
            }
            let result = evaluateRevocation(for: certificate, certificatePool: certificatePool)
            warnings.append(contentsOf: result.warnings)
            if result.isRevoked {
                return RevocationCheckResult(isRevoked: true, warnings: warnings)
            }
        }

        return RevocationCheckResult(isRevoked: false, warnings: uniqued(warnings))
    }

    private func evaluateRevocation(
        for certificate: ParsedCertificate,
        certificatePool: [ParsedCertificate]
    ) -> RevocationCheckResult {
        guard !certificate.crlDistributionPointURLs.isEmpty else {
            return RevocationCheckResult(isRevoked: false, warnings: [])
        }

        var warnings: [String] = []
        var hadVerifiedCRL = false

        for url in certificate.crlDistributionPointURLs {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                warnings.append("CRL の取得に未対応の URL を検出しました: \(url.absoluteString)")
                continue
            }

            do {
                let crl = try loadCRL(from: url)
                guard
                    let issuer = certificatePool.first(where: {
                        $0.subjectNameDER == crl.issuerNameDER
                    })
                else {
                    warnings.append("CRL 発行者証明書が見つかりません: \(url.absoluteString)")
                    continue
                }
                guard try verify(crl: crl, with: issuer) else {
                    warnings.append("CRL 署名を検証できませんでした: \(url.absoluteString)")
                    continue
                }
                if let nextUpdate = crl.nextUpdate, nextUpdate < now() {
                    warnings.append("CRL の有効期限が切れています: \(url.absoluteString)")
                    continue
                }

                hadVerifiedCRL = true
                if crl.revokedSerialNumbers.contains(certificate.serialNumberHex) {
                    warnings.append("証明書が CRL により失効しています: \(certificate.subjectDistinguishedName)")
                    return RevocationCheckResult(isRevoked: true, warnings: warnings)
                }
            } catch {
                warnings.append("CRL を確認できませんでした: \(url.absoluteString)")
            }
        }

        if !hadVerifiedCRL {
            warnings.append(
                "CRL を検証できなかったため失効状態を確認できませんでした: \(certificate.subjectDistinguishedName)")
        }
        return RevocationCheckResult(isRevoked: false, warnings: uniqued(warnings))
    }

    private func loadCRL(from url: URL) throws -> ParsedCRL {
        if let cached = cachedCRL(for: url), cached.isValid(at: now()) {
            return cached.crl
        }

        let data = try networkLoader.data(from: url)
        let crl = try ParsedCRL(der: data)
        storeCachedCRL(crl, for: url)
        return crl
    }

    private func verify(crl: ParsedCRL, with issuer: ParsedCertificate) throws -> Bool {
        if crl.signatureAlgorithm.isEd25519 {
            return try verifyEd25519Signature(
                signature: crl.signature,
                message: crl.tbsDER,
                subjectPublicKeyInfoDER: issuer.subjectPublicKeyInfoDER
            )
        }

        guard let publicKey = SecCertificateCopyKey(issuer.secCertificate) else {
            throw PluginPackageSignatureError.verificationFailed("CRL 発行者の公開鍵を取得できません")
        }
        guard let algorithm = crl.signatureAlgorithm.secKeyAlgorithm else {
            throw PluginPackageSignatureError.verificationFailed("CRL の署名アルゴリズムに対応していません")
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else {
            throw PluginPackageSignatureError.verificationFailed("CRL の署名アルゴリズムを検証できません")
        }

        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            publicKey,
            algorithm,
            crl.tbsDER as CFData,
            crl.signature as CFData,
            &error
        )
    }

    private func parseSigners(from container: APKSignatureContainer) throws -> [ParsedAPKSigner] {
        var reader = ByteReader(data: container.schemeBlockData)
        var signersReader = try reader.readLengthPrefixedReader()
        var signers: [ParsedAPKSigner] = []

        while !signersReader.isAtEnd {
            let signerReader = try signersReader.readLengthPrefixedReader()
            signers.append(try parseSigner(from: signerReader, scheme: container.scheme))
        }

        guard reader.isAtEnd else {
            throw PluginPackageSignatureError.invalidArchive("署名ブロック末尾に余分なデータがあります")
        }

        return signers
    }

    private func parseSigner(from reader: ByteReader, scheme: PluginPackageSignatureScheme) throws
        -> ParsedAPKSigner
    {
        var workingReader = reader
        let signedData = try workingReader.readLengthPrefixedData()

        let minSDK: UInt32?
        let maxSDK: UInt32?
        switch scheme {
        case .v2:
            minSDK = nil
            maxSDK = nil
        case .v3, .v31:
            minSDK = try workingReader.readUInt32()
            maxSDK = try workingReader.readUInt32()
        }

        let signaturesReader = try workingReader.readLengthPrefixedReader()
        let publicKeyDER = try workingReader.readLengthPrefixedData()
        guard workingReader.isAtEnd else {
            throw PluginPackageSignatureError.invalidArchive("署名者ブロック末尾に余分なデータがあります")
        }

        var signedDataReader = ByteReader(data: signedData)
        let digests = try parseDigestRecords(from: signedDataReader.readLengthPrefixedReader())
        let certificates = try parseCertificates(from: signedDataReader.readLengthPrefixedReader())

        switch scheme {
        case .v2:
            _ = try parseAttributes(from: signedDataReader.readLengthPrefixedReader())
        case .v3, .v31:
            let signedMinSDK = try signedDataReader.readUInt32()
            let signedMaxSDK = try signedDataReader.readUInt32()
            guard signedMinSDK == minSDK, signedMaxSDK == maxSDK else {
                throw PluginPackageSignatureError.verificationFailed(
                    "v3 署名者の SDK 範囲が一致しません"
                )
            }
            _ = try parseAttributes(from: signedDataReader.readLengthPrefixedReader())
        }

        guard signedDataReader.isAtEnd else {
            throw PluginPackageSignatureError.invalidArchive("signed data の形式が不正です")
        }

        return ParsedAPKSigner(
            signedData: signedData,
            digests: digests,
            signatures: try parseSignatureRecords(from: signaturesReader),
            certificates: certificates,
            publicKeyDER: publicKeyDER
        )
    }

    private func parseDigestRecords(from reader: ByteReader) throws -> [DigestRecord] {
        var workingReader = reader
        var records: [DigestRecord] = []
        while !workingReader.isAtEnd {
            var recordReader = try workingReader.readLengthPrefixedReader()
            let algorithmID = try recordReader.readUInt32()
            let digest = try recordReader.readLengthPrefixedData()
            guard let algorithm = APKSupportedSignatureAlgorithm(rawValue: algorithmID) else {
                records.append(DigestRecord(algorithmID: algorithmID, digest: digest))
                continue
            }
            records.append(DigestRecord(algorithmID: algorithm.rawValue, digest: digest))
        }
        return records
    }

    private func parseSignatureRecords(from reader: ByteReader) throws -> [SignatureRecord] {
        var workingReader = reader
        var records: [SignatureRecord] = []
        while !workingReader.isAtEnd {
            var recordReader = try workingReader.readLengthPrefixedReader()
            let algorithmID = try recordReader.readUInt32()
            let signature = try recordReader.readLengthPrefixedData()
            guard let algorithm = APKSupportedSignatureAlgorithm(rawValue: algorithmID) else {
                continue
            }
            records.append(
                SignatureRecord(
                    algorithmID: algorithm.rawValue,
                    algorithm: algorithm,
                    signature: signature
                )
            )
        }
        return records
    }

    private func parseCertificates(from reader: ByteReader) throws -> [ParsedCertificate] {
        var workingReader = reader
        var certificates: [ParsedCertificate] = []
        while !workingReader.isAtEnd {
            let certificateDER = try workingReader.readLengthPrefixedData()
            certificates.append(try ParsedCertificate(der: certificateDER))
        }
        return certificates
    }

    private func parseAttributes(from reader: ByteReader) throws -> [UInt32: Data] {
        var workingReader = reader
        var attributes: [UInt32: Data] = [:]
        while !workingReader.isAtEnd {
            var attributeReader = try workingReader.readLengthPrefixedReader()
            let identifier = try attributeReader.readUInt32()
            attributes[identifier] = try attributeReader.readToEnd()
        }
        return attributes
    }

    private func strongestSupportedSignature(in records: [SignatureRecord]) -> SignatureRecord? {
        records.max { lhs, rhs in
            lhs.algorithm.strength < rhs.algorithm.strength
        }
    }

    private func cachedCRL(for url: URL) -> CachedCRL? {
        crlCacheLock.lock()
        defer { crlCacheLock.unlock() }
        return crlCache[url]
    }

    private func storeCachedCRL(_ crl: ParsedCRL, for url: URL) {
        crlCacheLock.lock()
        defer { crlCacheLock.unlock() }
        crlCache[url] = CachedCRL(crl: crl)
    }

    private static func loadBundledTrustChain() -> Data? {
        if let url = Bundle.main.url(forResource: "trusted_chain", withExtension: "pem"),
            let data = try? Data(contentsOf: url)
        {
            return data
        }

        if let url = Bundle(for: BundleToken.self).url(
            forResource: "trusted_chain", withExtension: "pem"),
            let data = try? Data(contentsOf: url)
        {
            return data
        }

        return nil
    }
}

private final class BundleToken {}

private struct SignerVerificationResult {
    let summary: PluginPackageSignerSummary
    let isTrusted: Bool
    let isRevoked: Bool
    let warnings: [String]
}

private struct TrustEvaluationResult {
    let isTrusted: Bool
    let isRevoked: Bool
    let warnings: [String]
}

private struct RevocationCheckResult {
    let isRevoked: Bool
    let warnings: [String]
}

private struct CachedCRL {
    let crl: ParsedCRL
    let fetchedAt: Date

    init(crl: ParsedCRL, fetchedAt: Date = Date()) {
        self.crl = crl
        self.fetchedAt = fetchedAt
    }

    func isValid(at date: Date) -> Bool {
        if let nextUpdate = crl.nextUpdate {
            return nextUpdate >= date
        }
        return date.timeIntervalSince(fetchedAt) < 60 * 60
    }
}

private struct CRLNetworkLoader {
    let session: URLSession
    let timeout: TimeInterval

    init(session: URLSession, timeout: TimeInterval = 5) {
        self.session = session
        self.timeout = timeout
    }

    func data(from url: URL) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Data, Error>?
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let task = session.dataTask(with: request) { data, response, error in
            lock.lock()
            defer {
                lock.unlock()
                semaphore.signal()
            }

            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                200..<300 ~= httpResponse.statusCode,
                let data
            else {
                result = .failure(PluginPackageSignatureError.verificationFailed("CRL の取得に失敗しました"))
                return
            }

            result = .success(data)
        }

        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw PluginPackageSignatureError.verificationFailed("CRL の取得がタイムアウトしました")
        }

        return try lock.withLock {
            guard let result else {
                throw PluginPackageSignatureError.verificationFailed("CRL の取得結果が不明です")
            }
            return try result.get()
        }
    }
}

private struct TrustedCertificateStore {
    let certificates: [ParsedCertificate]

    init(pemData: Data?) {
        guard let pemString = String(data: pemData ?? Data(), encoding: .utf8),
            let documents = try? PEMDocument.parseMultiple(pemString: pemString)
        else {
            self.certificates = []
            return
        }

        self.certificates = documents.compactMap {
            try? ParsedCertificate(der: Data($0.derBytes))
        }
    }
}

private struct APKSignatureContainer {
    static let v2BlockID: UInt32 = 0x7109_871a
    static let v3BlockID: UInt32 = 0xf053_68c0
    static let v31BlockID: UInt32 = 0x1b93_ad61
    static let magic = Data("APK Sig Block 42".utf8)

    let packageData: Data
    let scheme: PluginPackageSignatureScheme
    let schemeBlockData: Data
    let signingBlockOffset: Int
    let centralDirectoryOffset: Int
    let eocdOffset: Int

    static func parse(from data: Data) throws -> APKSignatureContainer? {
        let eocdOffset = try ZIPParser.findEndOfCentralDirectory(in: data)
        let eocd = data.subdata(in: eocdOffset..<data.count)
        let centralDirectoryOffset = Int(try ZIPParser.readUInt32LE(in: eocd, at: 16))
        let centralDirectorySize = Int(try ZIPParser.readUInt32LE(in: eocd, at: 12))
        guard centralDirectoryOffset + centralDirectorySize == eocdOffset else {
            throw PluginPackageSignatureError.invalidArchive(
                "ZIP Central Directory の直後に EOCD がありません"
            )
        }
        guard centralDirectoryOffset >= 24 else {
            return nil
        }

        let footerOffset = centralDirectoryOffset - 24
        let magicRange = (footerOffset + 8)..<centralDirectoryOffset
        guard magicRange.lowerBound >= 0, data.subdata(in: magicRange) == magic else {
            return nil
        }

        let blockSize = Int(try ZIPParser.readUInt64LE(in: data, at: footerOffset))
        let blockOffset = centralDirectoryOffset - (blockSize + 8)
        guard blockOffset >= 0 else {
            throw PluginPackageSignatureError.invalidArchive("APK Signing Block の位置が不正です")
        }
        let headerSize = Int(try ZIPParser.readUInt64LE(in: data, at: blockOffset))
        guard headerSize == blockSize else {
            throw PluginPackageSignatureError.invalidArchive("APK Signing Block のサイズが一致しません")
        }

        var pairsReader = ByteReader(data: data.subdata(in: (blockOffset + 8)..<footerOffset))
        var pairs: [UInt32: Data] = [:]
        while !pairsReader.isAtEnd {
            let pairLength = Int(try pairsReader.readUInt64())
            guard pairLength >= 4 else {
                throw PluginPackageSignatureError.invalidArchive("APK Signing Block のペア長が不正です")
            }
            var pairReader = try pairsReader.readReader(count: pairLength)
            let identifier = try pairReader.readUInt32()
            pairs[identifier] = try pairReader.readToEnd()
        }

        if let blockData = pairs[v31BlockID] {
            return APKSignatureContainer(
                packageData: data,
                scheme: .v31,
                schemeBlockData: blockData,
                signingBlockOffset: blockOffset,
                centralDirectoryOffset: centralDirectoryOffset,
                eocdOffset: eocdOffset
            )
        }
        if let blockData = pairs[v3BlockID] {
            return APKSignatureContainer(
                packageData: data,
                scheme: .v3,
                schemeBlockData: blockData,
                signingBlockOffset: blockOffset,
                centralDirectoryOffset: centralDirectoryOffset,
                eocdOffset: eocdOffset
            )
        }
        if let blockData = pairs[v2BlockID] {
            return APKSignatureContainer(
                packageData: data,
                scheme: .v2,
                schemeBlockData: blockData,
                signingBlockOffset: blockOffset,
                centralDirectoryOffset: centralDirectoryOffset,
                eocdOffset: eocdOffset
            )
        }

        if !pairs.isEmpty {
            throw PluginPackageSignatureError.unsupportedSignatureScheme
        }
        return nil
    }
}

private struct ZIPParser {
    static let eocdSignature: UInt32 = 0x0605_4b50
    static let maxCommentLength = 65_535

    static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw PluginPackageSignatureError.invalidArchive("ZIP EOCD が見つかりません")
        }

        let lowerBound = max(0, data.count - (22 + maxCommentLength))
        let upperBound = data.count - 22
        for offset in stride(from: upperBound, through: lowerBound, by: -1) {
            if try readUInt32LE(in: data, at: offset) != eocdSignature {
                continue
            }

            let commentLength = Int(try readUInt16LE(in: data, at: offset + 20))
            if offset + 22 + commentLength == data.count {
                return offset
            }
        }

        throw PluginPackageSignatureError.invalidArchive("ZIP EOCD が見つかりません")
    }

    static func readUInt16LE(in data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw PluginPackageSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            UInt16(littleEndian: $0.load(as: UInt16.self))
        }
    }

    static func readUInt32LE(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw PluginPackageSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }

    static func readUInt64LE(in data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw PluginPackageSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data.subdata(in: offset..<(offset + 8)).withUnsafeBytes {
            UInt64(littleEndian: $0.load(as: UInt64.self))
        }
    }
}

private struct ByteReader {
    let data: Data
    private(set) var offset: Int = 0

    var isAtEnd: Bool {
        offset >= data.count
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try ZIPParser.readUInt32LE(in: data, at: offset)
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let value = try ZIPParser.readUInt64LE(in: data, at: offset)
        offset += 8
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw PluginPackageSignatureError.invalidArchive("長さ付きデータの範囲が不正です")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readReader(count: Int) throws -> ByteReader {
        ByteReader(data: try readData(count: count))
    }

    mutating func readLengthPrefixedData() throws -> Data {
        let length = Int(try readUInt32())
        return try readData(count: length)
    }

    mutating func readLengthPrefixedReader() throws -> ByteReader {
        ByteReader(data: try readLengthPrefixedData())
    }

    mutating func readToEnd() throws -> Data {
        try readData(count: data.count - offset)
    }
}

enum ContentDigestAlgorithm {
    case sha256
    case sha512

    var chunkDigestLength: Int {
        switch self {
        case .sha256:
            return 32
        case .sha512:
            return 64
        }
    }

    func hash(_ data: Data) -> Data {
        switch self {
        case .sha256:
            return Data(SHA256.hash(data: data))
        case .sha512:
            return Data(SHA512.hash(data: data))
        }
    }
}

private enum APKSupportedSignatureAlgorithm: UInt32 {
    case rsaPSSSHA256 = 0x0101
    case rsaPSSSHA512 = 0x0102
    case rsaPKCS1SHA256 = 0x0103
    case rsaPKCS1SHA512 = 0x0104
    case ecdsaSHA256 = 0x0201
    case ecdsaSHA512 = 0x0202

    var contentDigestAlgorithm: ContentDigestAlgorithm {
        switch self {
        case .rsaPSSSHA256, .rsaPKCS1SHA256, .ecdsaSHA256:
            return .sha256
        case .rsaPSSSHA512, .rsaPKCS1SHA512, .ecdsaSHA512:
            return .sha512
        }
    }

    var secKeyAlgorithm: SecKeyAlgorithm {
        switch self {
        case .rsaPSSSHA256:
            return .rsaSignatureMessagePSSSHA256
        case .rsaPSSSHA512:
            return .rsaSignatureMessagePSSSHA512
        case .rsaPKCS1SHA256:
            return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaPKCS1SHA512:
            return .rsaSignatureMessagePKCS1v15SHA512
        case .ecdsaSHA256:
            return .ecdsaSignatureMessageX962SHA256
        case .ecdsaSHA512:
            return .ecdsaSignatureMessageX962SHA512
        }
    }

    var strength: Int {
        switch self {
        case .rsaPSSSHA512:
            return 6
        case .ecdsaSHA512:
            return 5
        case .rsaPKCS1SHA512:
            return 4
        case .rsaPSSSHA256:
            return 3
        case .ecdsaSHA256:
            return 2
        case .rsaPKCS1SHA256:
            return 1
        }
    }

    var displayName: String {
        switch self {
        case .rsaPSSSHA256:
            return "RSASSA-PSS SHA-256"
        case .rsaPSSSHA512:
            return "RSASSA-PSS SHA-512"
        case .rsaPKCS1SHA256:
            return "RSASSA-PKCS1-v1_5 SHA-256"
        case .rsaPKCS1SHA512:
            return "RSASSA-PKCS1-v1_5 SHA-512"
        case .ecdsaSHA256:
            return "ECDSA SHA-256"
        case .ecdsaSHA512:
            return "ECDSA SHA-512"
        }
    }
}

private struct DigestRecord {
    let algorithmID: UInt32
    let digest: Data
}

private struct SignatureRecord {
    let algorithmID: UInt32
    let algorithm: APKSupportedSignatureAlgorithm
    let signature: Data
}

private struct ParsedAPKSigner {
    let signedData: Data
    let digests: [DigestRecord]
    let signatures: [SignatureRecord]
    let certificates: [ParsedCertificate]
    let publicKeyDER: Data
}
