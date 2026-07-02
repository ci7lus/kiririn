import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct SettingsView: View {
    let configStore: ServerConfigStore
    let manager: ServerManager
    let appModel: AppModel
    @State var pluginStore: PluginStore
    @State var playerState: PlayerState
    @ObservedObject private var captureService = CaptureService.shared
    @State private var isFolderPickerPresented = false
    @Environment(\.isTabActive) private var isTabActive

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServerSettingsView(
                        configStore: configStore,
                        manager: manager
                    )
                } label: {
                    Label("サーバー設定", systemImage: "server.rack")
                }

                NavigationLink {
                    PluginsSettingsView(
                        appModel: appModel, pluginStore: pluginStore, playerState: playerState)
                } label: {
                    Label("プラグイン設定", systemImage: "puzzlepiece.extension")
                }

                NavigationLink {
                    CaptureSettingsView(appModel: appModel)
                } label: {
                    Label("キャプチャ設定", systemImage: "photo.on.rectangle.angled")
                }

                NavigationLink {
                    AboutAppView()
                } label: {
                    Label("このアプリについて", systemImage: "info.circle")
                }
            }

        }
        .formStyle(.grouped)
        .navigationTitle(isTabActive ? "設定" : "")
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
