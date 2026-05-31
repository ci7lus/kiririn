import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

struct ParsedCertificate {
    let der: Data
    let secCertificate: SecCertificate
    let serialNumberHex: String
    let subjectDistinguishedName: String
    let subjectNameDER: Data
    let issuerNameDER: Data
    let subjectPublicKeyInfoDER: Data
    let crlDistributionPointURLs: [URL]

    init(der: Data) throws {
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw PluginPackageSignatureError.invalidArchive("X.509 証明書を読み取れません")
        }

        let certificate: Certificate
        do {
            certificate = try Certificate(secCertificate)
        } catch {
            throw PluginPackageSignatureError.invalidArchive("X.509 証明書を読み取れません")
        }

        let distributionPoints: [URL]
        if let distributionPointExtension = certificate.extensions[oid: crlDistributionPointsOID] {
            distributionPoints = try parseCRLDistributionPoints(
                der: Data(distributionPointExtension.value)
            )
        } else {
            distributionPoints = []
        }

        self.der = der
        self.secCertificate = secCertificate
        self.serialNumberHex = normalizeSerialHex(Data(certificate.serialNumber.bytes))
        self.subjectDistinguishedName = displayDistinguishedName(certificate.subject)
        self.subjectNameDER = try serializeToDER(certificate.subject)
        self.issuerNameDER = try serializeToDER(certificate.issuer)
        self.subjectPublicKeyInfoDER = try serializeToDER(certificate.publicKey)
        self.crlDistributionPointURLs = uniqued(distributionPoints)
    }
}

struct ParsedCRL {
    let tbsDER: Data
    let issuerNameDER: Data
    let nextUpdate: Date?
    let revokedSerialNumbers: Set<String>
    let signatureAlgorithm: X509SignatureAlgorithm
    let signature: Data

    init(der: Data) throws {
        let certificateList = try CertificateListValue(derEncoded: ASN1Node.singleNode(from: der))

        self.tbsDER = certificateList.tbsDER
        self.issuerNameDER = certificateList.issuerNameDER
        self.nextUpdate = certificateList.nextUpdate
        self.revokedSerialNumbers = certificateList.revokedSerialNumbers
        self.signatureAlgorithm = certificateList.signatureAlgorithm
        self.signature = certificateList.signature
    }
}

struct X509SignatureAlgorithm: Equatable {
    let oid: String
    let parameters: Data?

    init(node: ASN1Node) throws {
        let children = try node.children()
        guard !children.isEmpty else {
            throw PluginPackageSignatureError.invalidArchive("AlgorithmIdentifier の形式が不正です")
        }
        self.oid = try children[0].objectIdentifier()
        self.parameters = children.count > 1 ? children[1].fullData : nil
    }

    var secKeyAlgorithm: SecKeyAlgorithm? {
        switch oid {
        case "1.2.840.113549.1.1.11":
            return .rsaSignatureMessagePKCS1v15SHA256
        case "1.2.840.113549.1.1.13":
            return .rsaSignatureMessagePKCS1v15SHA512
        case "1.2.840.10045.4.3.2":
            return .ecdsaSignatureMessageX962SHA256
        case "1.2.840.10045.4.3.4":
            return .ecdsaSignatureMessageX962SHA512
        case "1.2.840.113549.1.1.10":
            return pssAlgorithm(from: parameters)
        default:
            return nil
        }
    }

    var isEd25519: Bool {
        oid == "1.3.101.112"
    }

    private func pssAlgorithm(from data: Data?) -> SecKeyAlgorithm? {
        guard let data,
            let parameters = try? RSASSAPSSParametersValue(
                derEncoded: ASN1Node.singleNode(from: data))
        else {
            return nil
        }

        switch (parameters.hashOID, parameters.saltLength) {
        case ("2.16.840.1.101.3.4.2.1", 32):
            return .rsaSignatureMessagePSSSHA256
        case ("2.16.840.1.101.3.4.2.3", 64):
            return .rsaSignatureMessagePSSSHA512
        default:
            return nil
        }
    }
}

private struct CertificateListValue: DERParseable {
    let tbsDER: Data
    let issuerNameDER: Data
    let nextUpdate: Date?
    let revokedSerialNumbers: Set<String>
    let signatureAlgorithm: X509SignatureAlgorithm
    let signature: Data

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(of: rootNode, message: "CRL の構造が不正です")
        guard children.count == 3 else {
            throw PluginPackageSignatureError.invalidArchive("CRL の構造が不正です")
        }

        let tbs = try TBSCertListValue(derEncoded: children[0])
        let outerAlgorithm = try X509SignatureAlgorithm(node: children[1])
        let signature = try children[2].bitStringPayload()

        guard tbs.signatureAlgorithm == outerAlgorithm else {
            throw PluginPackageSignatureError.invalidArchive("CRL の署名アルゴリズムが一致しません")
        }

        self.tbsDER = children[0].fullData
        self.issuerNameDER = tbs.issuerNameDER
        self.nextUpdate = tbs.nextUpdate
        self.revokedSerialNumbers = tbs.revokedSerialNumbers
        self.signatureAlgorithm = outerAlgorithm
        self.signature = signature
    }
}

private struct TBSCertListValue: DERParseable {
    let issuerNameDER: Data
    let nextUpdate: Date?
    let revokedSerialNumbers: Set<String>
    let signatureAlgorithm: X509SignatureAlgorithm

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(of: rootNode, message: "CRL の TBS 部分が不正です")
        var index = 0

        if index < children.count, children[index].identifier == .integer {
            index += 1
        }
        guard children.count > index + 2 else {
            throw PluginPackageSignatureError.invalidArchive("CRL の TBS 部分が不正です")
        }

        self.signatureAlgorithm = try X509SignatureAlgorithm(node: children[index])
        index += 1

        let issuer = children[index]
        index += 1
        _ = try children[index].timeValue()
        index += 1

        if index < children.count, children[index].isTimeNode {
            self.nextUpdate = try children[index].timeValue()
            index += 1
        } else {
            self.nextUpdate = nil
        }

        if index < children.count, children[index].identifier == .sequence {
            let entries = try DER.sequence(
                of: RevokedCertificateValue.self,
                identifier: .sequence,
                rootNode: children[index]
            )
            self.revokedSerialNumbers = Set(entries.map(\.serialNumberHex))
        } else {
            self.revokedSerialNumbers = []
        }

        self.issuerNameDER = issuer.fullData
    }
}

private struct RevokedCertificateValue: DERParseable {
    let serialNumberHex: String

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(of: rootNode, message: "CRL 失効エントリの形式が不正です")
        guard let serialNumber = children.first else {
            throw PluginPackageSignatureError.invalidArchive("CRL 失効エントリの形式が不正です")
        }
        self.serialNumberHex = normalizeSerialHex(serialNumber.valueData)
    }
}

private struct RSASSAPSSParametersValue: DERParseable {
    let hashOID: String
    let saltLength: Int

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(of: rootNode, message: "RSASSA-PSS パラメータの形式が不正です")
        let hashAlgorithmIdentifier = ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
        let saltLengthIdentifier = ASN1Identifier(tagWithNumber: 2, tagClass: .contextSpecific)

        var hashOID = "1.3.14.3.2.26"
        var saltLength = 20

        for child in children {
            switch child.identifier {
            case hashAlgorithmIdentifier:
                let algorithmIdentifier = try explicitSingleChild(
                    of: child,
                    message: "PSS hashAlgorithm の形式が不正です"
                )
                hashOID = try X509SignatureAlgorithm(node: algorithmIdentifier).oid
            case saltLengthIdentifier:
                let integerNode = try explicitSingleChild(
                    of: child,
                    message: "PSS saltLength の形式が不正です"
                )
                saltLength = integerNode.valueData.reduce(0) { ($0 << 8) | Int($1) }
            default:
                continue
            }
        }

        self.hashOID = hashOID
        self.saltLength = saltLength
    }
}

private struct CRLDistributionPointsValue: DERParseable {
    let urls: [URL]

    init(derEncoded rootNode: ASN1Node) throws {
        self.urls = try DER.sequence(
            of: CRLDistributionPointValue.self,
            identifier: .sequence,
            rootNode: rootNode
        ).flatMap(\.urls)
    }
}

private struct CRLDistributionPointValue: DERParseable {
    let urls: [URL]

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(
            of: rootNode,
            message: "CRL Distribution Point の形式が不正です"
        )
        let distributionPointIdentifier = ASN1Identifier(
            tagWithNumber: 0, tagClass: .contextSpecific)

        var urls: [URL] = []
        for child in children where child.identifier == distributionPointIdentifier {
            let distributionPointName = try explicitSingleChild(
                of: child,
                message: "DistributionPointName の形式が不正です"
            )
            urls.append(
                contentsOf: try DistributionPointNameValue(derEncoded: distributionPointName).urls)
        }
        self.urls = urls
    }
}

private struct DistributionPointNameValue: DERParseable {
    let urls: [URL]

    init(derEncoded rootNode: ASN1Node) throws {
        let fullNameIdentifier = ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)
        guard rootNode.identifier == fullNameIdentifier,
            case .constructed(let generalNameNodes) = rootNode.content
        else {
            self.urls = []
            return
        }

        self.urls = try generalNameNodes.compactMap { node in
            guard case .uniformResourceIdentifier(let uri) = try GeneralName(derEncoded: node)
            else {
                return nil
            }
            return URL(string: uri)
        }
    }
}

private struct SubjectPublicKeyInfoValue: DERParseable {
    let algorithmOID: String
    let publicKeyBytes: Data

    init(derEncoded rootNode: ASN1Node) throws {
        let children = try sequenceChildren(
            of: rootNode,
            message: "SubjectPublicKeyInfo の形式が不正です"
        )
        guard children.count == 2 else {
            throw PluginPackageSignatureError.invalidArchive("SubjectPublicKeyInfo の形式が不正です")
        }

        self.algorithmOID = try X509SignatureAlgorithm(node: children[0]).oid
        self.publicKeyBytes = try children[1].bitStringPayload()
    }
}

private func sequenceChildren(of node: ASN1Node, message: String) throws -> [ASN1Node] {
    guard node.identifier == .sequence,
        case .constructed(let children) = node.content
    else {
        throw PluginPackageSignatureError.invalidArchive(message)
    }
    return Array(children)
}

private func explicitSingleChild(of node: ASN1Node, message: String) throws -> ASN1Node {
    guard case .constructed(let children) = node.content else {
        throw PluginPackageSignatureError.invalidArchive(message)
    }
    let decodedChildren = Array(children)
    guard decodedChildren.count == 1 else {
        throw PluginPackageSignatureError.invalidArchive(message)
    }
    return decodedChildren[0]
}

extension ASN1Node {
    fileprivate static func singleNode(from data: Data) throws -> ASN1Node {
        do {
            return try DER.parse(Array(data))
        } catch {
            throw PluginPackageSignatureError.invalidArchive("ASN.1 を解析できません")
        }
    }

    fileprivate var tag: UInt8 {
        var value = UInt8(truncatingIfNeeded: identifier.tagNumber)
        switch identifier.tagClass {
        case .universal:
            break
        case .application:
            value |= 0x40
        case .contextSpecific:
            value |= 0x80
        case .private:
            value |= 0xc0
        }
        if case .constructed = content {
            value |= 0x20
        }
        return value
    }

    fileprivate var fullData: Data {
        Data(encodedBytes)
    }

    fileprivate var valueData: Data {
        switch content {
        case .primitive(let bytes):
            return Data(bytes)
        case .constructed(let nodes):
            return nodes.reduce(into: Data()) { partialResult, child in
                partialResult.append(contentsOf: child.encodedBytes)
            }
        }
    }

    fileprivate var isTimeNode: Bool {
        identifier == .utcTime || identifier == .generalizedTime
    }

    fileprivate func children() throws -> [ASN1Node] {
        guard case .constructed(let nodes) = content else {
            return []
        }
        return Array(nodes)
    }

    fileprivate func objectIdentifier() throws -> String {
        do {
            return String(describing: try ASN1ObjectIdentifier(derEncoded: self))
        } catch {
            throw PluginPackageSignatureError.invalidArchive("OID の形式が不正です")
        }
    }

    fileprivate func timeValue() throws -> Date {
        switch identifier {
        case .utcTime:
            do {
                return try date(from: UTCTime(derEncoded: self))
            } catch {
                throw PluginPackageSignatureError.invalidArchive("時刻を解析できません")
            }
        case .generalizedTime:
            do {
                return try date(from: GeneralizedTime(derEncoded: self))
            } catch {
                throw PluginPackageSignatureError.invalidArchive("時刻を解析できません")
            }
        default:
            throw PluginPackageSignatureError.invalidArchive("時刻形式が不正です")
        }
    }

    fileprivate func bitStringPayload() throws -> Data {
        do {
            let bitString = try ASN1BitString(derEncoded: self)
            guard bitString.paddingBits == 0 else {
                throw PluginPackageSignatureError.invalidArchive("BIT STRING の形式が不正です")
            }
            return Data(bitString.bytes)
        } catch let error as PluginPackageSignatureError {
            throw error
        } catch {
            throw PluginPackageSignatureError.invalidArchive("BIT STRING の形式が不正です")
        }
    }
}

private func parseCRLDistributionPoints(der: Data) throws -> [URL] {
    try CRLDistributionPointsValue(derEncoded: ASN1Node.singleNode(from: der)).urls
}

func computeContentDigest(
    algorithm: ContentDigestAlgorithm,
    packageData: Data,
    signingBlockOffset: Int,
    centralDirectoryOffset: Int,
    eocdOffset: Int
) throws -> Data {
    let chunkSize = 1 << 20
    let section1 = packageData.subdata(in: 0..<signingBlockOffset)
    let section3 = packageData.subdata(in: centralDirectoryOffset..<eocdOffset)
    var section4 = packageData.subdata(in: eocdOffset..<packageData.count)
    let offsetData = withUnsafeBytes(of: UInt32(signingBlockOffset).littleEndian) { Data($0) }
    section4.replaceSubrange(16..<20, with: offsetData)

    let sections = [section1, section3, section4]
    let chunkCount = sections.reduce(0) { partialResult, section in
        guard !section.isEmpty else {
            return partialResult
        }
        return partialResult + Int(ceil(Double(section.count) / Double(chunkSize)))
    }

    var concatenated = Data([0x5a])
    concatenated.append(littleEndianData(UInt32(chunkCount)))

    for section in sections {
        guard !section.isEmpty else { continue }

        var offset = 0
        while offset < section.count {
            let length = min(chunkSize, section.count - offset)
            let chunk = section.subdata(in: offset..<(offset + length))
            var chunkInput = Data([0xa5])
            chunkInput.append(littleEndianData(UInt32(length)))
            chunkInput.append(chunk)
            concatenated.append(algorithm.hash(chunkInput))
            offset += length
        }
    }

    return algorithm.hash(concatenated)
}

func verifyEd25519Signature(
    signature: Data,
    message: Data,
    subjectPublicKeyInfoDER: Data
) throws -> Bool {
    let rawPublicKey = try rawEd25519PublicKey(from: subjectPublicKeyInfoDER)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)
    return publicKey.isValidSignature(signature, for: message)
}

private func rawEd25519PublicKey(from subjectPublicKeyInfoDER: Data) throws -> Data {
    let subjectPublicKeyInfo = try SubjectPublicKeyInfoValue(
        derEncoded: ASN1Node.singleNode(from: subjectPublicKeyInfoDER)
    )
    guard subjectPublicKeyInfo.algorithmOID == "1.3.101.112" else {
        throw PluginPackageSignatureError.invalidArchive("Ed25519 の公開鍵ではありません")
    }
    return subjectPublicKeyInfo.publicKeyBytes
}

private func littleEndianData(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

func mergeCertificatePools(
    _ lhs: [ParsedCertificate],
    _ rhs: [ParsedCertificate]
) -> [ParsedCertificate] {
    var seen = Set<Data>()
    var output: [ParsedCertificate] = []
    for certificate in lhs + rhs where seen.insert(certificate.subjectNameDER).inserted {
        output.append(certificate)
    }
    return output
}

func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func normalizeSerialHex(_ data: Data) -> String {
    let trimmed = data.drop { $0 == 0 }
    let normalized = trimmed.isEmpty ? Data([0]) : Data(trimmed)
    return normalized.map { String(format: "%02X", $0) }.joined()
}

private let crlDistributionPointsOID: ASN1ObjectIdentifier = "2.5.29.31"

private func serializeToDER<T: DERSerializable>(_ value: T) throws -> Data {
    var serializer = DER.Serializer()
    try serializer.serialize(value)
    return Data(serializer.serializedBytes)
}

private func date(from utcTime: UTCTime) throws -> Date {
    try date(
        year: utcTime.year,
        month: utcTime.month,
        day: utcTime.day,
        hour: utcTime.hours,
        minute: utcTime.minutes,
        second: utcTime.seconds,
        nanosecond: 0
    )
}

private func date(from generalizedTime: GeneralizedTime) throws -> Date {
    let nanoseconds = Int((generalizedTime.fractionalSeconds * 1_000_000_000).rounded())
    return try date(
        year: generalizedTime.year,
        month: generalizedTime.month,
        day: generalizedTime.day,
        hour: generalizedTime.hours,
        minute: generalizedTime.minutes,
        second: generalizedTime.seconds,
        nanosecond: nanoseconds
    )
}

private func date(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int,
    second: Int,
    nanosecond: Int
) throws -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = nanosecond

    guard let date = components.date else {
        throw PluginPackageSignatureError.invalidArchive("時刻を解析できません")
    }
    return date
}

private func displayDistinguishedName(_ name: DistinguishedName) -> String {
    name.map { String(describing: $0) }.joined(separator: ", ")
}

func uniqued<T: Hashable>(_ values: [T]) -> [T] {
    var seen: Set<T> = []
    return values.filter { seen.insert($0).inserted }
}

extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
