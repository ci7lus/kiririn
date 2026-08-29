#if os(iOS)
    import SwiftUI

    struct RemoteDestinationListView: View {
        let service: RemoteControlService
        @State private var presentedPairingRequest: RemotePairingRequest?
        @State private var pairingPIN = ""
        @State private var isPairingAlertPresented = false
        @State private var presentedErrorMessage: String?

        var body: some View {
            List {
                connectionSection
                if isConnected {
                    RemotePlayerSection(service: service)
                } else {
                    destinationsSection
                }
            }
            .navigationTitle("リモコン")
            .task {
                await service.startBrowsing()
            }
            .onDisappear {
                guard !service.isReconnecting else { return }
                service.stopBrowsing()
            }
            .onChange(of: service.pairingRequest) { _, request in
                presentedPairingRequest = request
                pairingPIN = ""
                isPairingAlertPresented = request != nil
            }
            .onChange(of: service.lastErrorMessage) { _, message in
                presentedErrorMessage = message
            }
            .alert(
                "PINコードを入力",
                isPresented: $isPairingAlertPresented,
                presenting: presentedPairingRequest
            ) { _ in
                TextField("6桁のPINコード", text: $pairingPIN)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .onChange(of: pairingPIN) { _, newValue in
                        pairingPIN = String(newValue.filter(\.isNumber).prefix(6))
                    }

                Button("キャンセル", role: .cancel, action: cancelPairing)
                Button("接続", action: submitPairingPIN)
                    .disabled(pairingPIN.count != 6)
            } message: { request in
                Text("\(request.displayName)に表示されている6桁の番号を入力してください")
            }
            .alert(
                "リモコン接続エラー",
                isPresented: errorPresentationBinding
            ) {
                Button("OK") {
                    service.clearError()
                }
            } message: {
                Text(presentedErrorMessage ?? "")
            }
        }

        @ViewBuilder
        private var connectionSection: some View {
            Section {
                LabeledContent("状態") {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                if isConnected {
                    Button("切断", role: .destructive) {
                        service.disconnect()
                    }
                }
            }
        }

        @ViewBuilder
        private var destinationsSection: some View {
            Section("接続先") {
                if service.discoveredPeers.isEmpty {
                    ContentUnavailableView(
                        "接続先が見つかりません",
                        systemImage: "macbook.trianglebadge.exclamationmark",
                        description: Text("接続するには接続先でリモコン機能を有効化する必要があります")
                    )
                } else {
                    ForEach(service.discoveredPeers) { peer in
                        Button {
                            service.connect(to: peer)
                        } label: {
                            HStack {
                                Label(peer.displayName, systemImage: "macbook")
                                Spacer()
                                if isConnecting(to: peer) {
                                    ProgressView()
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }
            }
        }

        private var isConnected: Bool {
            switch service.connectionStatus {
            case .connected, .reconnecting:
                true
            default:
                false
            }
        }

        private var statusText: String {
            switch service.connectionStatus {
            case .idle:
                "停止中"
            case .browsing:
                "検索中"
            case .connecting(_, let name):
                "\(name)へ接続中"
            case .reconnecting(let name):
                "\(name)へ再接続中…"
            case .pairing(let name):
                "\(name)とペアリング中"
            case .connected(let name):
                "\(name)へ接続済み"
            case .failed:
                "接続できませんでした"
            }
        }

        private var isBusy: Bool {
            switch service.connectionStatus {
            case .connecting, .reconnecting, .pairing, .connected:
                true
            default:
                false
            }
        }

        private func isConnecting(to peer: RemoteDiscoveredPeer) -> Bool {
            guard case .connecting(let peerID, _) = service.connectionStatus else {
                return false
            }
            return peerID == peer.id
        }

        private var errorPresentationBinding: Binding<Bool> {
            Binding(
                get: { presentedErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        presentedErrorMessage = nil
                        service.clearError()
                    }
                }
            )
        }

        private func submitPairingPIN() {
            guard pairingPIN.count == 6 else { return }
            service.submitPairingPIN(pairingPIN)
        }

        private func cancelPairing() {
            presentedPairingRequest = nil
            pairingPIN = ""
            service.cancelPairing()
        }
    }
#endif
