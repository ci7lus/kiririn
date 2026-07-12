import Foundation
import GRDB
import Testing

@testable import kiririn

/// 各テストが他のテストや実アプリのUserDefaultsを汚さないよう、テストごとに
/// 使い捨てのsuiteを払い出す(d26e7b7で消失していたヘルパーの復元)。
private func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "kiririn.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

struct StoreBehaviorTests {

    @Test func dataBroadcastSettingsPersistsValidPostalCode() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DataBroadcastSettings.setPostalCode("0123456", in: defaults)

        #expect(DataBroadcastSettings.postalCode(in: defaults) == "0123456")
    }

    @Test func dataBroadcastSettingsRejectsInvalidPostalCodes() {
        #expect(DataBroadcastSettings.validatedPostalCode(nil) == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("") == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("123456") == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("12345678") == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("123-4567") == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("１２３４５６７") == nil)
        #expect(DataBroadcastSettings.validatedPostalCode("1234567") == "1234567")
    }

    @Test func bmlTuneRequestRequiresCompleteValidIdentifiers() {
        let request = BMLTuneRequest(bridgeMessage: [
            "originalNetworkId": 0x7880,
            "transportStreamId": 0x7881,
            "serviceId": 0x0400,
        ])

        #expect(request?.originalNetworkId == 0x7880)
        #expect(request?.transportStreamId == 0x7881)
        #expect(request?.serviceId == 0x0400)
        #expect(BMLTuneRequest(bridgeMessage: ["originalNetworkId": 1]) == nil)
        #expect(
            BMLTuneRequest(bridgeMessage: [
                "originalNetworkId": 1,
                "transportStreamId": 2,
                "serviceId": 65_536,
            ]) == nil)
    }

    @Test func bmlTuneRequestMatchesAllThreeServiceIdentifiers() throws {
        let request = try #require(
            BMLTuneRequest(bridgeMessage: [
                "originalNetworkId": 1,
                "transportStreamId": 2,
                "serviceId": 3,
            ]))
        let exact = makeService(networkId: 1, transportStreamId: 2, serviceId: 3)
        let missingTransportStream = makeService(
            networkId: 1, transportStreamId: nil, serviceId: 3)
        let differentTransportStream = makeService(
            networkId: 1, transportStreamId: 4, serviceId: 3)

        #expect(request.matches(exact))
        #expect(!request.matches(missingTransportStream))
        #expect(!request.matches(differentTransportStream))
    }

    @Test func serverConfigStorePersistsConfigurationsAndEnabledStates() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ServerConfigStore(localDefaults: defaults)
        let config = ServerConfiguration(
            id: "server-1",
            name: "Main",
            type: .epgstation,
            baseURL: "https://example.com"
        )

        store.addConfiguration(config)
        store.setEnabled(false, for: config.id)

        let reloaded = ServerConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations == [config])
        #expect(!reloaded.isEnabled(config.id))
    }

    @Test func serverConfigStoreCanMoveUpdateAndRemoveConfigurations() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ServerConfigStore(localDefaults: defaults)
        let first = ServerConfiguration(
            id: "a", name: "A", type: .mirakurun, baseURL: "https://a.example")
        let second = ServerConfiguration(
            id: "b", name: "B", type: .epgstation, baseURL: "https://b.example")
        let third = ServerConfiguration(id: "c", name: "C", type: .googledrive, baseURL: nil)

        store.addConfiguration(first)
        store.addConfiguration(second)
        store.addConfiguration(third)

        store.moveConfiguration(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(store.configurations.map(\.id) == ["b", "c", "a"])

        let moved = store.moveConfiguration(id: "a", delta: -1)
        #expect(moved)
        #expect(store.configurations.map(\.id) == ["b", "a", "c"])

        var updatedSecond = second
        updatedSecond.name = "B Updated"
        store.updateConfiguration(updatedSecond)
        store.removeConfiguration(id: "c")

        let reloaded = ServerConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations.map(\.id) == ["b", "a"])
        #expect(reloaded.configurations.first?.name == "B Updated")
        #expect(reloaded.isEnabled("c"))
    }

    @MainActor @Test func cacheStorePersistsLastProgramFullFetchDates() async throws {
        let dbQueue = try DatabaseQueue()
        let store = CacheStore(databaseQueue: dbQueue)

        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 1_234),
            serverId: "server-1"
        )
        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 5_678),
            serverId: "server-2"
        )

        let reloaded = CacheStore(databaseQueue: dbQueue)
        let dates = await reloaded.loadLastProgramFullFetchDates()

        #expect(dates["server-1"] == Date(timeIntervalSince1970: 1_234))
        #expect(dates["server-2"] == Date(timeIntervalSince1970: 5_678))
    }

    @MainActor @Test func cacheStorePersistsFavoriteServiceDisplayOrder() async throws {
        let dbQueue = try DatabaseQueue()
        let store = CacheStore(databaseQueue: dbQueue)

        let first = TVService(
            id: "service-1",
            providerIdentifier: nil,
            serviceId: 101,
            networkId: 1,
            transportStreamId: nil,
            name: "NHK総合",
            type: .digitalTelevision,
            remoteControlKeyId: 1,
            hasLogoData: false,
            channel: .init(id: "gr011", type: "GR"),
            serverId: "server-1"
        )
        let second = TVService(
            id: "service-2",
            providerIdentifier: nil,
            serviceId: 102,
            networkId: 1,
            transportStreamId: nil,
            name: "Eテレ",
            type: .digitalTelevision,
            remoteControlKeyId: 2,
            hasLogoData: false,
            channel: .init(id: "gr021", type: "GR"),
            serverId: "server-1"
        )
        await store.saveFavoriteService(first)
        await store.saveFavoriteService(second)
        await store.saveFavoriteServices([
            FavoriteServiceRecord(
                networkId: 1,
                serviceId: 101,
                displayOrder: 1
            ),
            FavoriteServiceRecord(
                networkId: 1,
                serviceId: 102,
                displayOrder: 0
            ),
        ])

        let reloaded = CacheStore(databaseQueue: dbQueue)
        let favorites = await reloaded.loadFavoriteServices()
        let favoriteByKey = Dictionary(
            uniqueKeysWithValues: favorites.map { ($0.unifiedServiceKey, $0) }
        )

        #expect(favoriteByKey["1-101"]?.displayOrder == 1)
        #expect(favoriteByKey["1-102"]?.displayOrder == 0)
    }
}

private func makeService(networkId: Int, transportStreamId: Int?, serviceId: Int) -> TVService {
    TVService(
        id: "\(networkId)-\(transportStreamId ?? -1)-\(serviceId)",
        providerIdentifier: nil,
        serviceId: serviceId,
        networkId: networkId,
        transportStreamId: transportStreamId,
        name: "Test",
        type: .digitalTelevision,
        remoteControlKeyId: nil,
        hasLogoData: false,
        channel: nil,
        serverId: "server-1"
    )
}
