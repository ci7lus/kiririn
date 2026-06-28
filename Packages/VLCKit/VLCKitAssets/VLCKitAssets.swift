import Foundation

public struct VLCKitLicenseNotice: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let text: String
}

public enum VLCKitAssets {
    public static let name = "VLCKit"
    public static let homepageURL = URL(string: "https://code.videolan.org/videolan/VLCKit")!

    public static var licenseNotices: [VLCKitLicenseNotice] {
        guard
            let licensesURL = Bundle.module.url(
                forResource: "LicenseNotices",
                withExtension: nil
            )
        else {
            return []
        }

        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: licensesURL,
                includingPropertiesForKeys: nil
            )) ?? []

        return
            urls
            .filter { $0.pathExtension == "txt" }
            .sorted(by: sortLicenseNoticeURLs)
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }

                return VLCKitLicenseNotice(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    text: text
                )
            }
    }

    public static func resolveSofaPath(
        sofaName: String = "dodeca_and_7channel_3DSL_HRTF",
        sofaExtension: String = "sofa"
    ) -> String? {
        Bundle.module.path(
            forResource: sofaName,
            ofType: sofaExtension
        )
    }

    private static func sortLicenseNoticeURLs(_ lhs: URL, _ rhs: URL) -> Bool {
        let priority = [
            "VLCKit.txt": 0,
            "VLC.txt": 1,
        ]
        let lhsPriority = priority[lhs.lastPathComponent] ?? 2
        let rhsPriority = priority[rhs.lastPathComponent] ?? 2

        guard lhsPriority == rhsPriority else {
            return lhsPriority < rhsPriority
        }

        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            == .orderedAscending
    }
}
