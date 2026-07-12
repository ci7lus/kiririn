import Foundation
import Testing

@testable import kiririn

/// 通信コンテンツ用プロキシ(BMLURLSchemeHandler /ip/*)の入力検証。実際の
/// HTTP往復はサンドボックス(network.clientのみ)内でローカルサーバーを
/// 張れないためここでは扱わず、検証はすべてネットワークに触る前に
/// throwする経路のみ。
struct BMLInternetProxyTests {

    private func proxyError(path: String, query: String, request: URLRequest? = nil) async
        -> URLError.Code?
    {
        let url = URL(string: "kiririn-bml://app\(path)?\(query)")!
        do {
            _ = try await BMLURLSchemeHandler.performProxy(
                path: path, requestURL: url,
                originalRequest: request ?? URLRequest(url: url))
            return nil
        } catch let error as URLError {
            return error.code
        } catch {
            return nil
        }
    }

    @Test func proxyRejectsNonHTTPTargetURL() async {
        let fileURL = "file%3A%2F%2F%2Fetc%2Fhosts"
        #expect(await proxyError(path: "/ip/get", query: "url=\(fileURL)") == .badURL)
        #expect(await proxyError(path: "/ip/post", query: "url=\(fileURL)") == .badURL)
        #expect(
            await proxyError(path: "/ip/get", query: "url=kiririn-bml%3A%2F%2Fapp%2Fbml.html")
                == .badURL)
    }

    @Test func proxyRejectsMissingTargetURL() async {
        #expect(await proxyError(path: "/ip/get", query: "") == .badURL)
        #expect(await proxyError(path: "/ip/post", query: "other=1") == .badURL)
    }

    @Test func proxyRejectsUnknownPath() async {
        #expect(
            await proxyError(path: "/ip/delete", query: "url=http%3A%2F%2Fexample.invalid%2F")
                == .fileDoesNotExist)
    }

    @Test func proxyCapsPostBodyAtDenbunLimit() async {
        // 電文の上限(4096 + "Denbun=")を1バイトでも超えたら、ネットワークに
        // 触る前に弾かれる。
        let url = URL(string: "kiririn-bml://app/ip/post?url=http%3A%2F%2Fexample.invalid%2F")!
        var request = URLRequest(url: url)
        request.httpBody = Data(repeating: 0x41, count: 4096 + "Denbun=".count + 1)
        let code = await proxyError(
            path: "/ip/post", query: "url=http%3A%2F%2Fexample.invalid%2F", request: request)
        #expect(code == .dataLengthExceedsMaximum)
    }

    @Test func proxyConfirmRequiresDestinationAndTimeout() async {
        #expect(await proxyError(path: "/ip/confirm", query: "") == .badURL)
        #expect(await proxyError(path: "/ip/confirm", query: "destination=example.com") == .badURL)
        #expect(
            await proxyError(
                path: "/ip/confirm", query: "destination=example.com&timeoutMillis=abc")
                == .badURL)
        #expect(
            await proxyError(path: "/ip/confirm", query: "destination=&timeoutMillis=1000")
                == .badURL)
    }

    @Test func proxyConfirmReportsResolutionFailureAsJSONNulls() async throws {
        let url = URL(
            string:
                "kiririn-bml://app/ip/confirm?destination=definitely-not-a-real-host.invalid&timeoutMillis=3000"
        )!
        let (response, data) = try await BMLURLSchemeHandler.performProxy(
            path: "/ip/confirm", requestURL: url, originalRequest: URLRequest(url: url))

        #expect(response.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(json["ipAddress"] is NSNull)
        #expect(json["responseTimeMillis"] is NSNull)
    }

    @Test func resolveIPv4ResolvesLoopback() async {
        let address = await BMLURLSchemeHandler.resolveIPv4("localhost", timeoutMillis: 5000)
        #expect(address == "127.0.0.1")
    }

    @Test func resolveIPv4FailsForInvalidHost() async {
        let address = await BMLURLSchemeHandler.resolveIPv4(
            "definitely-not-a-real-host.invalid", timeoutMillis: 3000)
        #expect(address == nil)
    }
}
