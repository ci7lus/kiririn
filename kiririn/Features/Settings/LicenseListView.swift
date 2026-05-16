import LicenseList
import SwiftUI
import VLCKitLicense

struct LicenseListView: View {
    private let libraries: [Library] =
        [
            Library(
                name: VLCKitLicense.name,
                url: VLCKitLicense.homepageURL.absoluteString,
                licenseBody: VLCKitLicense.text
            )
        ] + Library.libraries

    var body: some View {
        List(libraries) { library in
            NavigationLink {
                LicenseDetailView(library: library)
            } label: {
                Text(library.name)
            }
        }
        .navigationTitle("ライセンス")
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
