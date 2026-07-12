import Foundation

nonisolated struct BMLTuneRequest: Equatable, Sendable {
    let originalNetworkId: Int
    let transportStreamId: Int
    let serviceId: Int

    init?(bridgeMessage: [String: Any]) {
        guard let originalNetworkId = bridgeMessage["originalNetworkId"] as? Int,
            let transportStreamId = bridgeMessage["transportStreamId"] as? Int,
            let serviceId = bridgeMessage["serviceId"] as? Int,
            UInt16(exactly: originalNetworkId) != nil,
            UInt16(exactly: transportStreamId) != nil,
            UInt16(exactly: serviceId) != nil
        else { return nil }

        self.originalNetworkId = originalNetworkId
        self.transportStreamId = transportStreamId
        self.serviceId = serviceId
    }

    func matches(_ service: TVService) -> Bool {
        service.networkId == originalNetworkId
            && service.transportStreamId == transportStreamId
            && service.serviceId == serviceId
    }
}

// MARK: - Mahiron SSE payload shapes (minimal - only what's needed to schedule
// module fetches; the JS adapter re-parses the full raw JSON independently,
// see web/bml/src/mahiron.ts). All Mahiron JSON knowledge that isn't purely
// pass-through lives in these two places by design (kiririn-plugin.md plan).

nonisolated struct MahironModule: Decodable, Sendable {
    let componentTag: Int
    let moduleId: Int
    let downloadId: UInt32
    let version: Int
    let size: Int
    /// DII moduleInfo descriptor bytes for this module. Go's `encoding/json`
    /// marshals `[]byte` as base64 (or null when empty), and Foundation's
    /// JSONDecoder decodes a `Data` field from a base64 string by default -
    /// no manual decode step.
    let info: Data?
    let complete: Bool
    let etag: String?
}

nonisolated struct MahironComponent: Decodable, Sendable {
    let componentTag: Int
    let modules: [MahironModule]
}

nonisolated struct MahironPMT: Decodable, Sendable {
    let components: [MahironComponent]?
}

nonisolated struct MahironModuleList: Decodable, Sendable {
    let componentTag: Int
    let downloadId: UInt32
    let modules: [MahironModule]
}

nonisolated struct MahironSnapshot: Decodable, Sendable {
    let pmt: MahironPMT?
    let components: [MahironComponent]?
}

// Mahiron wraps each SSE `data:` payload in a per-type envelope:
// `{"type":"snapshot","snapshot":{...}}`, `{"type":"pmt","pmt":{...}}`,
// `{"type":"moduleListUpdated","moduleList":{...}}`,
// `{"type":"moduleUpdated","module":{...}}` (see apiDataBroadcastEvent in
// Mahiron's internal/web/api/data_broadcast.go). These decode that envelope.

nonisolated struct MahironSnapshotEnvelope: Decodable, Sendable {
    let snapshot: MahironSnapshot?
}

nonisolated struct MahironPMTEnvelope: Decodable, Sendable {
    let pmt: MahironPMT?
}

nonisolated struct MahironModuleListEnvelope: Decodable, Sendable {
    let moduleList: MahironModuleList?
}

nonisolated struct MahironModuleEnvelope: Decodable, Sendable {
    let module: MahironModule?
}

// MARK: - Native -> Web bridge payloads
// Mirrors web-bml/server/ws_api.ts's ProgramInfoMessage exactly (field names
// and all) so it can be forwarded to `bmlBrowser.emitMessage` unchanged by
// the JS adapter - see web/bml/src/types.ts's NativeToWebMessage.

nonisolated struct BMLProgramInfoPayload: Encodable, Sendable {
    let type = "programInfo"
    let originalNetworkId: Int?
    let transportStreamId: Int?
    let serviceId: Int?
    let eventId: Int?
    let eventName: String?
    let startTimeUnixMillis: Double?
    let durationSeconds: Double?
    let indefiniteDuration: Bool?
    let networkId: Int?
}
