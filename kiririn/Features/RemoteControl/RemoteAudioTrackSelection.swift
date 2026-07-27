nonisolated struct RemoteAudioTrackSelection: Codable, Equatable, Hashable, Sendable {
    enum Role: String, Codable, Equatable, Hashable, Sendable {
        case main
        case sub
    }

    let trackID: String
    let role: Role?
}
