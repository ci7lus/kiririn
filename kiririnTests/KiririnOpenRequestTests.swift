import Foundation
import Testing

@testable import kiririn

struct KiririnOpenRequestTests {
    @Test func parsesServiceDeepLinkRequest() throws {
        let url = try #require(
            URL(string: "kiririn://open/service?networkId=32736&serviceId=1024&serverId=server-a")
        )
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(components.host == "open")
        #expect(components.path == "/service")
        #expect(
            ServiceOpenRequest(components: components)
                == ServiceOpenRequest(
                    networkId: 32736,
                    serviceId: 1024,
                    preferredServerId: "server-a"
                )
        )
    }

    @Test func rejectsInvalidServiceIdentifiers() throws {
        let url = try #require(
            URL(string: "kiririn://open/service?networkId=65536&serviceId=1024")
        )
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(ServiceOpenRequest(components: components) == nil)
    }

    @Test func emptyPreferredServerIDIsIgnored() throws {
        let url = try #require(
            URL(string: "kiririn://open/service?networkId=1&serviceId=2&serverId=%20")
        )
        let components = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        #expect(
            ServiceOpenRequest(components: components)
                == ServiceOpenRequest(networkId: 1, serviceId: 2)
        )
    }

    @Test func buildsServiceDeepLinkURL() throws {
        let url = try #require(
            ServiceOpenRequest(
                networkId: 32736,
                serviceId: 1024,
                preferredServerId: "server-a"
            ).deepLinkURL
        )

        #expect(
            url.absoluteString
                == "kiririn://open/service?networkId=32736&serviceId=1024&serverId=server-a"
        )
    }

    @Test func openErrorsExposeOperationAndCode() {
        #expect(KiririnOpenError.invalidURL.operation == "openURL")
        #expect(KiririnOpenError.invalidURL.code == "invalidURL")
        #expect(KiririnOpenError.serviceNotFound.operation == "openService")
        #expect(KiririnOpenError.serviceNotFound.code == "serviceNotFound")
    }

    @Test(arguments: [
        "http:stream.ts",
        "https:/stream.ts",
        "https://",
        "ftp://example.com/stream.ts",
    ])
    func rejectsMediaURLsWithoutAnHTTPHost(_ rawURL: String) {
        #expect(PlaybackOpenCoordinator.validatedMediaURL(from: rawURL) == nil)
    }

    @Test func acceptsAndNormalizesHTTPMediaURL() throws {
        let url = try #require(
            PlaybackOpenCoordinator.validatedMediaURL(
                from: " HTTPS://example.com/live.ts "
            )
        )

        #expect(url.absoluteString == "https://example.com/live.ts")
    }
}
