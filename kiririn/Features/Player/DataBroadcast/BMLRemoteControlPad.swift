import SwiftUI

/// プレイヤー内と遠隔操作画面で共用するデータ放送リモコン。
/// キー送信先は呼び出し側が注入し、このViewは配置と有効状態だけを扱う。
struct BMLRemoteControlPad: View {
    enum Layout {
        case panel
        case touch
    }

    let layout: Layout
    let availability: BMLRemoteControlAvailability
    var showsDataButton = true
    let onPress: (ARIBRemoteKey) -> Void

    private var buttonHeight: CGFloat {
        switch layout {
        case .panel:
            26
        case .touch:
            44
        }
    }

    private var buttonFontSize: CGFloat {
        switch layout {
        case .panel:
            12
        case .touch:
            16
        }
    }

    private var directionalButtonWidth: CGFloat? {
        switch layout {
        case .panel:
            52
        case .touch:
            nil
        }
    }

    private var cornerRadius: CGFloat {
        layout == .touch ? 10 : 6
    }

    var body: some View {
        VStack(spacing: 10) {
            dataButtonRow
            arrowPad
            colorButtonRow
            digitGrid
        }
        .padding(layout == .touch ? 0 : 12)
        .frame(
            minWidth: layout == .panel ? 196 : nil,
            maxWidth: layout == .panel ? 196 : .infinity
        )
    }

    private var dataButtonRow: some View {
        HStack(spacing: 8) {
            if showsDataButton {
                remoteKey(.data, help: "d") {
                    HStack(spacing: 4) {
                        Text("d").italic().bold()
                        Text("ボタン")
                    }
                }
                .accessibilityLabel("dボタン")
            }

            remoteKey(.back, help: "Delete / Esc") {
                Text("戻る")
            }
            .accessibilityLabel("戻る")
        }
    }

    private var arrowPad: some View {
        VStack(spacing: 6) {
            arrowKey("chevron.up", label: "上", key: .up, help: "⌥↑")
            HStack(spacing: 6) {
                arrowKey("chevron.left", label: "左", key: .left, help: "⌥←")
                remoteKey(.enter, help: "Return") {
                    Text("決定")
                }
                .frame(width: directionalButtonWidth)
                .accessibilityLabel("決定")
                arrowKey("chevron.right", label: "右", key: .right, help: "⌥→")
            }
            arrowKey("chevron.down", label: "下", key: .down, help: "⌥↓")
        }
        .frame(maxWidth: .infinity)
    }

    private func arrowKey(
        _ systemImage: String,
        label: String,
        key: ARIBRemoteKey,
        help: String
    ) -> some View {
        remoteKey(key, help: help) {
            Image(systemName: systemImage)
        }
        .frame(width: directionalButtonWidth)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private var colorButtonRow: some View {
        HStack(spacing: 6) {
            colorKey("青", color: .blue, key: .blue, help: "b")
            colorKey("赤", color: .red, key: .red, help: "r")
            colorKey("緑", color: .green, key: .green, help: "g")
            colorKey("黄", color: .yellow, key: .yellow, help: "y")
        }
    }

    private func colorKey(
        _ label: String,
        color: Color,
        key: ARIBRemoteKey,
        help: String
    ) -> some View {
        Button {
            onPress(key)
        } label: {
            Text(label)
                .font(.system(size: buttonFontSize, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(color.opacity(0.75), in: RoundedRectangle(cornerRadius: cornerRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!availability.isEnabled(key))
        .opacity(availability.isEnabled(key) ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(label)
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

    @ViewBuilder
    private func digitKey(_ number: Int) -> some View {
        if let key = ARIBRemoteKey.digit(number) {
            remoteKey(
                key,
                help: number <= 9 ? "\(number)" : nil
            ) {
                Text("\(number)")
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(number)")
        }
    }

    private func remoteKey(
        _ key: ARIBRemoteKey,
        help: String? = nil,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let isEnabled = availability.isEnabled(key)
        return Button {
            onPress(key)
        } label: {
            label()
                .font(.system(size: buttonFontSize, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(
                    Color.primary.opacity(layout == .touch ? 0.08 : 0.1),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .overlay {
                    if layout == .touch {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.secondary.opacity(0.3))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help.map { "キー: \($0)" } ?? "")
    }
}
