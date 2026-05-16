import Foundation

extension String {
    nonisolated func replacingARIBEnclosedGlyphsForDisplay() -> String {
        broadcastDisplaySegments()
            .map { $0.isEnclosed ? "【\($0.text)】" : $0.text }
            .joined()
    }

    nonisolated func broadcastDisplaySegments() -> [(text: String, isEnclosed: Bool)] {
        guard !isEmpty else { return [] }
        guard containsARIBEnclosedGlyphs else { return [(text: self, isEnclosed: false)] }

        var segments: [(text: String, isEnclosed: Bool)] = []
        var plainText = ""
        plainText.reserveCapacity(utf16.count)

        func flushPlainText() {
            guard !plainText.isEmpty else { return }
            segments.append((text: plainText, isEnclosed: false))
            plainText.removeAll(keepingCapacity: true)
        }

        for character in self {
            if let replacement = Self.aribEnclosedGlyphLabels[character] {
                flushPlainText()
                segments.append((text: replacement, isEnclosed: true))
            } else {
                plainText.append(character)
            }
        }

        flushPlainText()
        return segments
    }

    private nonisolated var containsARIBEnclosedGlyphs: Bool {
        contains { Self.aribEnclosedGlyphLabels[$0] != nil }
    }

    private nonisolated static let aribEnclosedGlyphLabels: [Character: String] = [
        "🅊": "HV",
        "🄿": "P",
        "🅌": "SD",
        "🅆": "W",
        "🅋": "MV",
        "🈐": "手",
        "🈑": "字",
        "🈒": "双",
        "🈓": "デ",
        "🅂": "S",
        "🈔": "二",
        "🈕": "多",
        "🈖": "解",
        "🅍": "SS",
        "🄱": "B",
        "🄽": "N",
        "🈗": "天",
        "🈘": "交",
        "🈙": "映",
        "🈚": "無",
        "🈛": "料",
        "⚿": "鍵",
        "🈜": "前",
        "🈝": "後",
        "🈞": "再",
        "🈟": "新",
        "🈠": "初",
        "🈡": "終",
        "🈢": "生",
        "🈣": "販",
        "🈤": "声",
        "🈥": "吹",
        "🅎": "PPV",
        "㊙": "秘",
        "🈀": "ほか",
        "🆛": "3D",
        "🆜": "2ndScr",
        "🆝": "2K",
        "🆞": "4K",
        "🆟": "8K",
        "🆠": "5.1",
        "🆡": "7.1",
        "🆢": "22.2",
        "🆣": "60P",
        "🆤": "120P",
        "🆥": "d",
        "🆦": "HC",
        "🆧": "HDR",
        "🆨": "Hi-Res",
        "🆩": "Lossless",
        "🆪": "SHV",
        "🆫": "UHD",
        "🆬": "VOD",
    ]
}
