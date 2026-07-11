//
//  kiririnTests.swift
//  kiririnTests
//

import ARIBStandardKit
import Foundation
import OrderedCollections
import Testing

@testable import kiririn

struct KiririnTests {

    @Test func replacingARIBEnclosedGlyphsForDisplayMapsKnownBroadcastMarks() {
        let source = "🈑字幕🈔音声🆞🆧⚿㊙🈀🆬"

        let replaced = source.replacingARIBEnclosedGlyphsForDisplay()

        #expect(replaced == "[字]字幕[二]音声[4K][HDR][鍵][秘]🈀[VOD]")
    }

    @Test func replacingARIBEnclosedGlyphsForDisplayLeavesOtherCharactersUnchanged() {
        let source = "通常のタイトルとABC123"

        let replaced = source.replacingARIBEnclosedGlyphsForDisplay()

        #expect(replaced == source)
    }

    @Test func broadcastDisplaySegmentsSeparateEnclosedTokensFromPlainText() {
        let source = "番組🈑タイトル🆞"

        let segments = source.aribBroadcastDisplaySegments()

        #expect(segments.map(\.text) == ["番組", "字", "タイトル", "4K"])
        #expect(segments.map(\.isEnclosed) == [false, true, false, true])
    }

    @Test func programAndRecordedKeepRawValuesForBroadcastTextRendering() {
        let program = Program(
            id: "program",
            serverId: "server",
            eventId: 1,
            serviceId: 10,
            networkId: 20,
            startAt: Date(timeIntervalSince1970: 1_000),
            endAt: Date(timeIntervalSince1970: 1_060),
            duration: 60,
            name: "🈑番組🆞",
            desc: "🆧対応",
            extended: ["🈐": "🈑あり"],
            genres: [],
            updatedAt: nil
        )
        let record = Recorded(
            id: "record",
            name: "🈡録画🆬",
            desc: "🈚🈛ではない",
            extended: ["🈟": "🈞"],
            serviceName: "🈐チャンネル",
            startAt: nil,
            duration: nil,
            genres: [],
            variants: [],
            isRecording: false,
            hasThumbnail: false,
            serverId: "server"
        )

        #expect(program.name == "🈑番組🆞")
        #expect(program.desc == "🆧対応")
        #expect(program.extended?.map(\.key) == ["🈐"])
        #expect(program.extended?.map(\.value) == ["🈑あり"])

        #expect(record.name == "🈡録画🆬")
        #expect(record.desc == "🈚🈛ではない")
        #expect(record.serviceName == "🈐チャンネル")

        #expect(program.name.aribBroadcastDisplaySegments().map(\.text) == ["字", "番組", "4K"])
        #expect(
            program.name.aribBroadcastDisplaySegments().map(\.isEnclosed) == [true, false, true])
    }

    @Test func playableUsesRawValuesForBroadcastTextRendering() {
        let program = Program(
            id: "program",
            serverId: "server",
            eventId: 1,
            serviceId: 10,
            networkId: 20,
            startAt: Date(timeIntervalSince1970: 1_000),
            endAt: Date(timeIntervalSince1970: 1_060),
            duration: 60,
            name: "🈑番組🆞",
            desc: "🆧対応",
            extended: nil,
            genres: [],
            updatedAt: nil
        )
        let playable = Playable(
            streamURL: URL(string: "https://example.com/live.ts")!,
            source: .directURL(URL(string: "https://example.com/live.ts")!),
            program: program,
            service: TVService(
                id: "service",
                serviceId: 10,
                networkId: 20,
                transportStreamId: nil,
                name: "🈐サービス",
                type: .digitalTelevision,
                remoteControlKeyId: nil,
                hasLogoData: false,
                channel: nil,
                serverId: "server"
            )
        )

        #expect(playable.title == "🈑番組🆞")
        #expect(playable.subtitle == "🆧対応")
        #expect(playable.serviceName == "🈐サービス")

        #expect(playable.title.aribBroadcastDisplaySegments().map(\.text) == ["字", "番組", "4K"])
        #expect(playable.subtitle?.aribBroadcastDisplaySegments().map(\.text) == ["HDR", "対応"])
    }

    @Test func programGenreUsesSubGenreForShortDisplayName() {
        let genre = ProgramGenre(lv1: 0x0, lv2: 0x1)

        #expect(genre.majorDisplayName == "ニュース・報道")
        #expect(genre.subDisplayName == "天気")
        #expect(genre.displayName == "ニュース・報道 / 天気")
    }

    @Test func programGenreFallsBackToMajorDisplayName() {
        let genre = ProgramGenre(lv1: 0xE, lv2: 0x2)

        #expect(genre.majorDisplayName == "拡張")
        #expect(genre.subDisplayName == nil)
        #expect(genre.displayName == "拡張")
    }

    @Test func programGenreCanResolveCodesFromNames() {
        #expect(ProgramGenre.level1(for: "福祉") == 0xB)
        #expect(ProgramGenre.level2(for: "文字(字幕)", in: 0xB) == 0x5)
        #expect(ProgramGenre.level2(for: "", in: 0xB) == nil)
        #expect(ProgramGenre.level2(for: "存在しない分類", in: 0xB) == nil)
    }

    @Test func playableProgramOverrideReplacesExtendedEntries() {
        let base = Program(
            id: "program",
            serverId: "server",
            eventId: 1,
            serviceId: 10,
            networkId: 20,
            startAt: Date(timeIntervalSince1970: 1_000),
            endAt: Date(timeIntervalSince1970: 1_060),
            duration: 60,
            name: "旧番組",
            desc: "旧説明",
            extended: ["old": "前番組", "stale": "残ってはいけない"],
            genres: [],
            updatedAt: nil
        )
        let override = PlayableProgramOverride(
            name: "新番組",
            extended: ["new": "新番組の詳細"]
        )

        let applied = override.applying(to: base)

        #expect(applied.name == "新番組")
        #expect(applied.extended == OrderedDictionary(uniqueKeysWithValues: [("new", "新番組の詳細")]))
    }

    @Test func playableProgramOverrideCanClearExtendedEntries() {
        let base = Program(
            id: "program",
            serverId: "server",
            eventId: 1,
            serviceId: 10,
            networkId: 20,
            startAt: Date(timeIntervalSince1970: 1_000),
            endAt: Date(timeIntervalSince1970: 1_060),
            duration: 60,
            name: "旧番組",
            desc: "旧説明",
            extended: ["old": "前番組"],
            genres: [],
            updatedAt: nil
        )
        let override = PlayableProgramOverride(
            name: "新番組",
            extended: [:]
        )

        let applied = override.applying(to: base)

        #expect(applied.extended == OrderedDictionary<String, String>())
    }
}
