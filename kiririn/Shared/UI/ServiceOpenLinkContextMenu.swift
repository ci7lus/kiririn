import SwiftUI

private struct ServiceOpenLinkContextMenuModifier: ViewModifier {
    let service: TVService

    func body(content: Content) -> some View {
        content.contextMenu {
            if let url = serviceOpenLinkURL {
                Button {
                    copyTextToClipboard(url.absoluteString)
                } label: {
                    Label {
                        Text("リンクをコピー")
                    } icon: {
                        accentMenuIcon(systemName: "link")
                    }
                }
            }
        }
    }

    private var serviceOpenLinkURL: URL? {
        ServiceOpenRequest(
            networkId: service.networkId,
            serviceId: service.serviceId,
            preferredServerId: service.serverId
        ).deepLinkURL
    }
}

extension View {
    func serviceOpenLinkContextMenu(for service: TVService) -> some View {
        modifier(ServiceOpenLinkContextMenuModifier(service: service))
    }
}
