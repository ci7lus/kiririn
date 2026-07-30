import SwiftUI

/// データ放送用のオンスクリーンリモコン(BMLRemotePanelControllerの
/// フローティングパネルに載る)。共有のキー配置をPlayerStateへ接続する。
struct BMLRemoteControlView: View {
    typealias Layout = BMLRemoteControlPad.Layout

    let playerState: PlayerState
    var layout: Layout = .panel
    var showsDataButton = true

    var body: some View {
        BMLRemoteControlPad(
            layout: layout,
            availability: BMLRemoteControlAvailability(
                isDataButtonEnabled: playerState.bmlAvailable,
                enabledGroups: playerState.bmlContentVisible ? usedKeyGroups : []
            ),
            showsDataButton: showsDataButton
        ) { key in
            _ = playerState.pressBMLKey(key)
        }
    }

    private var usedKeyGroups: Set<BMLKeyGroup> {
        Set(
            playerState.dataBroadcastSession?.usedKeyGroups.compactMap(
                BMLKeyGroup.init(rawValue:)
            ) ?? []
        )
    }
}
