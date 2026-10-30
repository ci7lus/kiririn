import Foundation
import Testing

#if !PLAYABLE_MODEL_STANDALONE
    @testable import kiririn
#endif

@Suite struct PlayableProgramPresentationTests {
    @Test func bootstrapUsesCachedProgram() {
        let playable = playable()
        #expect(playable.displayProgram == playable.program)
        #expect(playable.title == "MLB中継")
        #expect(playable.subtitle == "旧番組の説明")
        #expect(playable.toPluginSchema()["program"] != nil)
    }

    @Test func unavailableProgramHidesCachedProgramAndPluginMetadata() throws {
        let playable = try settingAvailability("unavailable", on: playable())
        expectUnavailable(playable)
        #expect(playable.program?.name == "MLB中継")
    }

    @Test func unavailableProgramAlsoHidesPartialOverrides() throws {
        var playable = playable()
        playable.overriddenProgram = PlayableProgramOverride(
            name: "古い上書き番組", desc: "古い上書き説明")
        playable = try settingAvailability("unavailable", on: playable)
        expectUnavailable(playable)
        playable.program = nil
        expectUnavailable(playable)
    }

    @Test func providerRefreshKeepsUnavailableProgramHidden() throws {
        var playable = try settingAvailability("unavailable", on: playable())
        playable.program?.name = "更新された古い番組"
        playable.program?.desc = "更新された古い説明"
        expectUnavailable(playable)
        #expect(playable.program?.name == "更新された古い番組")
    }

    @Test func knownProgramRecoversPresentation() throws {
        var playable = try settingAvailability("unavailable", on: playable())
        playable.overriddenProgram = PlayableProgramOverride(
            startAt: Date(timeIntervalSince1970: 5_000), duration: 1_800,
            name: "緊急ニュース", desc: "新しい番組の説明")
        playable = try settingAvailability("available", on: playable)
        #expect(playable.displayProgram?.name == "緊急ニュース")
        #expect(playable.title == "緊急ニュース")
        #expect(playable.subtitle == "新しい番組の説明")
        let schema = playable.toPluginSchema()
        #expect(schema["title"] as? String == "緊急ニュース")
        let program = schema["program"] as? [String: Any]
        #expect(program?["name"] as? String == "緊急ニュース")
    }

    @Test func indefiniteEmergencyProgramNeverInheritsCachedEPG() throws {
        var playable = playable()
        playable.overriddenProgram = PlayableProgramOverride(
            eventId: 2, serviceId: 10, networkId: 20,
            startAt: Date(timeIntervalSince1970: 5_000), name: "緊急ニュース")
        playable = try settingAvailability("available", on: playable)
        #expect(playable.title == "緊急ニュース")
        #expect(playable.subtitle == nil)
        #expect(playable.displayProgram == nil)
        #expect(playable.toPluginSchema()["program"] == nil)

        playable.program?.name = "更新されたMLB中継"
        playable.program?.endAt = Date(timeIntervalSince1970: 9_000)
        #expect(playable.title == "緊急ニュース")
        #expect(playable.subtitle == nil)
        #expect(playable.displayProgram == nil)

        playable.overriddenProgram?.desc = "緊急放送の説明"
        #expect(playable.subtitle == "緊急放送の説明")
    }

    @Test func receivedSIReplacesUnknownPresentationAndFrozenProgramTakesPriority() {
        var presentation = PlayerProgramPresentation<PlayableProgramOverride>()
        let known = PlayableProgramOverride(
            startAt: Date(timeIntervalSince1970: 1_000), duration: 4_000,
            name: "提示中の番組A", desc: "提示中の説明")
        presentation.presented = known
        presentation.received = PlayableProgramOverride(
            startAt: Date(timeIntervalSince1970: 5_000), name: "緊急ニュースB")
        var playable = playable()
        playable.programAvailability = .available
        playable.overriddenProgram = presentation.selected(allowsReceived: true)
        #expect(playable.title == "提示中の番組A")
        #expect(playable.subtitle == "提示中の説明")
        #expect(playable.displayProgram?.name == "提示中の番組A")

        presentation.presented = nil
        playable.overriddenProgram = presentation.selected(allowsReceived: true)
        #expect(playable.title == "緊急ニュースB")
        #expect(playable.subtitle == nil)
        #expect(playable.displayProgram == nil)

        presentation.resetPresented()
        presentation.presented = known
        playable.overriddenProgram = presentation.selected(allowsReceived: true)
        #expect(playable.title == "提示中の番組A")
        #expect(playable.subtitle == "提示中の説明")
        #expect(playable.displayProgram?.name == "提示中の番組A")
    }

    @Test func unavailableProgramKeepsSourceTitleFallback() throws {
        let directURL = try #require(URL(string: "https://example.com/news.ts"))
        let sources: [PlayableSource] = [
            .fileURL(URL(fileURLWithPath: "/tmp/news.ts"), bookmarkData: nil),
            .directURL(directURL),
        ]
        for source in sources {
            var playable = playable()
            playable.source = source
            playable.service = nil
            playable = try settingAvailability("unavailable", on: playable)
            #expect(playable.title == "news.ts")
            #expect(playable.subtitle == nil)
            #expect(playable.displayService == nil)
        }
    }

    @Test func legacyCodingWithoutAvailabilityKeepsFallback() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(playable())) as? [String: Any])
        json.removeValue(forKey: "programAvailability")
        let decoded = try JSONDecoder().decode(
            Playable.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.displayProgram?.name == "MLB中継")
        #expect(decoded.subtitle == "旧番組の説明")
    }

    @Test func availabilitySurvivesCodingRoundTrip() throws {
        for availability in ["available", "unavailable"] {
            let original = try settingAvailability(availability, on: playable())
            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(Playable.self, from: encoded)
            #expect(decoded == original)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(json["programAvailability"] as? String == availability)
            if availability == "unavailable" {
                expectUnavailable(decoded)
            } else {
                #expect(decoded.displayProgram == nil)
                #expect(decoded.title == "放送局")
            }
        }
    }

    private func expectUnavailable(_ playable: Playable) {
        #expect(playable.displayProgram == nil)
        #expect(playable.title == "放送局")
        #expect(playable.subtitle == nil)
        let schema = playable.toPluginSchema()
        #expect(schema["title"] as? String == "放送局")
        #expect(schema["subtitle"] == nil)
        #expect(schema["program"] == nil)
        let service = schema["service"] as? [String: Any]
        #expect(service?["name"] as? String == "放送局")
    }

    private func settingAvailability(_ availability: String, on playable: Playable) throws
        -> Playable
    {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(playable)) as? [String: Any])
        json["programAvailability"] = availability
        return try JSONDecoder().decode(
            Playable.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func playable() -> Playable {
        let service = TVService(
            id: "20-10", serviceId: 10, networkId: 20, name: "放送局",
            type: .digitalTelevision, hasLogoData: false, serverId: "server")
        let program = Program(
            id: "mlb", serverId: "server", eventId: 1, serviceId: 10, networkId: 20,
            startAt: Date(timeIntervalSince1970: 1_000),
            endAt: Date(timeIntervalSince1970: 5_000), duration: 4_000,
            name: "MLB中継", desc: "旧番組の説明", genres: [])
        return Playable(
            streamURL: URL(fileURLWithPath: "/tmp/news.ts"),
            source: .liveService(serviceUniqueId: service.id), program: program, service: service)
    }
}
