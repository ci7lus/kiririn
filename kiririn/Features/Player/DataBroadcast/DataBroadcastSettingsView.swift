import SwiftUI

struct DataBroadcastSettingsView: View {
    @AppStorage(DataBroadcastSettings.enabledKey) private var isDataBroadcastEnabled = false
    @AppStorage(DataBroadcastSettings.internetAccessKey) private var isInternetAccessEnabled =
        false
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
                Toggle("インターネット接続を許可", isOn: $isInternetAccessEnabled)
            } header: {
                Text("通信")
            } footer: {
                Text(
                    "データ放送コンテンツが放送局などのサーバーと通信できるようになります（通信コンテンツ）。視聴中の番組に関する情報が外部へ送信されることがあります。変更は次の選局から反映されます。"
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
