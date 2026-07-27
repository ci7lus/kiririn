#if os(macOS)
    import SwiftUI

    struct RemoteReceiverSettingsView: View {
        let service: RemoteControlService
        @State private var isReceiverEnabled: Bool

        init(service: RemoteControlService) {
            self.service = service
            _isReceiverEnabled = State(initialValue: service.isReceiverEnabled)
        }

        var body: some View {
            Form {
                Section {
                    Toggle("有効化", isOn: $isReceiverEnabled)
                        .onChange(of: isReceiverEnabled) { _, enabled in
                            service.setReceiverEnabled(enabled)
                        }

                    LabeledContent("状態") {
                        Text(statusText)
                            .foregroundStyle(statusStyle)
                    }
                } footer: {
                    Text("同じローカルネットワーク上のiPhoneまたはiPadのkiririnアプリからプレイヤーを操作できます。")
                }

                if isReceiverEnabled {
                    Section {
                        LabeledContent("PINコード") {
                            Text(service.pairingPIN)
                                .font(.title2.monospacedDigit())
                                .bold()
                                .textSelection(.enabled)
                        }

                        LabeledContent("有効期限") {
                            Text(
                                timerInterval: pairingPINCountdownInterval,
                                countsDown: true
                            )
                            .monospacedDigit()
                        }

                        Button("PINコードを再生成", systemImage: "arrow.clockwise") {
                            service.rotatePairingPIN()
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("ペアリング")
                    } footer: {
                        Text("初回接続時にはPINコードが必要です。")
                    }
                }

                Section("登録済み端末") {
                    if service.trustedPeers.isEmpty {
                        Text("登録済み端末はありません")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(service.trustedPeers) { peer in
                            TrustedRemotePeerRow(
                                peer: peer,
                                onForget: {
                                    service.forgetTrustedPeer(id: peer.id)
                                }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("リモコン")
            .onChange(of: service.isReceiverEnabled) { _, enabled in
                isReceiverEnabled = enabled
            }
        }

        private var pairingPINCountdownInterval: ClosedRange<Date> {
            let expiration = service.pairingPINExpiresAt
            return min(Date(), expiration)...expiration
        }

        private var statusText: String {
            guard isReceiverEnabled else { return "停止中" }
            switch service.connectionStatus {
            case .connected(let name):
                return "\(name)から接続中"
            case .pairing(let name):
                return "\(name)をペアリング中"
            case .failed:
                return "エラー"
            default:
                return "受信中"
            }
        }

        private var statusStyle: HierarchicalShapeStyle {
            switch service.connectionStatus {
            case .failed:
                return .secondary
            case .connected:
                return .primary
            default:
                return .secondary
            }
        }
    }
#endif
