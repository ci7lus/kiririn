import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct SettingsView: View {
    let configStore: BackendConfigStore
    let manager: BackendManager
    let appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    @ObservedObject private var captureService = CaptureService.shared
    @State private var isFolderPickerPresented = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CaptureSettingsView(appModel: appModel)
                } label: {
                    Label("キャプチャ設定", systemImage: "photo.on.rectangle.angled")
                }

                NavigationLink {
                    BackendSettingsView(
                        configStore: configStore,
                        manager: manager
                    )
                } label: {
                    Label("バックエンド設定", systemImage: "server.rack")
                }

                NavigationLink {
                    PluginSettingsView(
                        appModel: appModel, pluginStore: pluginStore, playerState: playerState)
                } label: {
                    Label("プラグイン設定", systemImage: "puzzlepiece.extension")
                }

                NavigationLink {
                    AboutAppView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
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
}
