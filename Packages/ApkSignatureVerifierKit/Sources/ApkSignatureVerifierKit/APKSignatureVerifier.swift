import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

public enum APKSignatureRequirement: Sendable {
    case optional
    case required
}

public enum APKSignatureScheme: String, Codable, Sendable {
    case v2
    case v3
    case v31

    public var displayName: String {
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

public enum APKAuthenticationState: String, Codable, Sendable {
    case unsigned
    case verified
    case selfSigned
    case revoked

    public var localizedTitle: String {
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

public struct APKSignerSummary: Codable, Equatable, Sendable {
    public let distinguishedName: String
    public let publicKeySHA256: String

    public init(distinguishedName: String, publicKeySHA256: String) {
        self.distinguishedName = distinguishedName
        self.publicKeySHA256 = publicKeySHA256
    }
}

public struct APKAuthentication: Codable, Equatable, Sendable {
    public let scheme: APKSignatureScheme?
    public let state: APKAuthenticationState
    public let signers: [APKSignerSummary]
    public let warnings: [String]

    public static let unsigned = APKAuthentication(
        scheme: nil,
        state: .unsigned,
        signers: [],
        warnings: []
    )

    public init(
        scheme: APKSignatureScheme?,
        state: APKAuthenticationState,
        signers: [APKSignerSummary],
        warnings: [String]
    ) {
        self.scheme = scheme
        self.state = state
        self.signers = signers
        self.warnings = warnings
    }

    public var isSigned: Bool {
        scheme != nil && !signers.isEmpty
    }

    public var signerKeyHashes: [String] {
        signers.map(\.publicKeySHA256)
    }
}

public enum APKSignatureError: LocalizedError, Sendable {
    case unsupportedSignatureScheme
    case invalidArchive(String)
    case verificationFailed(String)

    public var errorDescription: String? {
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

public final class ApkSignatureVerifierKit: @unchecked Sendable {
    private let trustedStore: TrustedCertificateStore
    private let networkLoader: CRLNetworkLoader
    private let now: () -> Date
    private let requirement: APKSignatureRequirement
    private let ignoreExpiry: Bool
    private let crlCacheLock = NSLock()
    private var crlCache: [URL: CachedCRL] = [:]

    public init(
        trustedChainPEMData: Data? = nil,
        session: URLSession = .shared,
        now: @escaping () -> Date = Date.init,
        ignoreExpiry: Bool = false
    ) {
        self.trustedStore = TrustedCertificateStore(pemData: trustedChainPEMData)
        self.networkLoader = CRLNetworkLoader(session: session)
        self.now = now
        self.requirement = .optional
        self.ignoreExpiry = ignoreExpiry
    }

    init(
        trustedChainPEMData: Data?,
        session: URLSession,
        now: @escaping () -> Date,
        requirement: APKSignatureRequirement,
        ignoreExpiry: Bool = false
    ) {
        self.trustedStore = TrustedCertificateStore(pemData: trustedChainPEMData)
        self.networkLoader = CRLNetworkLoader(session: session)
        self.now = now
        self.requirement = requirement
        self.ignoreExpiry = ignoreExpiry
    }

    public func verify(packageURL: URL) throws -> APKAuthentication {
        guard let container = try APKSignatureContainer.parse(from: packageURL) else {
            return .unsigned
        }

        let signers = try parseSigners(from: container)
        guard !signers.isEmpty else {
            throw APKSignatureError.verificationFailed("署名者が含まれていません")
        }

        var digestCache: [ContentDigestAlgorithm: Data] = [:]
        var signerSummaries: [APKSignerSummary] = []
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

        let state: APKAuthenticationState
        if revoked {
            state = .revoked
        } else if allTrusted {
            state = .verified
        } else {
            state = .selfSigned
        }

        return APKAuthentication(
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
            throw APKSignatureError.verificationFailed("署名者証明書がありません")
        }

        if leafCertificate.subjectPublicKeyInfoDER != signer.publicKeyDER {
            throw APKSignatureError.verificationFailed(
                "署名者の公開鍵と証明書の SubjectPublicKeyInfo が一致しません"
            )
        }

        guard let signatureRecord = strongestSupportedSignature(in: signer.signatures) else {
            throw APKSignatureError.verificationFailed(
                "サポートされている署名アルゴリズムがありません"
            )
        }
        guard
            let digestRecord = signer.digests.first(where: {
                $0.algorithmID == signatureRecord.algorithmID
            })
        else {
            throw APKSignatureError.verificationFailed(
                "署名に対応するダイジェストが見つかりません"
            )
        }

        guard let publicKey = SecCertificateCopyKey(leafCertificate.secCertificate) else {
            throw APKSignatureError.verificationFailed("署名者証明書の公開鍵を取得できません")
        }
        guard
            SecKeyIsAlgorithmSupported(
                publicKey, .verify, signatureRecord.algorithm.secKeyAlgorithm)
        else {
            throw APKSignatureError.verificationFailed(
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
            throw APKSignatureError.verificationFailed(message)
        }

        let contentDigest: Data
        if let cached = digestCache[signatureRecord.algorithm.contentDigestAlgorithm] {
            contentDigest = cached
        } else {
            let computed = try computeContentDigest(
                algorithm: signatureRecord.algorithm.contentDigestAlgorithm,
                packageURL: container.packageURL,
                fileSize: container.fileSize,
                signingBlockOffset: container.signingBlockOffset,
                centralDirectoryOffset: container.centralDirectoryOffset,
                eocdOffset: container.eocdOffset
            )
            digestCache[signatureRecord.algorithm.contentDigestAlgorithm] = computed
            contentDigest = computed
        }

        guard contentDigest == digestRecord.digest else {
            throw APKSignatureError.verificationFailed(
                "パッケージ本体のダイジェストが一致しません"
            )
        }

        let trustResult = evaluateTrust(for: signer.certificates)
        return SignerVerificationResult(
            summary: APKSignerSummary(
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

        if ignoreExpiry, let leaf = certificates.first,
            let cert = try? Certificate(leaf.secCertificate)
        {
            SecTrustSetVerifyDate(trust, cert.notValidBefore as CFDate)
        }

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
            throw APKSignatureError.verificationFailed("CRL 発行者の公開鍵を取得できません")
        }
        guard let algorithm = crl.signatureAlgorithm.secKeyAlgorithm else {
            throw APKSignatureError.verificationFailed("CRL の署名アルゴリズムに対応していません")
        }
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else {
            throw APKSignatureError.verificationFailed("CRL の署名アルゴリズムを検証できません")
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
            throw APKSignatureError.invalidArchive("署名ブロック末尾に余分なデータがあります")
        }

        return signers
    }

    private func parseSigner(from reader: ByteReader, scheme: APKSignatureScheme) throws
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
            throw APKSignatureError.invalidArchive("署名者ブロック末尾に余分なデータがあります")
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
                throw APKSignatureError.verificationFailed(
                    "v3 署名者の SDK 範囲が一致しません"
                )
            }
            _ = try parseAttributes(from: signedDataReader.readLengthPrefixedReader())
        }

        guard signedDataReader.isAtEnd else {
            throw APKSignatureError.invalidArchive("signed data の形式が不正です")
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
}

private struct SignerVerificationResult {
    let summary: APKSignerSummary
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
        let box = ResultBox()
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let task = session.dataTask(with: request) { data, response, error in
            lock.lock()
            defer {
                lock.unlock()
                semaphore.signal()
            }

            if let error {
                box.result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                200..<300 ~= httpResponse.statusCode,
                let data
            else {
                box.result = .failure(APKSignatureError.verificationFailed("CRL の取得に失敗しました"))
                return
            }

            box.result = .success(data)
        }

        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw APKSignatureError.verificationFailed("CRL の取得がタイムアウトしました")
        }

        return try lock.withLock {
            guard let result = box.result else {
                throw APKSignatureError.verificationFailed("CRL の取得結果が不明です")
            }
            return try result.get()
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<Data, Error>?
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

    let fileSize: Int
    let packageURL: URL
    let scheme: APKSignatureScheme
    let schemeBlockData: Data
    let signingBlockOffset: Int
    let centralDirectoryOffset: Int
    let eocdOffset: Int

    static func parse(from url: URL) throws -> APKSignatureContainer? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(try handle.seekToEnd())
        let reader = FileRandomAccessReader(handle: handle, fileSize: fileSize)

        let eocdOffset = try ZIPParser.findEndOfCentralDirectory(using: reader)
        let eocd = try reader.readData(at: UInt64(eocdOffset), count: fileSize - eocdOffset)
        let centralDirectoryOffset = Int(try ZIPParser.readUInt32LE(in: eocd, at: 16))
        let centralDirectorySize = Int(try ZIPParser.readUInt32LE(in: eocd, at: 12))
        guard centralDirectoryOffset + centralDirectorySize == eocdOffset else {
            throw APKSignatureError.invalidArchive(
                "ZIP Central Directory の直後に EOCD がありません"
            )
        }
        guard centralDirectoryOffset >= 24 else {
            return nil
        }

        let footerOffset = centralDirectoryOffset - 24
        let magicData = try reader.readData(at: UInt64(footerOffset + 8), count: 16)
        guard magicData == magic else {
            return nil
        }

        let blockSize = Int(try reader.readUInt64LE(at: UInt64(footerOffset)))
        let blockOffset = centralDirectoryOffset - (blockSize + 8)
        guard blockOffset >= 0 else {
            throw APKSignatureError.invalidArchive("APK Signing Block の位置が不正です")
        }
        let headerSize = Int(try reader.readUInt64LE(at: UInt64(blockOffset)))
        guard headerSize == blockSize else {
            throw APKSignatureError.invalidArchive("APK Signing Block のサイズが一致しません")
        }

        let pairsData = try reader.readData(
            at: UInt64(blockOffset + 8),
            count: footerOffset - (blockOffset + 8)
        )
        var pairsReader = ByteReader(data: pairsData)
        var pairs: [UInt32: Data] = [:]
        while !pairsReader.isAtEnd {
            let pairLength = Int(try pairsReader.readUInt64())
            guard pairLength >= 4 else {
                throw APKSignatureError.invalidArchive("APK Signing Block のペア長が不正です")
            }
            var pairReader = try pairsReader.readReader(count: pairLength)
            let identifier = try pairReader.readUInt32()
            pairs[identifier] = try pairReader.readToEnd()
        }

        let containerFor = {
            (scheme: APKSignatureScheme, blockData: Data) -> APKSignatureContainer in
            APKSignatureContainer(
                fileSize: fileSize,
                packageURL: url,
                scheme: scheme,
                schemeBlockData: blockData,
                signingBlockOffset: blockOffset,
                centralDirectoryOffset: centralDirectoryOffset,
                eocdOffset: eocdOffset
            )
        }

        if let blockData = pairs[v31BlockID] {
            return containerFor(.v31, blockData)
        }
        if let blockData = pairs[v3BlockID] {
            return containerFor(.v3, blockData)
        }
        if let blockData = pairs[v2BlockID] {
            return containerFor(.v2, blockData)
        }

        if !pairs.isEmpty {
            throw APKSignatureError.unsupportedSignatureScheme
        }
        return nil
    }
}

private struct FileRandomAccessReader {
    let handle: FileHandle
    let fileSize: Int

    func readData(at offset: UInt64, count: Int) throws -> Data {
        guard offset + UInt64(count) <= UInt64(fileSize) else {
            throw APKSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw APKSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data
    }

    func readUInt64LE(at offset: UInt64) throws -> UInt64 {
        let data = try readData(at: offset, count: 8)
        return data.withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) }
    }
}

private struct ZIPParser {
    static let eocdSignature: UInt32 = 0x0605_4b50
    static let maxCommentLength = 65_535

    static func findEndOfCentralDirectory(using reader: FileRandomAccessReader) throws -> Int {
        guard reader.fileSize >= 22 else {
            throw APKSignatureError.invalidArchive("ZIP EOCD が見つかりません")
        }

        let lowerBound = max(0, reader.fileSize - (22 + maxCommentLength))
        let bufferSize = reader.fileSize - lowerBound
        let buffer = try reader.readData(at: UInt64(lowerBound), count: bufferSize)

        let upperBound = buffer.count - 22
        for offset in stride(from: upperBound, through: 0, by: -1) {
            if try readUInt32LE(in: buffer, at: offset) != eocdSignature {
                continue
            }

            let commentLength = Int(try readUInt16LE(in: buffer, at: offset + 20))
            if lowerBound + offset + 22 + commentLength == reader.fileSize {
                return lowerBound + offset
            }
        }

        throw APKSignatureError.invalidArchive("ZIP EOCD が見つかりません")
    }

    static func readUInt16LE(in data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw APKSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            UInt16(littleEndian: $0.load(as: UInt16.self))
        }
    }

    static func readUInt32LE(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw APKSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
        }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }

    static func readUInt64LE(in data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw APKSignatureError.invalidArchive("ZIP 読み取り範囲が不正です")
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
            throw APKSignatureError.invalidArchive("長さ付きデータの範囲が不正です")
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
