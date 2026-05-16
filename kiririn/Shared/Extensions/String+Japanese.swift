import Foundation

extension String {
    /// 日本語検索向けに正規化する（大文字小文字・全角半角・アクセント記号を無視）
    func normalizedForJapaneseSearch() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ja_JP"))
    }
}
