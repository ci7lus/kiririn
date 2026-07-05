import SwiftUI

struct CaptionWindowView_macOS: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if let playerState = appModel.focusedPlayerState {
                CaptionHistoryView(playerState: playerState)
                    .id(playerState.id)
            } else {
                ContentUnavailableView(
                    "プレイヤーがありません",
                    systemImage: "captions.bubble",
                    description: Text("プレイヤーウィンドウをフォーカスすると、字幕履歴が表示されます")
                )
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .navigationTitle("字幕履歴")
    }
}
