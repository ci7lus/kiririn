import Foundation
import Testing

@testable import kiririn

struct APIClientDiagnosticsTests {

    private struct Payload: Decodable {
        let programs: [String]
    }

    @Test func decodingDiagnosticReportsJSONErrorIndexAndControlCharacterSnippet() throws {
        let data =
            Data(#"{"programs":["正常"#.utf8)
            + Data([0x1D])
            + Data(#""]}"#.utf8)
        let url = URL(string: "http://example.com/api/programs")!
        let expectedIndex = try #require(data.firstIndex(of: 0x1D))

        do {
            _ = try JSONDecoder().decode(Payload.self, from: data)
            Issue.record("Expected malformed JSON to fail decoding")
        } catch {
            let diagnostic = APIClient.makeDecodingDiagnostic(
                data: data,
                error: error,
                url: url,
                serverName: "Main",
                serverType: .mirakurun,
                contentType: "application/json"
            )

            #expect(diagnostic.errorIndex == expectedIndex)
            #expect(diagnostic.summary.contains("Main"))
            #expect(diagnostic.summary.contains("Mirakurun"))
            #expect(diagnostic.summary.contains("/api/programs"))
            #expect(diagnostic.summary.contains("byte \(expectedIndex)"))
            #expect(diagnostic.reason.contains("dataCorrupted"))
            #expect(diagnostic.detail.contains("contentType=application/json"))
            #expect(diagnostic.detail.contains("errorIndex=\(expectedIndex)"))
            #expect(diagnostic.snippet?.contains("\\u{001D}") == true)
            #expect(diagnostic.snippet?.contains("[1D]") == true)

            let apiError = APIError.decodingError(diagnostic)
            let feedback = apiError.feedbackContent
            #expect(apiError.briefDescription == "データの解析に失敗しました(byte \(expectedIndex))")
            #expect(feedback.title == "データの解析に失敗しました")
            #expect(
                feedback.fields.contains(.init(label: "Content-Type", value: "application/json")))
            #expect(feedback.fields.contains(.init(label: "バイト位置", value: "\(expectedIndex)")))
            #expect(feedback.response?.contains("\\u{001D}") == true)
            #expect(apiError.localizedDescription.contains("理由:dataCorrupted"))
            #expect(apiError.localizedDescription.contains("レスポンス:"))
        }
    }

    @Test func httpErrorDiagnosticReportsStatusAndResponseBody() throws {
        let data = Data(#"{"error":"bad request","message":"invalid token"}"#.utf8)
        let url = URL(string: "http://example.com/api/status")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
        )

        let diagnostic = APIClient.makeHTTPErrorDiagnostic(
            data: data,
            response: response,
            url: url
        )
        let apiError = APIError.httpError(statusCode: 400, diagnostic: diagnostic)
        let feedback = apiError.feedbackContent

        #expect(diagnostic.statusCode == 400)
        #expect(diagnostic.contentType == "application/json")
        #expect(diagnostic.responseBody?.contains("invalid token") == true)
        #expect(apiError.briefDescription == "HTTPエラー: 400 bad request")
        #expect(feedback.title == "HTTPエラー")
        #expect(feedback.fields.contains(.init(label: "ステータス", value: "400 bad request")))
        #expect(feedback.fields.contains(.init(label: "URL", value: url.absoluteString)))
        #expect(feedback.fields.contains(.init(label: "Content-Type", value: "application/json")))
        #expect(feedback.response?.contains("invalid token") == true)
        #expect(apiError.localizedDescription.contains("HTTPエラー: 400"))
        #expect(apiError.localizedDescription.contains("Content-Type: application/json"))
        #expect(apiError.localizedDescription.contains("レスポンス:"))
        #expect(apiError.localizedDescription.contains("invalid token"))
    }

    @Test func sanitizedJSONRemovesInvalidControlCharactersInsideStrings() throws {
        let data =
            Data(#"{"programs":["正常"#.utf8)
            + Data([0x1D])
            + Data(#""]}"#.utf8)

        let sanitized = try #require(
            APIClient.sanitizedJSONByRemovingInvalidControlCharacters(from: data))
        let decoded = try JSONDecoder().decode(Payload.self, from: sanitized.data)

        #expect(sanitized.removedControlCharacterCount == 1)
        #expect(decoded.programs == ["正常"])
    }

    @Test func sanitizedJSONLeavesCleanPayloadUntouched() {
        let data = Data(#"{"programs":["正常"]}"#.utf8)

        let sanitized = APIClient.sanitizedJSONByRemovingInvalidControlCharacters(from: data)

        #expect(sanitized == nil)
    }
}
