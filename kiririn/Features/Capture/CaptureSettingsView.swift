import SwiftUI
import UniformTypeIdentifiers

struct CaptureSettingsView: View {
    let appModel: AppModel
    @ObservedObject private var captureService = CaptureService.shared
    @State private var isFolderPickerPresented = false
    @State private var isShowingClearAllAlert = false

    #if os(macOS)
        @AppStorage(GlobalCaptureHotKeyManager.defaultsKeyCodeKey) private
            var globalCaptureHotKeyKeyCode = -1
        @AppStorage(GlobalCaptureHotKeyManager.defaultsModifiersKey) private
            var globalCaptureHotKeyModifiers = 0
        @State private var isCapturingGlobalCaptureHotKey = false
    #endif

    var body: some View {
        Form {
            Section("保存設定") {
                #if os(macOS)
                    LabeledContent("保存先") {
                        HStack(spacing: 4) {
                            Text(captureService.captureFolder?.path ?? "App Sandbox (デフォルト)")
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                                .truncationMode(.middle)

                            Button("変更") {
                                isFolderPickerPresented = true
                            }

                            if captureService.isExternalFolderSelected {
                                Button("デフォルトに戻す") {
                                    captureService.resetToSandbox()
                                }
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                #else
                    Toggle("iCloudバックアップに含める", isOn: $captureService.shouldIncludeIniCloudBackup)
                #endif
                Toggle("キャプチャをクリップボードにコピーする", isOn: $captureService.shouldCopyCaptureToClipboard)
                Toggle("キャプチャにプラグイン領域を合成する", isOn: $captureService.shouldCompositePluginOverlay)

                if captureService.shouldCopyCaptureToClipboard
                    && captureService.shouldCompositePluginOverlay
                {
                    Picker("コピーするイメージ", selection: $captureService.clipboardTarget) {
                        ForEach(CaptureClipboardTarget.allCases, id: \.self) { target in
                            Text(target.localizedName).tag(target)
                        }
                    }
                }

                HStack {
                    Text("履歴を消去")
                    Spacer()
                    Button(role: .destructive) {
                        isShowingClearAllAlert = true
                    } label: {
                        Text("消去")
                    }
                }
            }

            #if os(macOS)
                Section("グローバルキャプチャキー") {
                    LabeledContent("キーコンビネーション") {
                        HStack(spacing: 8) {
                            ShortcutRecorderView(
                                keyCode: $globalCaptureHotKeyKeyCode,
                                modifiers: $globalCaptureHotKeyModifiers,
                                isRecording: $isCapturingGlobalCaptureHotKey
                            )

                            if globalCaptureHotKeyKeyCode >= 0 {
                                Button {
                                    clearGlobalCaptureHotKey()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("ショートカットをクリア")
                            }
                        }
                    }
                }
            #endif
        }
        .navigationTitle("キャプチャ設定")
        #if os(macOS)
            .formStyle(.grouped)
            .onAppear {
                appModel.refreshGlobalCaptureHotKey()
            }
            .onChange(of: globalCaptureHotKeyKeyCode) { _, _ in
                appModel.refreshGlobalCaptureHotKey()
            }
            .onChange(of: globalCaptureHotKeyModifiers) { _, _ in
                appModel.refreshGlobalCaptureHotKey()
            }
        #endif
        .alert("履歴の消去", isPresented: $isShowingClearAllAlert) {
            Button("キャンセル", role: .cancel) {}
            Button("全て消去", role: .destructive) {
                Task {
                    await captureService.clearHistory()
                }
            }
        } message: {
            Text("本当に全てのキャプチャ履歴を消去しますか? この操作は元に戻せません。")
        }
        .fileImporter(
            isPresented: $isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    do {
                        try captureService.setCaptureFolder(url)
                    } catch {
                        print("Failed to set folder: \(error)")
                    }
                }
            case .failure(let error):
                print("Folder selection failed: \(error)")
            }
        }
    }

    #if os(macOS)
        private func clearGlobalCaptureHotKey() {
            globalCaptureHotKeyKeyCode = -1
            globalCaptureHotKeyModifiers = 0
            isCapturingGlobalCaptureHotKey = false
        }
    #endif
}
