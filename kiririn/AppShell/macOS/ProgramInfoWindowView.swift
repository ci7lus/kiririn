import SwiftUI

struct ProgramInfoWindowView_macOS: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let playerState = appModel.focusedPlayerState {
                if let program = playerState.displayProgram {
                    ScrollView {
                        ProgramInfoContentView(
                            program: program,
                            serviceName: playerState.currentPlayable?.serviceName,
                            showsCopyContextMenu: true
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .id(playerState.id)
                } else {
                    ContentUnavailableView(
                        "番組情報がありません",
                        systemImage: "info.circle",
                        description: Text("フォーカス中のプレイヤーに番組情報があれば、ここに表示されます")
                    )
                    .id(playerState.id)
                }
            } else {
                ContentUnavailableView(
                    "プレイヤーがありません",
                    systemImage: "play.rectangle",
                    description: Text("プレイヤーウィンドウをフォーカスすると、番組情報が表示されます")
                )
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
