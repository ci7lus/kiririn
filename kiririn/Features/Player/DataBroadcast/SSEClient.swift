import Foundation
import Logging

nonisolated struct SSEEvent: Sendable {
    let event: String
    /// Raw payload text for this event (already valid JSON in Mahiron's case),
    /// exactly as sent - not decoded here so callers can both forward it
    /// verbatim and decode it themselves.
    let data: String
}

nonisolated enum SSEClientError: Error, Sendable {
    case httpError(statusCode: Int)
}

/// Minimal Server-Sent Events reader. Only `event:`/`data:` fields are
/// handled; multi-line `data:` fields are joined with `\n` per the SSE spec.
/// Mahiron sends `id:` (its per-service event sequence) but doesn't support
/// resuming from `Last-Event-ID` - every connection starts with an
/// authoritative `snapshot` event instead - so the id is ignored.
///
/// Lines are split manually from the byte stream instead of via
/// `AsyncBytes.lines`: `AsyncLineSequence` skips empty lines, and SSE uses
/// the empty line as the event delimiter - with `.lines`, no event would
/// ever be dispatched.
nonisolated final class SSEClient: Sendable {
    private let session: URLSession
    private let logger = Logger(label: "SSEClient")

    init() {
        let config = URLSessionConfiguration.default
        // SSE connections are long-lived for as long as the player keeps the
        // service tuned; don't let URLSession's default request/resource
        // timeouts tear the stream down mid-broadcast.
        config.timeoutIntervalForRequest = 60 * 60 * 24
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    func events(url: URL, headers: [String: String]) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [logger, session] in
                do {
                    var request = URLRequest(url: url)
                    for (key, value) in headers {
                        request.setValue(value, forHTTPHeaderField: key)
                    }
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse {
                        guard (200...299).contains(http.statusCode) else {
                            continuation.finish(
                                throwing: SSEClientError.httpError(statusCode: http.statusCode))
                            return
                        }
                        logger.info("SSE stream opened (status \(http.statusCode)): \(url)")
                    }

                    var lineBuffer = Data()
                    var eventName = "message"
                    var dataLines: [String] = []

                    func processLine(_ lineData: Data) {
                        var lineData = lineData
                        if lineData.last == 0x0D {  // strip CR of CRLF
                            lineData.removeLast()
                        }
                        let line = String(decoding: lineData, as: UTF8.self)
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                continuation.yield(
                                    SSEEvent(
                                        event: eventName, data: dataLines.joined(separator: "\n")))
                            }
                            eventName = "message"
                            dataLines = []
                            return
                        }
                        if line.hasPrefix(":") {
                            return
                        }
                        guard let colonIndex = line.firstIndex(of: ":") else {
                            return
                        }
                        let field = line[line.startIndex..<colonIndex]
                        var value = String(line[line.index(after: colonIndex)...])
                        if value.hasPrefix(" ") {
                            value.removeFirst()
                        }
                        switch field {
                        case "event":
                            eventName = value
                        case "data":
                            dataLines.append(value)
                        default:
                            break
                        }
                    }

                    for try await byte in bytes {
                        if byte == 0x0A {  // LF: line complete
                            try Task.checkCancellation()
                            processLine(lineBuffer)
                            lineBuffer.removeAll(keepingCapacity: true)
                        } else {
                            lineBuffer.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func cancelAll() {
        session.invalidateAndCancel()
    }
}
