import SwiftUI

struct DataBroadcastSettingsView: View {
    @AppStorage(DataBroadcastSettings.enabledKey) private var isDataBroadcastEnabled = false
    @AppStorage(DataBroadcastSettings.internetAccessKey) private var isInternetAccessEnabled =
        false
    @AppStorage(DataBroadcastSettings.receivingIndicatorKey)
    private var isReceivingIndicatorEnabled = DataBroadcastSettings.receivingIndicatorDefault
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
                    "利用には[Mahiron](https://github.com/rokoucha/Mahiron)のデータ放送用拡張APIが必要です。"
                )
            }
            Section {
                Toggle("データ取得中の表示", isOn: $isReceivingIndicatorEnabled)
            } header: {
                Text("表示")
            } footer: {
                Text(
                    "モジュールの取得中や通信中に、受信機と同じ「データ取得中...」「通信中...」を画面右下へ表示します。"
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
