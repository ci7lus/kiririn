import CryptoKit
import Foundation
import Testing

@testable import KppxKit

struct GeckoUpdateHashTests {

    @Test func parsesSha256Hash() throws {
        let hash = try #require(GeckoUpdateHash("sha256:" + String(repeating: "a", count: 64)))
        #expect(hash.expectedHex == String(repeating: "a", count: 64))
    }

    @Test func parsesSha512Hash() throws {
        let hash = try #require(GeckoUpdateHash("sha512:" + String(repeating: "b", count: 128)))
        #expect(hash.expectedHex == String(repeating: "b", count: 128))
    }

    @Test func normalizesUppercaseToLowercase() throws {
        let hash = try #require(GeckoUpdateHash("sha256:" + String(repeating: "A", count: 64)))
        #expect(hash.expectedHex == String(repeating: "a", count: 64))
    }

    @Test func rejectsEmptyString() {
        #expect(GeckoUpdateHash("") == nil)
        #expect(GeckoUpdateHash(nil) == nil)
    }

    @Test func rejectsInvalidFormat() {
        #expect(GeckoUpdateHash("not-a-hash") == nil)
        #expect(GeckoUpdateHash("sha256:") == nil)
        #expect(GeckoUpdateHash("md5:abc") == nil)
    }

    @Test func rejectsWrongLength() {
        #expect(GeckoUpdateHash("sha256:" + String(repeating: "a", count: 32)) == nil)
        #expect(GeckoUpdateHash("sha512:" + String(repeating: "a", count: 64)) == nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(GeckoUpdateHash("sha256:" + String(repeating: "z", count: 64)) == nil)
    }

    @Test func matchesActualDataHash() {
        let data = Data("hello world".utf8)
        let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let hash = GeckoUpdateHash("sha256:" + expectedHash)
        #expect(hash?.matches(data: data) == true)
    }

    @Test func doesNotMatchDifferentData() {
        let data = Data("hello world".utf8)
        let differentData = Data("hello WORLD".utf8)
        let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let hash = GeckoUpdateHash("sha256:" + expectedHash)
        #expect(hash?.matches(data: differentData) == false)
    }
}

struct PluginUpdateResolverTests {

    @Test func compatibleUpdateWithoutApplicationInfo() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "https://example.com/update.kppx",
            updateHash: "sha256:abc",
            updateInfoURL: nil,
            applications: nil
        )
        #expect(resolver.isCompatible(entry))
    }

    @Test func incompatibleUpdateForOlderAppVersion() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "https://example.com/update.kppx",
            updateHash: "sha256:abc",
            updateInfoURL: nil,
            applications: GeckoUpdateManifestApplications(
                kiririn: GeckoUpdateManifestKiririnApplication(
                    strictMinVersion: "2.0.0",
                    strictMaxVersion: nil,
                    advisoryMaxVersion: nil
                )
            )
        )
        #expect(!resolver.isCompatible(entry))
    }

    @Test func supportsHTTPSUpdate() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "https://example.com/update.kppx",
            updateHash: nil,
            updateInfoURL: nil,
            applications: nil
        )
        #expect(resolver.supportsUpdateDownload(entry))
    }

    @Test func supportsHTTPUpdateWithHash() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "http://example.com/update.kppx",
            updateHash: "sha256:abc",
            updateInfoURL: nil,
            applications: nil
        )
        #expect(resolver.supportsUpdateDownload(entry))
    }

    @Test func doesNotSupportHTTPUpdateWithoutHash() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "http://example.com/update.kppx",
            updateHash: nil,
            updateInfoURL: nil,
            applications: nil
        )
        #expect(!resolver.supportsUpdateDownload(entry))
    }

    @Test func doesNotSupportInvalidScheme() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        let entry = GeckoUpdateManifestEntry(
            version: "2.0.0",
            updateLink: "ftp://example.com/update.kppx",
            updateHash: "sha256:abc",
            updateInfoURL: nil,
            applications: nil
        )
        #expect(!resolver.supportsUpdateDownload(entry))
    }

    @Test func acceptsUpgradeVersion() throws {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        try resolver.validateUpdateVersion(
            currentVersion: "1.0.0",
            candidateVersion: "2.0.0"
        )
    }

    @Test func rejectsDowngrade() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        do {
            try resolver.validateUpdateVersion(
                currentVersion: "2.0.0",
                candidateVersion: "1.0.0"
            )
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }

    @Test func rejectsSameVersion() {
        let resolver = PluginUpdateResolver(currentAppVersion: "1.0.0")
        do {
            try resolver.validateUpdateVersion(
                currentVersion: "1.0.0",
                candidateVersion: "1.0.0"
            )
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }
}
