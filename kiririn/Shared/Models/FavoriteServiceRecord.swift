import Foundation

nonisolated struct FavoriteServiceRecord: Sendable, Equatable {
    let networkId: Int
    let serviceId: Int
    let displayOrder: Int?

    var unifiedServiceKey: String {
        "\(networkId)-\(serviceId)"
    }

    init(networkId: Int, serviceId: Int, displayOrder: Int?) {
        self.networkId = networkId
        self.serviceId = serviceId
        self.displayOrder = displayOrder
    }

    init?(unifiedServiceKey: String, displayOrder: Int?) {
        let components = unifiedServiceKey.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            let networkId = Int(components[0]),
            let serviceId = Int(components[1])
        else {
            return nil
        }

        self.init(
            networkId: networkId,
            serviceId: serviceId,
            displayOrder: displayOrder
        )
    }
}
