import Foundation
import SwiftUI

#if canImport(PronamaAssets)
    import PronamaAssets

    enum PronamaImageAsset: String {
        case keiIcon = "KeiIcon"
        case keiKotatsu = "KeiKotatsu"
    }

    struct PronamaCredit: Identifiable {
        let asset: PronamaImageAsset
        let authorName: String
        let originalFileName: String
        let url: URL

        var id: String {
            asset.rawValue
        }

        var title: String {
            "\(authorName)（\(originalFileName)）"
        }
    }

    enum PronamaCreditStore {
        static let credits: [PronamaCredit] = [
            PronamaCredit(
                asset: .keiIcon,
                authorName: "ta2nbさま",
                originalFileName: "01-1.png",
                url: URL(string: "https://x.com/ta2nb")!
            ),
            PronamaCredit(
                asset: .keiKotatsu,
                authorName: "ささくら（339ra）さま",
                originalFileName: "20161231.png",
                url: URL(string: "https://x.com/339ra_")!
            ),
        ]
    }
#endif

private struct PronamaAboutHeaderView: View {
    var body: some View {
        VStack(spacing: 20) {
            #if canImport(PronamaAssets)
                PronamaAssets.keiKotatsu
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(radius: 1)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("プロ生ちゃん")
            #endif

            Text("本アプリは、「プロ生ちゃん アプリ開発支援プログラム」のサポートを受けています。")
        }
        .padding(.vertical, 8)
    }
}

private struct PronamaCreditLinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(title, destination: url)
        }
        .padding(.vertical, 2)
    }
}

struct PronamaAboutView: View {
    private let supportProgramURL = URL(
        string: "https://kei.pronama.jp/pronama-chan-developer-support-program/")!
    private let pronamaURL = URL(string: "https://pronama.jp")!
    private let keiURL = URL(string: "https://kei.pronama.jp/")!
    private let guidelineURL = URL(string: "https://kei.pronama.jp/guideline/")!
    private let downloadURL = URL(string: "https://kei.pronama.jp/download/")!

    @ViewBuilder
    private var pronamaHeaderSection: some View {
        #if os(macOS)
            Section {
                EmptyView()
            } header: {
                PronamaAboutHeaderView()
            }
        #else
            Section {
                PronamaAboutHeaderView()
            }
            .listRowBackground(Color.clear)
        #endif
    }

    var body: some View {
        Form {
            pronamaHeaderSection

            Section("関連リンク") {
                Link("プロ生ちゃん アプリ開発支援プログラム", destination: supportProgramURL)
                Link("プログラミング生放送 (プロ生)", destination: pronamaURL)
                Link("プロ生ちゃん（暮井 慧）", destination: keiURL)
            }

            #if canImport(PronamaAssets)
                Section("注記") {
                    Text("使用している画像は、プロ生 利用ガイドラインに基づき、配布素材を利用しています。\n© 2026 Pronama LLC")
                        .fixedSize(horizontal: false, vertical: true)
                    Link("プロ生 利用ガイドライン", destination: guidelineURL)
                    Link("ダウンロードページ", destination: downloadURL)
                }

                Section("画像クレジット") {
                    ForEach(PronamaCreditStore.credits) { credit in
                        PronamaCreditLinkRow(
                            title: credit.title,
                            url: credit.url
                        )
                    }
                }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("プロ生ちゃん アプリ開発支援プログラムについて")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationStack {
        PronamaAboutView()
    }
}
