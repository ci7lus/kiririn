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

/// BMLコンテンツからの音声ES切替 (object.setMainAudioStream)。JS側が最新PMT
/// からコンポーネントタグを解決したPID(VLCのTrackId照合用)と、PMT内の音声ES
/// 中での序数(TrackId形式が想定外だったときのフォールバック)を添えてくる。
nonisolated struct BMLAudioStreamRequest: Equatable, Sendable {
    let componentId: Int
    /// デュアルモノの音声チャンネル指定 (TR-B14: 1=主, 2=副, 3=主+副)。
    let channelId: Int?
    let pid: Int?
    let audioIndex: Int?

    init?(bridgeMessage: [String: Any]) {
        guard let componentId = bridgeMessage["componentId"] as? Int else { return nil }
        self.componentId = componentId
        self.channelId = bridgeMessage["channelId"] as? Int
        self.pid = bridgeMessage["pid"] as? Int
        self.audioIndex = bridgeMessage["audioIndex"] as? Int
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
    let complete: Bool
    /// `announced` / `receiving` / `complete` / `rejected`. A rejected module
    /// was refused by Mahiron's receiver (resource limits, unsupported
    /// carousel) and will never become fetchable - see `rejectionReason`.
    let status: String?
    let rejectionReason: String?
}

// MARK: - Mahiron module resource manifest
// Mahiron expands a completed DSM-CC module into logical BML resources
// server-side (zlib, multipart entities, Type-descriptor direct mapping) and
// serves each one under the module's immutable version URL.

nonisolated struct MahironModuleResource: Decodable, Sendable {
    let id: String
    let contentLocation: String?
    let contentType: String
}

nonisolated struct MahironModuleManifest: Decodable, Sendable {
    let componentTag: Int
    let moduleId: Int
    let downloadId: UInt32
    let version: Int
    let resources: [MahironModuleResource]
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

/// One logical BML resource of a module, in the shape web-bml's `ModuleFile`
/// expects (`contentType` is re-parsed into a MediaType by the JS adapter).
nonisolated struct BMLModuleFile: Encodable, Sendable {
    let contentLocation: String?
    let contentType: String
    let dataBase64: String
}

nonisolated struct BMLModuleResourcesPayload: Encodable, Sendable {
    let type = "moduleResources"
    let componentTag: Int
    let moduleId: Int
    let downloadId: UInt32
    let version: Int
    let files: [BMLModuleFile]
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
