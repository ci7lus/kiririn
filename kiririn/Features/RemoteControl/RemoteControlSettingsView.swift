import SwiftUI

struct RemoteControlSettingsView: View {
    let service: RemoteControlService

    var body: some View {
        Group {
            #if os(macOS)
                RemoteReceiverSettingsView(service: service)
            #else
                RemoteDestinationListView(service: service)
            #endif
        }
        .task {
            service.prepare()
        }
    }
}
