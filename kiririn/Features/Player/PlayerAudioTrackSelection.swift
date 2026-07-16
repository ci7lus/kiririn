nonisolated struct PlayerAudioTrackSelection: Hashable, Sendable {
    private enum Kind: Hashable, Sendable {
        case regular
        case dualMono(DualMonoRole)
    }

    enum DualMonoRole: Hashable, Sendable {
        case main
        case sub

        var displayName: String {
            switch self {
            case .main: "主音声"
            case .sub: "副音声"
            }
        }

        var stereoMode: PlayerAudioStereoMode {
            switch self {
            case .main: .left
            case .sub: .right
            }
        }

        init?(stereoMode: PlayerAudioStereoMode) {
            switch stereoMode {
            case .left: self = .main
            case .right: self = .sub
            default: return nil
            }
        }
    }

    let track: PlayerAudioTrack
    private let kind: Kind

    var dualMonoRole: DualMonoRole? {
        guard case .dualMono(let role) = kind else { return nil }
        return role
    }

    var stereoMode: PlayerAudioStereoMode? {
        dualMonoRole?.stereoMode
    }

    static func options(for track: PlayerAudioTrack) -> [Self] {
        if track.isDualMono {
            return [
                Self(track: track, kind: .dualMono(.main)),
                Self(track: track, kind: .dualMono(.sub)),
            ]
        }
        return [Self(track: track, kind: .regular)]
    }

    static func current(
        track: PlayerAudioTrack,
        stereoMode: PlayerAudioStereoMode
    ) -> Self {
        guard track.isDualMono else {
            return Self(track: track, kind: .regular)
        }
        guard let role = DualMonoRole(stereoMode: stereoMode) else {
            return Self(track: track, kind: .dualMono(.main))
        }
        return Self(track: track, kind: .dualMono(role))
    }
}
