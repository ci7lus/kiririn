import Foundation

enum DataBroadcastSettings {
    static let enabledKey = "dataBroadcast.enabled"
    static let postalCodeKey = "dataBroadcast.receiverInfo.postalCode"
    static let internetAccessKey = "dataBroadcast.internetAccess"

    /// 通信コンテンツ(データ放送のインターネット接続機能)を許可するか。
    /// コンテンツが放送局などの外部サーバーへHTTP接続するためデフォルトOFF。
    static func internetAccessEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: internetAccessKey)
    }

    static func postalCode(in defaults: UserDefaults = .standard) -> String? {
        validatedPostalCode(defaults.string(forKey: postalCodeKey))
    }

    static func setPostalCode(_ postalCode: String?, in defaults: UserDefaults = .standard) {
        if let postalCode = validatedPostalCode(postalCode) {
            defaults.set(postalCode, forKey: postalCodeKey)
        } else {
            defaults.removeObject(forKey: postalCodeKey)
        }
    }

    static func validatedPostalCode(_ postalCode: String?) -> String? {
        guard let postalCode, postalCode.count == 7,
            postalCode.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return postalCode
    }
}
