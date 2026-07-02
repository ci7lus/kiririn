import Foundation
import Testing

@testable import kiririn

struct APIClientDiagnosticsTests {

    private struct Payload: Decodable {
        let programs: [String]
    }

    @Test func decodingDiagnosticReportsJSONErrorIndexAndControlCharacterSnippet() {
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
            #expect(diagnostic.detail.contains("contentType=application/json"))
            #expect(diagnostic.detail.contains("errorIndex=\(expectedIndex)"))
            #expect(diagnostic.snippet?.contains("\\u{001D}") == true)
            #expect(diagnostic.snippet?.contains("[1D]") == true)
        }
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
