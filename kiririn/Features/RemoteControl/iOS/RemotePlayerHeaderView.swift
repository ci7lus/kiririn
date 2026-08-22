#if os(iOS)
    import SwiftUI

    struct RemotePlayerHeaderView: View, Equatable {
        let player: RemotePlayerSnapshot

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.player.id == rhs.player.id
                && lhs.player.title == rhs.player.title
                && lhs.player.serviceName == rhs.player.serviceName
                && lhs.player.isRecording == rhs.player.isRecording
        }

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    BroadcastText(
                        player.title,
                        style: .headline,
                        weight: .semibold
                    )
                    .lineLimit(2)
                    if let serviceName = player.serviceName {
                        Text(serviceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if player.isRecording {
                    Label("録画中", systemImage: "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("録画中")
                }
            }
            .remoteControlCard()
        }
    }
#endif
