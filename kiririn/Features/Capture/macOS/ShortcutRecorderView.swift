#if os(macOS)
    import SwiftUI
    import AppKit

    struct ShortcutRecorderView: View {
        @Binding var keyCode: Int
        @Binding var modifiers: Int
        @Binding var isRecording: Bool

        var body: some View {
            Button {
                isRecording.toggle()
            } label: {
                HStack(spacing: 8) {
                    if isRecording {
                        Text("キーを押してください...")
                            .foregroundStyle(.blue)
                    } else {
                        if keyCode >= 0 {
                            Text(
                                GlobalCaptureHotKeyManager.shortcutDisplayString(
                                    keyCode: UInt16(keyCode),
                                    modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
                                ))
                        } else {
                            Text("未設定")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 160)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isRecording ? Color.blue : Color.secondary.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .overlay {
                if isRecording {
                    GlobalHotKeyCaptureView { newKeyCode, newModifiers in
                        self.keyCode = Int(newKeyCode)
                        self.modifiers = Int(
                            GlobalCaptureHotKeyManager.normalizedModifierFlags(newModifiers)
                                .rawValue)
                        self.isRecording = false
                    }
                    .frame(width: 0, height: 0)
                    .opacity(0)
                }
            }
        }
    }

    private struct GlobalHotKeyCaptureView: NSViewRepresentable {
        let onCapture: (_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Void

        func makeNSView(context: Context) -> GlobalHotKeyRecorderNSView {
            let view = GlobalHotKeyRecorderNSView()
            view.onCapture = onCapture
            return view
        }

        func updateNSView(_ nsView: GlobalHotKeyRecorderNSView, context: Context) {
            nsView.onCapture = onCapture
            if let window = nsView.window {
                window.makeFirstResponder(nsView)
            }
        }
    }

    private final class GlobalHotKeyRecorderNSView: NSView {
        var onCapture: ((_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            onCapture?(event.keyCode, event.modifierFlags)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            onCapture?(event.keyCode, event.modifierFlags)
            return true
        }
    }
#endif
