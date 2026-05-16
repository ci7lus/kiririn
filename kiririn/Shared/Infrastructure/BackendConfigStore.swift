import Foundation

@Observable
class BackendConfigStore {
    private let localDefaults: UserDefaults
    private let configsKey = "kiririn.backend.configurations"
    private let enabledKey = "kiririn.backend.enabled."

    var configurations: [BackendConfiguration] = []
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
        configurations = (try? decoder.decode([BackendConfiguration].self, from: data)) ?? []
        enabledStates = configurations.reduce(into: [:]) { result, config in
            let key = enabledKey + config.id
            let enabled =
                localDefaults.object(forKey: key) == nil ? true : localDefaults.bool(forKey: key)
            result[config.id] = enabled
        }
    }

    private func saveConfigurations() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(configurations) else { return }
        localDefaults.set(data, forKey: configsKey)
    }

    func addConfiguration(_ config: BackendConfiguration) {
        configurations.append(config)
        saveConfigurations()
        setEnabled(true, for: config.id)
    }

    func updateConfiguration(_ config: BackendConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            configurations[index] = config
            saveConfigurations()
        }
    }

    func removeConfiguration(id: String) {
        configurations.removeAll { $0.id == id }
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

    func isEnabled(_ backendId: String) -> Bool {
        enabledStates[backendId] ?? true
    }

    func setEnabled(_ enabled: Bool, for backendId: String) {
        enabledStates[backendId] = enabled
        localDefaults.set(enabled, forKey: enabledKey + backendId)
    }
}
