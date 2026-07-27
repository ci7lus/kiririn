nonisolated struct RemoteControlAudioTrackOption: Codable, Equatable, Identifiable, Sendable {
    let selection: RemoteAudioTrackSelection
    let label: String

    var id: RemoteAudioTrackSelection {
        selection
    }
}
