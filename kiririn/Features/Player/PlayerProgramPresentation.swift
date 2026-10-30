nonisolated struct PlayerProgramPresentation<Content> {
    var presented: Content?
    var received: Content?

    func selected(allowsReceived: Bool) -> Content? {
        presented ?? (allowsReceived ? received : nil)
    }

    mutating func resetPresented() {
        presented = nil
    }
}
