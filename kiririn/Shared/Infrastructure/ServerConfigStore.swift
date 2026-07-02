import Foundation

@Observable
class ServerConfigStore {
    private let localDefaults: UserDefaults
    private let keychainStore = KeychainCredentialStore()
    private let configsKey = "kiririn.server.configurations"
    private let enabledKey = "kiririn.server.enabled."

    var configurations: [ServerConfiguration] = []
    var enabledStates: [String: Bool] = [:]

    init(localDefaults: UserDefaults = .standard) {
        self.localDefaults = localDefaults
        loadConfigurations()
    }

    private func loadConfigurations() {
        let data = localDefaults.data(forKey: configsKey)
        guard let data else {
            configurations = []
            enabledStates = [:]
            return
        }
        let decoder = JSONDecoder()
        var loaded = (try? decoder.decode([ServerConfiguration].self, from: data)) ?? []
        for index in loaded.indices {
            if let auth = keychainStore.load(forServerId: loaded[index].id) {
                loaded[index].auth = auth
            }
        }
        configurations = loaded
        enabledStates = configurations.reduce(into: [:]) { result, config in
            let key = enabledKey + config.id
            let enabled =
                localDefaults.object(forKey: key) == nil ? true : localDefaults.bool(forKey: key)
            result[config.id] = enabled
        }
    }

    private func saveConfigurations() {
        for config in configurations {
            keychainStore.save(config.auth, forServerId: config.id)
        }
        let stripped = configurations.map { config -> ServerConfiguration in
            var c = config
            c.auth = .none
            return c
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(stripped) else { return }
        localDefaults.set(data, forKey: configsKey)
    }

    func addConfiguration(_ config: ServerConfiguration) {
        configurations.append(config)
        saveConfigurations()
        setEnabled(true, for: config.id)
    }

    func updateConfiguration(_ config: ServerConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()
        }
    }

    func removeConfiguration(id: String) {
        configurations.removeAll { $0.id == id }
        keychainStore.delete(forServerId: id)
        saveConfigurations()
        enabledStates[id] = nil
        localDefaults.removeObject(forKey: enabledKey + id)
    }

    func moveConfiguration(fromOffsets: IndexSet, toOffset: Int) {
        guard !fromOffsets.isEmpty else { return }
        let sortedOffsets = fromOffsets.sorted()
        let movingItems = sortedOffsets.map { configurations[$0] }
        for index in sortedOffsets.reversed() {
            configurations.remove(at: index)
        }

        var adjustedDestination = toOffset
        for index in sortedOffsets where index < toOffset {
            adjustedDestination -= 1
        }
        adjustedDestination = max(0, min(adjustedDestination, configurations.count))
        configurations.insert(contentsOf: movingItems, at: adjustedDestination)
        saveConfigurations()
    }

    @discardableResult
    func moveConfiguration(id: String, delta: Int) -> Bool {
        guard delta != 0,
            let currentIndex = configurations.firstIndex(where: { $0.id == id })
        else {
            return false
        }
        let newIndex = max(0, min(configurations.count - 1, currentIndex + delta))
        guard newIndex != currentIndex else { return false }
        let item = configurations.remove(at: currentIndex)
        configurations.insert(item, at: newIndex)
        saveConfigurations()
        return true
    }

    func isEnabled(_ serverId: String) -> Bool {
        enabledStates[serverId] ?? true
    }

    func setEnabled(_ enabled: Bool, for serverId: String) {
        enabledStates[serverId] = enabled
        localDefaults.set(enabled, forKey: enabledKey + serverId)
    }
}
