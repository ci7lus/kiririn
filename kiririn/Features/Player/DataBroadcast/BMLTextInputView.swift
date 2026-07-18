import SwiftUI

struct BMLTextInputView: View {
    let request: DataBroadcastSession.InputRequest
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(
        request: DataBroadcastSession.InputRequest,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: request.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文字入力")
                .font(.headline)

            inputField
                .focused($isFocused)

            HStack {
                Text(inputDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if request.maxLength > 0 {
                    Text("最大\(request.maxLength)文字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("決定") { onSubmit(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.15))
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
        .task(id: request.id) {
            isFocused = true
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if request.isSecure {
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(text) }
        } else if request.isMultiline {
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        } else {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(text) }
        }
    }

    private var inputDescription: String {
        switch request.characterType {
        case "number": "半角数字"
        case "alphabet": "半角英字・記号"
        case "hankaku": "半角英数字・記号"
        case "zenkaku": "全角文字"
        case "katakana": "全角カタカナ"
        case "hiragana": "ひらがな"
        default: "文字を入力してください"
        }
    }
}
