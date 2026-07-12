import Foundation

enum DataBroadcastSettings {
    static let enabledKey = "dataBroadcast.enabled"
    static let postalCodeKey = "dataBroadcast.receiverInfo.postalCode"
    static let internetAccessKey = "dataBroadcast.internetAccess"
    static let webStorageKey = "dataBroadcast.webStorage"

    /// web-bmlが郵便番号NVRAMに使うlocalStorageキー
    /// (web/bml/src/index.tsのpostalCodeStorageKeyと一致させること)。
    static let postalCodeStorageKey = "nvram_prefix=receiverinfo%2Fzipcode"

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

    // MARK: - Web storage mirror

    /// web-bmlのlocalStorage(NVRAM・放送局DB)のミラー。kiririn-bml://
    /// オリジンのlocalStorageはWebKitがディスクへ永続化しないため、書き込みを
    /// ここへミラーし、WKWebView生成時にユーザースクリプトでシードし直す。

    static func webStorage(in defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: webStorageKey) as? [String: String]) ?? [:]
    }

    static func setWebStorageItem(
        key: String, value: String?, in defaults: UserDefaults = .standard
    ) {
        var storage = webStorage(in: defaults)
        storage[key] = value
        defaults.set(storage, forKey: webStorageKey)
        // 郵便番号は設定UIにも表示するので、NVRAM側の変更を設定値へ同期する。
        if key == postalCodeStorageKey {
            setPostalCode(value.flatMap(postalCode(fromStorageValue:)), in: defaults)
        }
    }

    /// NVRAMのzipcodeエントリ(7桁数字のbase64)を郵便番号へ復号する。
    static func postalCode(fromStorageValue value: String) -> String? {
        guard let data = Data(base64Encoded: value),
            let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        return validatedPostalCode(decoded)
    }
}
