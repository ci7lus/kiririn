import Foundation
import Testing

@testable import kiririn

struct PluginInstallDeepLinkTests {
    @Test func parsesUpdateManifestInstallRequest() throws {
        let url = try #require(
            URL(
                string:
                    "kiririn://plugins/?updateManifestUrl=https://cdn.jsdelivr.net/gh/ci7lus/kiririn-plugins@main/update.json&manifestID=io.github.ci7lus.kiririn-plugins.nicojk"
            ))
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let request = try #require(PluginInstallDeepLink(components: components))

        #expect(
            request.updateManifestURL.absoluteString
                == "https://cdn.jsdelivr.net/gh/ci7lus/kiririn-plugins@main/update.json"
        )
        #expect(request.manifestID == "io.github.ci7lus.kiririn-plugins.nicojk")
    }

    @Test func rejectsMissingManifestID() throws {
        let url = try #require(
            URL(
                string:
                    "kiririn://plugins/?updateManifestUrl=https://example.com/update.json"
            ))
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(PluginInstallDeepLink(components: components) == nil)
    }

    @Test func rejectsNonHTTPUpdateManifestURL() throws {
        let url = try #require(
            URL(
                string:
                    "kiririn://plugins/?updateManifestUrl=file:///tmp/update.json&manifestID=com.example.plugin"
            ))
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(PluginInstallDeepLink(components: components) == nil)
    }
}
