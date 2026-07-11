import Foundation
import Testing

@testable import ARIBStandardKit

struct ARIBStandardKitTests {

    @Test func programGenreMajorDisplayName() {
        let genre = ProgramGenre(lv1: 0x0, lv2: nil)
        #expect(genre.majorDisplayName == "ニュース・報道")
    }

    @Test func programGenreSubDisplayName() {
        let genre = ProgramGenre(lv1: 0x0, lv2: 0x1)
        #expect(genre.subDisplayName == "天気")
    }

    @Test func programGenreDisplayName() {
        let genre = ProgramGenre(lv1: 0x0, lv2: 0x1)
        #expect(genre.displayName == "ニュース・報道 / 天気")
    }

    @Test func programGenreDisplayNameWithoutSub() {
        let genre = ProgramGenre(lv1: 0x0, lv2: nil)
        #expect(genre.displayName == "ニュース・報道")
    }

    @Test func programGenreLevel1Lookup() {
        #expect(ProgramGenre.level1(for: "スポーツ") == 0x1)
    }

    @Test func programGenreLevel2Lookup() {
        #expect(ProgramGenre.level2(for: "野球", in: 0x1) == 0x1)
    }

    @Test func replacingARIBEnclosedGlyphsForDisplay() {
        let input = "🈐🈑🈒"
        let result = input.replacingARIBEnclosedGlyphsForDisplay()
        #expect(result == "[手][字][双]")
    }

    @Test func aribBroadcastDisplaySegments() {
        let input = "テスト🈐文字"
        let segments = input.aribBroadcastDisplaySegments()
        #expect(segments.count == 3)
        #expect(segments[0].text == "テスト")
        #expect(!segments[0].isEnclosed)
        #expect(segments[1].text == "手")
        #expect(segments[1].isEnclosed)
        #expect(segments[2].text == "文字")
        #expect(!segments[2].isEnclosed)
    }

    @Test func aribEnclosedGlyphLabelsContainsExpectedEntries() {
        #expect(String.aribEnclosedGlyphLabels["🈐"] == "手")
        #expect(String.aribEnclosedGlyphLabels["🆞"] == "4K")
        #expect(String.aribEnclosedGlyphLabels["🆧"] == "HDR")
        #expect(String.aribEnclosedGlyphLabels["🈀"] == nil)
    }
}
