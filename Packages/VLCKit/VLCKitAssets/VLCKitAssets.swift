import Foundation

public enum VLCKitAssets {
    public static let name = "VLCKit"
    public static let homepageURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!

    public static var text: String {
        guard let url = Bundle.module.url(forResource: "COPYING", withExtension: nil),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "ライセンスの取得に失敗しました"
        }
        return text
    }

    public static func resolveSofaPath(
        sofaName: String = "dodeca_and_7channel_3DSL_HRTF",
        sofaExtension: String = "sofa"
    ) -> String? {
        Bundle.module.path(
            forResource: sofaName,
            ofType: sofaExtension
        )
    }
}
