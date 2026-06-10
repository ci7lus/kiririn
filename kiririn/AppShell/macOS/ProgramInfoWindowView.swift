import SwiftUI

struct ProgramInfoWindowView_macOS: View {
    let appModel: AppModel

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
                        "番組情報なし",
                        systemImage: "info.circle",
                        description: Text("フォーカス中のプレイヤーで番組情報を取得できると、ここに表示されます")
                    )
                    .id(playerState.id)
                }
            } else {
                ContentUnavailableView(
                    "プレイヤーなし",
                    systemImage: "play.rectangle",
                    description: Text("プレイヤーウィンドウをフォーカスすると番組情報が表示されます")
                )
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}
