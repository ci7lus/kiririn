#if os(macOS)
    import SwiftUI

    struct CaptionWindowView_macOS: View {
        let appModel: AppModel

        var body: some View {
            Group {
                if let playerState = appModel.focusedPlayerState {
                    CaptionHistoryView(playerState: playerState)
                        .id(playerState.id)
                } else {
                    ContentUnavailableView(
                        "プレイヤーなし",
                        systemImage: "captions.bubble",
                        description: Text("プレイヤーウィンドウをフォーカスすると字幕履歴が表示されます")
                    )
                }
            }
            .frame(minWidth: 320, minHeight: 240)
            .navigationTitle("字幕履歴")
        }
    }
#endif
