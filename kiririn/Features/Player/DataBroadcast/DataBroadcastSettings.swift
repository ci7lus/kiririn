import Foundation

enum DataBroadcastSettings {
    static let enabledKey = "dataBroadcast.enabled"
    static let postalCodeKey = "dataBroadcast.receiverInfo.postalCode"

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
