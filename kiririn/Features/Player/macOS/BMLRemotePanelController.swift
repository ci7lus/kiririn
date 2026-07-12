import AppKit
import SwiftUI

/// データ放送リモコン(BMLRemoteControlView)を独立したフローティング
/// パネルとして表示する。プレイヤーウィンドウに埋め込むと位置が固定されて
/// しまうため、好きな場所へ動かせる別ウィンドウにしている。
@MainActor
final class BMLRemotePanelController: NSObject, NSWindowDelegate {
    /// キーウィンドウに一切ならないパネル。パネルがキーを取るとプレイヤー
    /// ウィンドウ宛のキーイベントが来なくなり、BMLKeyMonitorが素通り・
    /// 未処理キーのbeepが鳴る。パネル上に文字入力は無いのでキー不要。
    private final class NonKeyPanel: NSPanel {
        override var canBecomeKey: Bool { false }
    }

    private let panel: NSPanel
    private let onUserClose: () -> Void

    private static let frameAutosaveName = "BMLRemoteControlPanel"

    init(playerState: PlayerState, onUserClose: @escaping () -> Void) {
        self.onUserClose = onUserClose
        let hosting = NSHostingController(
            rootView: BMLRemoteControlView(playerState: playerState)
        )
        let panel = NonKeyPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
        panel.title = "リモコン"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        self.panel = panel
        super.init()
        panel.delegate = self
    }

    func show(near playerWindow: NSWindow?) {
        let restored = panel.setFrameUsingName(Self.frameAutosaveName)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored {
            position(near: playerWindow)
        }
        panel.orderFront(nil)
    }

    func close() {
        // 呼び出し元が状態を畳んだあとの明示的なclose。windowWillClose経由で
        // onUserCloseが二重に走らないようdelegateを外してから閉じる。
        panel.delegate = nil
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        onUserClose()
    }

    private func position(near playerWindow: NSWindow?) {
        guard let playerFrame = playerWindow?.frame else {
            panel.center()
            return
        }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        var origin = NSPoint(
            x: playerFrame.maxX + 12,
            y: playerFrame.midY - size.height / 2
        )
        if let visible = (playerWindow?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(origin.x, visible.maxX - size.width)
            origin.x = max(origin.x, visible.minX)
            origin.y = min(origin.y, visible.maxY - size.height)
            origin.y = max(origin.y, visible.minY)
        }
        panel.setFrameOrigin(origin)
    }
}
