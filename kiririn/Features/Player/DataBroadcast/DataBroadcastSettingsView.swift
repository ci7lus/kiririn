import SwiftUI

struct DataBroadcastSettingsView: View {
    @AppStorage(DataBroadcastSettings.enabledKey) private var isDataBroadcastEnabled = false
    @State private var postalCode = ""

    private var isPostalCodeValid: Bool {
        postalCode.isEmpty || DataBroadcastSettings.validatedPostalCode(postalCode) != nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("データ放送を有効にする", isOn: $isDataBroadcastEnabled)
            } footer: {
                Text(
                    "実験的機能です。Mirakurun互換サーバーのライブ視聴でのみ動作し、対応していないサーバーでは何も起こりません。"
                )
            }
            Section {
                TextField("郵便番号（7桁）", text: $postalCode)
                    .onChange(of: postalCode) { _, newValue in
                        guard
                            newValue.isEmpty
                                || DataBroadcastSettings.validatedPostalCode(newValue) != nil
                        else { return }
                        DataBroadcastSettings.setPostalCode(newValue)
                    }
            } header: {
                Text("受信機情報")
            } footer: {
                if isPostalCodeValid {
                    Text("天気など地域情報を利用するデータ放送へ提供します。")
                } else {
                    Text("郵便番号は半角数字7桁で入力してください。")
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            postalCode = DataBroadcastSettings.postalCode() ?? ""
        }
        .navigationTitle("データ放送設定")
        #if os(macOS)
            .formStyle(.grouped)
        #endif
    }
}
