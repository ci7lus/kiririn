import SwiftUI

#if canImport(PronamaAssets)
    import PronamaAssets
#endif

private struct AboutAppHeaderView: View {
    let appVersion: String
    let buildNumber: String
    let githubURL: URL

    var body: some View {
        VStack(spacing: 20) {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)

            VStack(spacing: 6) {
                Text("kiririn")
                    .font(.title2.bold())
                Text("バージョン \(appVersion) (\(buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Link(destination: githubURL) {
                Label("GitHub リポジトリ", systemImage: "link")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct AboutAppView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }
    private let githubURL = URL(string: "https://github.com/ci7lus/kiririn")!

    @ViewBuilder
    private var appHeaderSection: some View {
        #if os(macOS)
            Section {
                EmptyView()
            } header: {
                AboutAppHeaderView(
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    githubURL: githubURL
                )
            }
        #else
            Section {
                AboutAppHeaderView(
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                    githubURL: githubURL
                )
            }
            .listRowBackground(Color.clear)
        #endif
    }

    var body: some View {
        Form {
            appHeaderSection

            Section {
                NavigationLink {
                    VLCKitAboutView()
                } label: {
                    Label("VLCKitについて", systemImage: "info.circle")
                }

                NavigationLink {
                    PronamaAboutView()
                } label: {
                    Label {
                        Text("プロ生ちゃん アプリ開発支援プログラムについて")
                    } icon: {
                        #if canImport(PronamaAssets)
                            PronamaAssets.keiIcon
                                .resizable()
                                .scaledToFit()
                        #else
                            Image(systemName: "heart.text.square")
                        #endif
                    }
                }

                NavigationLink {
                    LicenseListView()
                } label: {
                    Label("ライセンス表示", systemImage: "doc.text")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("このアプリについて")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview("このアプリについて") {
    NavigationStack {
        AboutAppView()
    }
}
