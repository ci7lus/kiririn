import Foundation
import Testing

#if !PLAYER_SCHEDULE_STANDALONE
    @testable import kiririn
#endif

@Suite struct PlayerProgramScheduleTests {
    private let now = Date(timeIntervalSince1970: 100_000)

    @Test func selectsPreviousCurrentAndProgramsWithin24Hours() {
        let programs = [
            program("old", -7_200, -3_600), program("previous", -3_600, -1_800),
            program("current", -1_800, 1_800), program("next", 1_800, 3_600),
            program("last", 86_399, 90_000), program("outside", 86_400, 90_000),
            program("otherNetwork", 2_000, 3_000, networkId: 21),
        ]
        let rows = PlayerProgramSchedule.make(programs: programs, service: service(), at: now).rows
        #expect(rows.map(\.program.id) == ["previous", "current", "next", "last"])
        #expect(rows.map(\.state) == [.previous, .current, .upcoming, .upcoming])
    }

    @Test func handlesEmptyAndBoundaryTimes() {
        #expect(PlayerProgramSchedule.make(programs: [], service: service(), at: now).rows.isEmpty)
        let rows = PlayerProgramSchedule.make(
            programs: [
                program("ended", -3_600, 0), program("starting", 0, 3_600),
            ], service: service(), at: now
        ).rows
        #expect(rows.map(\.state) == [.previous, .current])
    }

    @Test func unknownEndDoesNotRemainCurrentAfterNextProgramStarts() {
        var unknown = program("unknown", -3_600, -3_600)
        unknown.duration = 0
        let rows = PlayerProgramSchedule.make(
            programs: [unknown, program("current", -60, 3_600)], service: service(), at: now
        ).rows
        #expect(rows.map(\.program.id) == ["unknown", "current"])
        #expect(rows.map(\.state) == [.previous, .current])
    }

    @Test func invalidEndTimeIsTreatedAsUnknown() {
        var unknown = program("unknown", -3_600, -3_600)
        unknown.duration = 3_600
        let rows = PlayerProgramSchedule.make(programs: [unknown], service: service(), at: now).rows
        #expect(rows.map(\.state) == [.current])
    }

    private func program(
        _ id: String, _ start: TimeInterval, _ end: TimeInterval, networkId: Int = 20
    ) -> Program {
        Program(
            id: id, serverId: "server", eventId: nil, serviceId: 10, networkId: networkId,
            startAt: now.addingTimeInterval(start), endAt: now.addingTimeInterval(end),
            duration: end - start, name: id, desc: nil, extended: nil, genres: [], updatedAt: nil)
    }

    private func service() -> TVService {
        TVService(
            id: "service", providerIdentifier: nil, serviceId: 10, networkId: 20,
            transportStreamId: nil, name: "サービス", type: .digitalTelevision,
            remoteControlKeyId: nil, hasLogoData: false, channel: nil, serverId: "server")
    }
}
