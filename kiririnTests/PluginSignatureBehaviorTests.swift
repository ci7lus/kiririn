import Foundation
import Testing

@testable import kiririn

struct PluginSignatureBehaviorTests {

    @Test func packageSignatureVerifierTreatsUnsignedArchiveAsUnsigned() throws {
        let verifier = PluginPackageSignatureVerifier(trustedChainPEMData: nil)
        let tempURL = try tempFileForTest(data: emptyZIPData())
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let authentication = try verifier.verify(packageURL: tempURL)

        #expect(authentication.state == .unsigned)
        #expect(!authentication.isSigned)
        #expect(authentication.scheme == nil)
    }

    @Test func pluginStoreStoresUnsignedPackageAuthenticationAndDisablesManualUpdate() throws {
        let suiteName = "kiririn.plugin.signature.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(
            defaults: defaults,
            packageSignatureVerifier: PluginPackageSignatureVerifier(trustedChainPEMData: nil)
        )
        let packageData = unsignedPluginPackageData(
            manifestID: "com.example.unsigned",
            updateURL: "https://example.com/plugins/sample/update.json"
        )
        let tempURL = try tempFileForTest(data: packageData)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let preview = try store.previewPlugin(packageURL: tempURL, sourceType: .kppx)
        let plugin = try store.installPlugin(from: preview)

        #expect(preview.packageAuthentication.state == .unsigned)
        #expect(plugin.packageAuthentication.state == .unsigned)
        #expect(plugin.manifestUpdateURL == "https://example.com/plugins/sample/update.json")
        #expect(!plugin.canCheckForUpdates)
    }

    @Test func remoteUpdateRejectsUnsignedInstalledPackageBeforeFetching() async {
        let suiteName = "kiririn.plugin.signature.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(
            defaults: defaults,
            packageSignatureVerifier: PluginPackageSignatureVerifier(trustedChainPEMData: nil)
        )
        let plugin = PluginDefinition(
            id: UUID(),
            name: "Unsigned Plugin",
            sourceType: .kppx,
            resourceBasePath: "unsigned.kppx",
            manifestUpdateURL: "https://example.com/plugins/sample/update.json",
            manifestID: "com.example.unsigned",
            packageAuthentication: .unsigned
        )

        do {
            try await store.overwritePlugin(
                fromUpdateManifestURL: URL(
                    string: "https://example.com/plugins/sample/update.json")!,
                previous: plugin
            )
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("未署名パッケージ") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func refreshPreservesStoredPackageAuthenticationForArchivePlugins() throws {
        let suiteName = "kiririn.plugin.signature.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(
            defaults: defaults,
            packageSignatureVerifier: PluginPackageSignatureVerifier(trustedChainPEMData: nil)
        )
        let packageData = unsignedPluginPackageData(
            manifestID: "com.example.signed",
            updateURL: "https://example.com/plugins/signed/update.json"
        )
        let archiveFileName = "signed-\(UUID().uuidString).kppx"
        let archiveURL = store.pluginDirectoryURL.appending(path: archiveFileName)
        let authentication = PluginPackageAuthentication(
            scheme: .v3,
            state: .verified,
            signers: [
                PluginPackageSignerSummary(
                    distinguishedName: "CN=kiririn Signer S1",
                    publicKeySHA256: "deadbeef"
                )
            ],
            warnings: []
        )

        try FileManager.default.createDirectory(
            at: store.pluginDirectoryURL,
            withIntermediateDirectories: true
        )
        try packageData.write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let plugin = PluginDefinition(
            id: UUID(),
            name: "Signed Plugin",
            sourceType: .kppx,
            resourceBasePath: archiveFileName,
            manifestUpdateURL: "https://example.com/plugins/signed/update.json",
            manifestID: "com.example.signed",
            packageAuthentication: authentication
        )

        store.plugins = [plugin]
        store.refreshPluginsFromFiles()

        let refreshed = try #require(store.plugin(id: plugin.id))
        #expect(refreshed.packageAuthentication == authentication)
    }

    @Test func installRoutingTreatsUnknownManifestAsNewInstall() throws {
        let suiteName = "kiririn.plugin.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        let preview = routingPreview(
            manifestID: "com.example.routing.install", signerHashes: ["aa"])

        let routing = try store.installRouting(for: preview)
        if case .install = routing {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test func installRoutingRoutesExistingManifestToUpdateWhenSignerMatches() throws {
        let suiteName = "kiririn.plugin.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        let previous = routingPlugin(
            manifestID: "com.example.routing.update",
            signerHashes: ["same-signer"]
        )
        store.plugins = [previous]
        let preview = routingPreview(
            manifestID: "com.example.routing.update",
            signerHashes: ["same-signer"]
        )

        let routing = try store.installRouting(for: preview)
        if case .update(let pluginID, let signerMismatch) = routing {
            #expect(pluginID == previous.id)
            #expect(!signerMismatch)
        } else {
            #expect(Bool(false))
        }
    }

    @Test func updateRoutingRejectsSignerMismatchWhenDeveloperModeDisabled() throws {
        let suiteName = "kiririn.plugin.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        let previous = routingPlugin(
            manifestID: "com.example.routing.reject",
            signerHashes: ["trusted-a"]
        )
        let preview = routingPreview(
            manifestID: "com.example.routing.reject",
            signerHashes: ["trusted-b"]
        )

        do {
            _ = try store.updateRouting(replacing: previous, with: preview)
            #expect(Bool(false))
        } catch let error as PluginManifestValidationError {
            #expect(error.messages.contains { $0.contains("署名元が一致しない") })
        } catch {
            #expect(Bool(false))
        }
    }

    @Test func updateRoutingAllowsSignerMismatchWhenDeveloperModeEnabled() throws {
        let suiteName = "kiririn.plugin.routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PluginStore(defaults: defaults)
        store.setDeveloperModeEnabled(true)

        let previous = routingPlugin(
            manifestID: "com.example.routing.devmode",
            signerHashes: ["trusted-a"]
        )
        let preview = routingPreview(
            manifestID: "com.example.routing.devmode",
            signerHashes: ["trusted-b"]
        )

        let routing = try store.updateRouting(replacing: previous, with: preview)
        if case .update(let pluginID, let signerMismatch) = routing {
            #expect(pluginID == previous.id)
            #expect(signerMismatch)
        } else {
            #expect(Bool(false))
        }
    }
}

private func routingPlugin(manifestID: String, signerHashes: [String]) -> PluginDefinition {
    PluginDefinition(
        id: UUID(),
        name: "Routing Plugin",
        sourceType: .kppx,
        resourceBasePath: "routing.kppx",
        manifestID: manifestID,
        packageAuthentication: routingAuthentication(signerHashes: signerHashes)
    )
}

private func routingPreview(manifestID: String, signerHashes: [String]) -> PluginInstallPreview {
    PluginInstallPreview.testing(
        sourceType: .kppx,
        manifest: routingManifest(manifestID: manifestID),
        packageAuthentication: routingAuthentication(signerHashes: signerHashes)
    )
}

private func routingAuthentication(signerHashes: [String]) -> PluginPackageAuthentication {
    PluginPackageAuthentication(
        scheme: .v3,
        state: .verified,
        signers: signerHashes.map { hash in
            PluginPackageSignerSummary(
                distinguishedName: "CN=Routing Signer",
                publicKeySHA256: hash
            )
        },
        warnings: []
    )
}

private func routingManifest(manifestID: String) -> ExtensionPluginManifest {
    ExtensionPluginManifest(
        manifestID: manifestID,
        displayName: "Routing Preview",
        version: "1.0.0",
        author: "Tester",
        homepageURL: nil,
        summary: nil,
        displayAreas: [.overlay],
        overlayPage: "overlay.html",
        panelPage: nil,
        optionsPage: nil,
        isBackgroundExists: false,
        strictMinVersion: nil,
        strictMaxVersion: nil,
        manifestUpdateURL: nil,
        requestedPermissions: ["storage"],
        requestedHostPermissions: []
    )
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

private func unsignedPluginPackageData(manifestID: String, updateURL: String) -> Data {
    let manifest = """
        {
          "manifest_version": 3,
          "name": "Unsigned Plugin",
          "version": "1.0.0",
          "author": "Tester",
          "permissions": ["storage"],
          "host_permissions": [],
          "browser_specific_settings": {
            "kiririn": {
              "id": "\(manifestID)",
              "views": {
                "overlay": {
                  "page": "overlay.html"
                }
              }
            }
          },
          "update_url": "\(updateURL)"
        }
        """

    return storedZIPData(
        files: [
            ("manifest.json", Data(manifest.utf8)),
            ("overlay.html", Data("<html><body>overlay</body></html>".utf8)),
        ]
    )
}

private func storedZIPData(files: [(String, Data)]) -> Data {
    var localEntries = Data()
    var centralDirectory = Data()

    for (path, contents) in files {
        let pathData = Data(path.utf8)
        let crc = crc32(contents)
        let localHeaderOffset = UInt32(localEntries.count)

        localEntries.append(littleEndian(UInt32(0x0403_4b50)))
        localEntries.append(littleEndian(UInt16(20)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(littleEndian(crc))
        localEntries.append(littleEndian(UInt32(contents.count)))
        localEntries.append(littleEndian(UInt32(contents.count)))
        localEntries.append(littleEndian(UInt16(pathData.count)))
        localEntries.append(littleEndian(UInt16(0)))
        localEntries.append(pathData)
        localEntries.append(contents)

        centralDirectory.append(littleEndian(UInt32(0x0201_4b50)))
        centralDirectory.append(littleEndian(UInt16(20)))
        centralDirectory.append(littleEndian(UInt16(20)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(crc))
        centralDirectory.append(littleEndian(UInt32(contents.count)))
        centralDirectory.append(littleEndian(UInt32(contents.count)))
        centralDirectory.append(littleEndian(UInt16(pathData.count)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt16(0)))
        centralDirectory.append(littleEndian(UInt32(0)))
        centralDirectory.append(littleEndian(localHeaderOffset))
        centralDirectory.append(pathData)
    }

    let centralDirectoryOffset = UInt32(localEntries.count)

    var output = localEntries
    output.append(centralDirectory)
    output.append(littleEndian(UInt32(0x0605_4b50)))
    output.append(littleEndian(UInt16(0)))
    output.append(littleEndian(UInt16(0)))
    output.append(littleEndian(UInt16(files.count)))
    output.append(littleEndian(UInt16(files.count)))
    output.append(littleEndian(UInt32(centralDirectory.count)))
    output.append(littleEndian(centralDirectoryOffset))
    output.append(littleEndian(UInt16(0)))
    return output
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

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xedb8_8320 & mask)
        }
    }
    return ~crc
}
