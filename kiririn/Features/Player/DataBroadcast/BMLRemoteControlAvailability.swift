nonisolated struct BMLRemoteControlAvailability: Equatable, Sendable {
    let isDataButtonEnabled: Bool
    let enabledGroups: Set<BMLKeyGroup>

    func isEnabled(_ key: ARIBRemoteKey) -> Bool {
        guard isDataButtonEnabled else {
            return false
        }
        guard let requiredGroup = key.requiredGroup else {
            return true
        }
        return enabledGroups.contains(requiredGroup)
    }
}
