import Foundation

nonisolated enum RemoteControlCommand: Codable, Equatable, Sendable {
    case setPlaying(Bool)
    case seekToTime(Double)
    case skipBy(Double)
    case setRate(Float)
    case setVolume(Float)
    case setMuted(Bool)
    case selectAudioTrack(RemoteAudioTrackSelection?)
    case selectVideoTrack(String)
    case setSubtitleEnabled(Bool)
    case setPipEnabled(Bool)
    case takeCapture
    case setRecording(Bool)
    case reload
    case pressBMLKey(ARIBRemoteKey)
    case setFullscreen(Bool)
    case setAlwaysOnTop(Bool)
    case close
}

nonisolated struct RemotePlayerCommandRequest: Codable, Equatable, Sendable {
    let playerID: String
    let command: RemoteControlCommand
}

nonisolated enum RemoteCommandError: String, Codable, Equatable, Sendable {
    case playerNotFound
    case unsupported
    case invalidValue
    case unavailable
    case unauthorized
}

nonisolated struct RemoteCommandResponse: Codable, Equatable, Sendable {
    let requestID: UUID
    let error: RemoteCommandError?
}
