import SwiftUI

/// Toggle backing key mirrors the literal used in
/// PlayerState.setupDataBroadcastSessionIfNeeded() -
/// `UserDefaults.standard.bool(forKey:)` there, `@AppStorage` here; both
/// read/write the same `UserDefaults.standard` suite so they stay in sync.
struct DataBroadcastSettingsView: View {
    @AppStorage("dataBroadcast.enabled") private var isDataBroadcastEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("データ放送を有効にする", isOn: $isDataBroadcastEnabled)
            } footer: {
                Text(
                    "実験的機能です。Mirakurun互換サーバーのライブ視聴でのみ動作し、対応していないサーバーでは何も起こりません。"
                )
            }
        }
        .navigationTitle("データ放送設定")
        #if os(macOS)
            .formStyle(.grouped)
        #endif
    }
}
