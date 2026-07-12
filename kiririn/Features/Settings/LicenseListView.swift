import LicenseList
import SwiftUI
import VLCKitAssets

struct LicenseListView: View {
    private let libraries = Library.libraries

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    VLCKitAboutView()
                } label: {
                    Text("VLCKit")
                }
                NavigationLink {
                    WebBMLAboutView()
                } label: {
                    Text("web-bml")
                }
                ForEach(libraries) { library in
                    NavigationLink {
                        LicenseDetailView(library: library)
                    } label: {
                        Text(library.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("ライセンス")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct WebBMLAboutView: View {
    private let sourceCodeURL = URL(string: "https://github.com/otya128/web-bml")!
    private let license = """
        MIT License

        Copyright (c) 2022 otya

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """

    var body: some View {
        Form {
            Section {
                Link("ソースコード", destination: sourceCodeURL)
            }

            Section("ライセンス") {
                Text(license)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("web-bml")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct VLCKitAboutView: View {
    private let sourceCodeURL = URL(string: "https://github.com/neneka/vlckit")!
    private let licenseNotices = VLCKitAssets.licenseNotices

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "本アプリはVLCKitをGNU Lesser General Public License v2.1の規定に基づき動的にリンクして使用しています。"
                    )
                    Text(
                        "ユーザーは、LGPLの条項に従ってVLCKitのソースコードを入手、改変、および再配布する権利を有します。"
                    )
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: sourceCodeURL) {
                    Text("ソースコード")
                }
            }

            Section("ライセンス") {
                if licenseNotices.isEmpty {
                    Text("ライセンス情報が見つかりません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(licenseNotices) { notice in
                        NavigationLink {
                            VLCKitLicenseNoticeView(notice: notice)
                        } label: {
                            Text(notice.name)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VLCKit")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct VLCKitLicenseNoticeView: View {
    let notice: VLCKitLicenseNotice

    var body: some View {
        ScrollView {
            Text(notice.text)
                #if os(iOS)
                    .font(.caption)
                #else
                    .font(.body)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(notice.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct LicenseDetailView: View {
    let library: Library

    var body: some View {
        LicenseView(library: library)
            .licenseViewStyle(.withRepositoryAnchorLink)
            .navigationTitle(library.name)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

#Preview("ライセンス") {
    NavigationStack {
        LicenseListView()
    }
}

#Preview("VLCKitについて") {
    NavigationStack {
        VLCKitAboutView()
    }
}
