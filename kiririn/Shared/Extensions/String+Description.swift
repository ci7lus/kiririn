import Foundation

extension String {
    /// 複数行テキストの各行をトリムし空行を除去して半角スペースで結合する
    var compactedLines: String {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
