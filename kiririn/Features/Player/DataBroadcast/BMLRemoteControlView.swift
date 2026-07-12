import SwiftUI

/// データ放送用のオンスクリーンリモコン(BMLRemotePanelControllerの
/// フローティングパネルに載る)。キーボードを介さずにARIBキーをBML
/// コンテンツへ直接送るため、プレイヤー側ショートカットと競合しない。
/// 各キーはコンテンツがusedKeyListで宣言したグループに応じて有効化される
/// (dボタンのみ常時有効 - コンテンツはinvisible状態から起動されるため)。
struct BMLRemoteControlView: View {
    enum Layout {
        case panel
        case tab
    }

    let playerState: PlayerState
    var layout: Layout = .panel
    var showsDataButton = true

    private let spacing: CGFloat = 10
    private var buttonHeight: CGFloat { layout == .tab ? 38 : 26 }
    private var buttonFontSize: CGFloat { layout == .tab ? 16 : 12 }
    private var directionalButtonWidth: CGFloat { layout == .tab ? 72 : 52 }

    private var session: DataBroadcastSession? { playerState.dataBroadcastSession }
    private var usedKeyGroups: Set<String> { session?.usedKeyGroups ?? [] }
    private var basicEnabled: Bool {
        playerState.bmlContentVisible && usedKeyGroups.contains("basic")
    }
    private var colorEnabled: Bool {
        playerState.bmlContentVisible && usedKeyGroups.contains("data-button")
    }
    private var digitEnabled: Bool {
        playerState.bmlContentVisible && usedKeyGroups.contains("numeric-tuning")
    }

    var body: some View {
        VStack(spacing: spacing) {
            dataButtonRow
            arrowPad
            colorButtonRow
            digitGrid
        }
        .padding(12)
        .frame(
            minWidth: layout == .panel ? 196 : nil,
            maxWidth: layout == .tab ? .infinity : 196
        )
    }

    private var dataButtonRow: some View {
        HStack(spacing: 8) {
            if showsDataButton {
                remoteKey(enabled: playerState.bmlAvailable, help: "d") {
                    playerState.pressBMLDataButton()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "d.circle\(playerState.bmlContentVisible ? ".fill" : "")")
                        Text("データ")
                    }
                }
            }
            remoteKey(enabled: basicEnabled, help: "Delete / Esc") {
                press(19)  // Back
            } label: {
                Text("戻る")
            }
        }
    }

    private var arrowPad: some View {
        VStack(spacing: 6) {
            arrowKey("chevron.up", code: 1, help: "⌥↑")
            HStack(spacing: 6) {
                arrowKey("chevron.left", code: 3, help: "⌥←")
                remoteKey(enabled: basicEnabled, help: "Return") {
                    press(18)  // Enter
                } label: {
                    Text("決定")
                }
                .frame(width: directionalButtonWidth)
                arrowKey("chevron.right", code: 4, help: "⌥→")
            }
            arrowKey("chevron.down", code: 2, help: "⌥↓")
        }
        .frame(maxWidth: layout == .tab ? 360 : nil)
        .frame(maxWidth: .infinity)
    }

    private func arrowKey(_ systemImage: String, code: Int, help: String) -> some View {
        remoteKey(enabled: basicEnabled, help: help) {
            press(code)
        } label: {
            Image(systemName: systemImage)
        }
        .frame(width: directionalButtonWidth)
        .buttonRepeatBehavior(.enabled)
    }

    private var colorButtonRow: some View {
        HStack(spacing: 6) {
            colorKey("青", color: .blue, code: 21, help: "b")
            colorKey("赤", color: .red, code: 22, help: "r")
            colorKey("緑", color: .green, code: 23, help: "g")
            colorKey("黄", color: .yellow, code: 24, help: "y")
        }
    }

    private func colorKey(_ label: String, color: Color, code: Int, help: String) -> some View {
        Button {
            press(code)
        } label: {
            Text(label)
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(color.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!colorEnabled)
        .opacity(colorEnabled ? 1 : 0.35)
        .help(help)
    }

    private var digitGrid: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<4) { row in
                GridRow {
                    ForEach(1..<4) { column in
                        digitKey(row * 3 + column)
                    }
                }
            }
        }
    }

    private func digitKey(_ number: Int) -> some View {
        // AribKeyCode: Digit0=5...Digit9=14, Digit10=15, Digit11=16, Digit12=17
        remoteKey(
            enabled: digitEnabled,
            help: number <= 9 ? "\(number)" : nil
        ) {
            press(number <= 9 ? 5 + number : 15 + (number - 10))
        } label: {
            Text("\(number)")
        }
        .frame(maxWidth: .infinity)
    }

    private func remoteKey(
        enabled: Bool,
        help: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: buttonFontSize, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help.map { "キー: \($0)" } ?? "")
    }

    private func press(_ aribKeyCode: Int) {
        guard let session else { return }
        session.sendKey(down: true, aribKeyCode: aribKeyCode)
        session.sendKey(down: false, aribKeyCode: aribKeyCode)
    }
}
