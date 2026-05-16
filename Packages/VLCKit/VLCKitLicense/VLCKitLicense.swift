import Foundation

public enum VLCKitLicense {
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
}
