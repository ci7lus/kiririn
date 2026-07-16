import SwiftUI

struct CaptionHistoryView: View {
    @State var playerState: PlayerState

    var body: some View {
        let history = playerState.captionHistory.reversed()
        Group {
            if history.isEmpty {
                ContentUnavailableView(
                    "字幕履歴がありません",
                    systemImage: "captions.bubble",
                    description: Text("再生中に字幕が表示されると、ここに履歴が表示されます")
                )
            } else {
                List(history) { item in
                    captionRow(item)
                }
                .listStyle(.plain)
            }
        }
        #if !os(macOS)
            .background(Color.kiririnSystemBackground.ignoresSafeArea())
        #endif
        .navigationTitle("")
    }

    @ViewBuilder
    private func captionRow(_ item: CaptionHistoryItem) -> some View {
        if let broadcastTime = item.broadcastTime {
            HStack(alignment: .center, spacing: 12) {
                Text(formattedBroadcastTime(broadcastTime))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .leading)

                Text(item.text)
                    .font(.systemWithARIBFallback(.body))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    playerState.seek(to: item.position)
                } label: {
                    Text(item.time.playerTimeString)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: 52, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text(item.text)
                    .font(.systemWithARIBFallback(.body))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }

    private func formattedBroadcastTime(_ date: Date) -> String {
        Self.broadcastTimeFormatter.string(from: date)
    }

    private static let broadcastTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
