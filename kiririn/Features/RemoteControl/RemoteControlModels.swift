import Foundation

nonisolated enum RemoteControlCapability: String, Codable, Hashable, Sendable {
    case playback
    case seek
    case rate
    case volume
    case audioTrack
    case videoTrack
    case subtitle
    case pictureInPicture
    case capture
    case recording
    case reload
    case dataBroadcast
    case fullscreen
    case alwaysOnTop
    case close
}

nonisolated struct RemoteControlTrack: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String?
}

nonisolated struct RemotePlayerSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let serviceName: String?
    let isPlaying: Bool
    let isSeekable: Bool
    let time: Double
    let duration: Double
    let rate: Float
    let volume: Float
    let isMuted: Bool
    let isRecording: Bool
    let isSubtitleEnabled: Bool
    let isPipEnabled: Bool
    let isFullscreen: Bool?
    let isAlwaysOnTop: Bool?
    let capabilities: Set<RemoteControlCapability>
    let audioTracks: [RemoteControlAudioTrackOption]
    let selectedAudioTrackSelection: RemoteAudioTrackSelection?
    let videoTracks: [RemoteControlTrack]
    let selectedVideoTrackID: String?
    let bmlKeyGroups: Set<BMLKeyGroup>
}

nonisolated struct RemoteTrustedPeer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String
    let publicKey: Data
    let pairedAt: Date
}

nonisolated struct RemoteDiscoveredPeer: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

nonisolated struct RemotePairingRequest: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
}

nonisolated enum RemoteConnectionStatus: Equatable, Sendable {
    case idle
    case browsing
    case connecting(String)
    case pairing(String)
    case connected(String)
    case failed(String)
}

nonisolated struct RemoteWindowSnapshot: Equatable, Sendable {
    let isFullscreen: Bool
    let isAlwaysOnTop: Bool
}
