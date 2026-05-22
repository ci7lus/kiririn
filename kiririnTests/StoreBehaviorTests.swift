import Foundation
import GRDB
import Testing

@testable import kiririn

struct StoreBehaviorTests {

    @Test func backendConfigStorePersistsConfigurationsAndEnabledStates() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BackendConfigStore(localDefaults: defaults)
        let config = BackendConfiguration(
            id: "backend-1",
            name: "Main",
            type: .epgstation,
            baseURL: "https://example.com"
        )

        store.addConfiguration(config)
        store.setEnabled(false, for: config.id)

        let reloaded = BackendConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations == [config])
        #expect(!reloaded.isEnabled(config.id))
    }

    @Test func backendConfigStoreCanMoveUpdateAndRemoveConfigurations() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BackendConfigStore(localDefaults: defaults)
        let first = BackendConfiguration(
            id: "a", name: "A", type: .mirakurun, baseURL: "https://a.example")
        let second = BackendConfiguration(
            id: "b", name: "B", type: .epgstation, baseURL: "https://b.example")
        let third = BackendConfiguration(id: "c", name: "C", type: .googledrive, baseURL: nil)

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

        let reloaded = BackendConfigStore(localDefaults: defaults)
        #expect(reloaded.configurations.map(\.id) == ["b", "a"])
        #expect(reloaded.configurations.first?.name == "B Updated")
        #expect(reloaded.isEnabled("c"))
    }

    @MainActor @Test func cacheStorePersistsLastProgramFullFetchDates() async throws {
        let dbQueue = try DatabaseQueue()
        let store = CacheStore(databaseQueue: dbQueue)

        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 1_234),
            backendId: "backend-1"
        )
        await store.saveLastProgramFullFetchDate(
            Date(timeIntervalSince1970: 5_678),
            backendId: "backend-2"
        )

        let reloaded = CacheStore(databaseQueue: dbQueue)
        let dates = await reloaded.loadLastProgramFullFetchDates()

        #expect(dates["backend-1"] == Date(timeIntervalSince1970: 1_234))
        #expect(dates["backend-2"] == Date(timeIntervalSince1970: 5_678))
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
            backendId: "backend-1"
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
            backendId: "backend-1"
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
