import Foundation
import GRDB
import Testing

@testable import kiririn

@Suite struct PlayerScheduleCacheTests {
    @Test @MainActor func returnsOnlyRecentPastAndFuturePrograms() async throws {
        let store = CacheStore(databaseQueue: try DatabaseQueue())
        let now = Date(timeIntervalSince1970: 100_000)
        let service = TVService(
            id: "service", providerIdentifier: nil, serviceId: 10, networkId: 20,
            transportStreamId: nil, name: "サービス", type: .digitalTelevision,
            remoteControlKeyId: nil, hasLogoData: false, channel: nil, serverId: "server")

        func program(_ id: String, _ offset: TimeInterval, networkId: Int = 20) -> Program {
            let start = now.addingTimeInterval(offset)
            return Program(
                id: id, serverId: "server", eventId: nil, serviceId: 10, networkId: networkId,
                startAt: start, endAt: start.addingTimeInterval(3_600), duration: 3_600,
                name: id, desc: nil, extended: nil, genres: [], updatedAt: nil)
        }

        let until = now.addingTimeInterval(86_400)
        await store.cachePrograms(
            [
                program("old", -10_800), program("previous", -7_200),
                program("current", -3_600), program("duplicate", -3_600),
                program("future", 60), program("boundary", 86_400),
                program("other-network", -60, networkId: 21),
            ], serverId: "server")

        let programs = await store.loadPlayerSchedulePrograms(for: service, at: now, until: until)
        #expect(programs.map(\.id) == ["previous", "current", "future"])
    }

    @Test @MainActor func includesSinglePastOrOnlyFuturePrograms() async throws {
        let store = CacheStore(databaseQueue: try DatabaseQueue())
        let now = Date(timeIntervalSince1970: 100_000)
        let service = TVService(
            id: "service", providerIdentifier: nil, serviceId: 10, networkId: 20,
            transportStreamId: nil, name: "サービス", type: .digitalTelevision,
            remoteControlKeyId: nil, hasLogoData: false, channel: nil, serverId: "server")
        func program(_ id: String, _ offset: TimeInterval) -> Program {
            let start = now.addingTimeInterval(offset)
            return Program(
                id: id, serverId: "server", eventId: nil, serviceId: 10, networkId: 20,
                startAt: start, endAt: start.addingTimeInterval(60), duration: 60,
                name: id, desc: nil, extended: nil, genres: [], updatedAt: nil)
        }

        await store.cachePrograms(
            [program("past", -60), program("future", 60)], serverId: "server")
        let until = now.addingTimeInterval(86_400)
        let withPast = await store.loadPlayerSchedulePrograms(for: service, at: now, until: until)
        #expect(withPast.map(\.id) == ["past", "future"])
        let futureOnly = await store.loadPlayerSchedulePrograms(
            for: service, at: now.addingTimeInterval(-120), until: until)
        #expect(futureOnly.map(\.id) == ["past", "future"])
    }
}
