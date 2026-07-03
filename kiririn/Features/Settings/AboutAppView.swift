import SwiftUI

#if canImport(PronamaAssets)
    import PronamaAssets
#endif

private struct AboutAppHeaderView: View {
    let buildInfo: AppBuildInfo

    var body: some View {
        VStack(spacing: 20) {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)

            VStack(spacing: 6) {
                Text("kiririn")
                    .font(.title2.bold())
                Text("バージョン\(buildInfo.versionDescription)")
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.72))
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct AboutAppView: View {
    private let buildInfo = AppBuildInfo.current
    private let githubURL = URL(string: "https://github.com/ci7lus/kiririn")!
    private let githubIssuesURL = URL(string: "https://github.com/ci7lus/kiririn/issues")!

    @ViewBuilder
    private var appHeaderSection: some View {
        #if os(macOS)
            Section {
                EmptyView()
            } header: {
                AboutAppHeaderView(buildInfo: buildInfo)
            }
        #else
            Section {
                AboutAppHeaderView(buildInfo: buildInfo)
            }
            .listRowBackground(Color.clear)
        #endif
    }

    var body: some View {
        Form {
            appHeaderSection

            Section {
                Link(destination: githubURL) {
                    Label("GitHubリポジトリ", systemImage: "link")
                }

                Link(destination: githubIssuesURL) {
                    Label("GitHubで問題を報告", systemImage: "exclamationmark.circle")
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
                    Label("権利表記", systemImage: "doc.text")
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
